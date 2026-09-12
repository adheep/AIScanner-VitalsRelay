import Foundation
import HealthKit

/// Reads the Watch data out of HealthKit on the phone and hands it upstream.
///
/// Four mechanisms, because HealthKit has no single one that covers the job:
///
///   HKObserverQuery       registers for background wake-up. Its only job is to
///                         get the process running when a sample lands while
///                         the app is backgrounded; it carries no data itself.
///   HKSampleQuery         hydrates the latest known discrete values whenever
///                         the relay starts, including sparse older readings.
///   HKAnchoredObjectQuery streams new discrete samples. The anchor is
///                         persisted, so a relaunch resumes where it stopped
///                         instead of re-sending the last hour.
///   HKStatisticsQuery     sums the cumulative metrics. Steps arrive as dozens
///                         of tiny samples an hour; only the daily total means
///                         anything, so those are summed rather than streamed.
///
/// Latency here is not ours to control. The Watch decides when to sync, which
/// is usually seconds under load and can stretch to minutes when idle. The
/// watch app is what closes that gap; see WorkoutSessionManager.
@MainActor
final class HealthRelayService: NSObject {

    /// Called whenever new readings are available. Never called with an empty array.
    var onSamples: (([VitalsSample]) -> Void)?
    /// Non-fatal problems worth showing in the UI (a denied type, a failed query).
    var onWarning: ((String) -> Void)?

    private let store = HKHealthStore()
    private var anchors: [VitalsMetric: HKQueryAnchor] = [:]
    private var activeQueries: [HKQuery] = []
    private var backgroundDeliveryEnabled: [HKQuantityType] = []
    private var cumulativeTimer: Timer?
    private(set) var isRunning = false

    /// How far back the first query reaches. Without a bound, a fresh install
    /// would dump the entire Health database into the socket on first start.
    private let initialLookback: TimeInterval = 15 * 60

    /// Cumulative totals are re-summed on this cadence while the app is live.
    /// The observer queries also trigger a re-sum; this is the floor, so the
    /// step count still ticks when observers are throttled.
    private let cumulativeInterval: TimeInterval = 20

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Authorisation

    /// Returns the metrics that were requested.
    ///
    /// HealthKit deliberately will not tell you that read access was denied — a
    /// denied type simply reads as empty, so an app cannot infer a medical
    /// condition from the refusal. A metric that never produces a sample is
    /// therefore the only signal available.
    @discardableResult
    func requestAuthorization() async throws -> [VitalsMetric] {
        guard Self.isAvailable else {
            throw RelayError.healthDataUnavailable
        }
        try await store.requestAuthorization(toShare: [], read: VitalsMetric.readTypes)
        return VitalsMetric.allCases
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning, Self.isAvailable else { return }
        isRunning = true
        loadAnchors()

        // An anchored query only returns samples newer than its saved anchor.
        // Hydrate the screen/socket separately on every launch, otherwise
        // slow-moving values such as resting HR, respiration, wrist
        // temperature and VO2 max remain blank until Health creates another
        // sample (which can take days or weeks).
        hydrateLatestDiscreteReadings()

        for metric in VitalsMetric.discrete {
            startAnchoredQuery(for: metric)
        }
        for metric in VitalsMetric.cumulative {
            startObserver(for: metric)
        }
        refreshCumulative()

        cumulativeTimer = Timer.scheduledTimer(
            timeInterval: cumulativeInterval,
            target: self,
            selector: #selector(cumulativeTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func cumulativeTimerFired() {
        refreshCumulative()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        for query in activeQueries { store.stop(query) }
        activeQueries.removeAll()

        cumulativeTimer?.invalidate()
        cumulativeTimer = nil

        let types = backgroundDeliveryEnabled
        backgroundDeliveryEnabled.removeAll()
        Task {
            for type in types {
                try? await store.disableBackgroundDelivery(for: type)
            }
        }
        saveAnchors()
    }

    // MARK: - Discrete metrics

    /// Fetch the newest value that exists for every point-in-time metric.
    ///
    /// There is deliberately no date predicate here. Some legitimate Health
    /// metrics are sparse: VO2 max may only be calculated after an eligible
    /// outdoor workout, and wrist temperature/respiration are commonly
    /// recorded only during sleep. `limit: 1` keeps this efficient while
    /// allowing the WebApp to show the freshest available value immediately.
    private func hydrateLatestDiscreteReadings() {
        let newestFirst = NSSortDescriptor(
            key: HKSampleSortIdentifierEndDate,
            ascending: false
        )

        for metric in VitalsMetric.discrete {
            guard let type = metric.quantityType else { continue }

            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [newestFirst]
            ) { [weak self] _, samples, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.onWarning?(metric.displayName + ": " + error.localizedDescription)
                        return
                    }
                    self.emit(quantitySamples: samples, metric: metric)
                }
            }
            store.execute(query)
        }
    }

    private func startAnchoredQuery(for metric: VitalsMetric) {
        guard let type = metric.quantityType else { return }

        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-initialLookback),
            end: nil,
            options: .strictStartDate
        )

        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = {
            [weak self] _, samples, _, newAnchor, error in
            // HealthKit calls back on a private queue; everything below touches
            // main-actor state.
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.onWarning?(metric.displayName + ": " + error.localizedDescription)
                    return
                }
                if let newAnchor {
                    self.anchors[metric] = newAnchor
                    self.saveAnchors()
                }
                self.emit(quantitySamples: samples, metric: metric)
            }
        }

        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: predicate,
            anchor: anchors[metric],
            limit: HKObjectQueryNoLimit,
            resultsHandler: handler
        )
        // Fires for the lifetime of the query, which is what makes this a
        // stream rather than a one-shot fetch.
        query.updateHandler = handler

        store.execute(query)
        activeQueries.append(query)
        enableBackgroundDelivery(for: type, metric: metric)
    }

    private func emit(quantitySamples: [HKSample]?, metric: VitalsMetric) {
        guard let quantitySamples, !quantitySamples.isEmpty else { return }

        let readings: [VitalsSample] = quantitySamples
            .compactMap { $0 as? HKQuantitySample }
            .map { sample in
                VitalsSample(
                    metric: metric,
                    value: metric.wireValue(from: sample.quantity),
                    start: sample.startDate,
                    end: sample.endDate,
                    source: .healthKit
                )
            }
            .sorted { $0.end < $1.end }

        guard !readings.isEmpty else { return }
        onSamples?(readings)
    }

    // MARK: - Cumulative metrics

    private func startObserver(for metric: VitalsMetric) {
        guard let type = metric.quantityType else { return }

        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
            Task { @MainActor in
                guard let self else { completion(); return }
                if let error {
                    self.onWarning?(metric.displayName + ": " + error.localizedDescription)
                } else {
                    self.refreshCumulative(only: metric)
                }
                // Must be called, or iOS throttles and then stops waking this app.
                completion()
            }
        }
        store.execute(query)
        activeQueries.append(query)
        enableBackgroundDelivery(for: type, metric: metric)
    }

    private func refreshCumulative(only single: VitalsMetric? = nil) {
        let metrics = single.map { [$0] } ?? VitalsMetric.cumulative
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: nil, options: .strictStartDate)

        for metric in metrics {
            guard let type = metric.quantityType else { continue }
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { [weak self] _, statistics, _ in
                // No error branch: an unauthorised type and a genuinely empty
                // one both return nil here, and neither deserves a warning.
                guard let sum = statistics?.sumQuantity() else { return }
                Task { @MainActor in
                    self?.onSamples?([
                        VitalsSample(
                            metric: metric,
                            value: metric.wireValue(from: sum),
                            start: startOfDay,
                            end: Date(),
                            source: .healthKit
                        )
                    ])
                }
            }
            store.execute(query)
        }
    }

    // MARK: - Background delivery

    private func enableBackgroundDelivery(for type: HKQuantityType, metric: VitalsMetric) {
        Task {
            do {
                try await store.enableBackgroundDelivery(for: type, frequency: .immediate)
                await MainActor.run { self.backgroundDeliveryEnabled.append(type) }
            } catch {
                // Expected when the entitlement was stripped to get a free Apple
                // ID to sign. Foreground relaying is unaffected, so this is a
                // note rather than a failure.
                await MainActor.run {
                    self.onWarning?("Background updates unavailable for " + metric.displayName + ". Foreground relay still works.")
                }
            }
        }
    }

    // MARK: - Anchor persistence

    private static let anchorDefaultsKey = "health.anchors.v1"

    private func loadAnchors() {
        guard let blob = UserDefaults.standard.dictionary(forKey: Self.anchorDefaultsKey) as? [String: Data] else { return }
        for (key, data) in blob {
            guard let metric = VitalsMetric(rawValue: key),
                  let anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
            else { continue }
            anchors[metric] = anchor
        }
    }

    private func saveAnchors() {
        var blob: [String: Data] = [:]
        for (metric, anchor) in anchors {
            guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { continue }
            blob[metric.rawValue] = data
        }
        UserDefaults.standard.set(blob, forKey: Self.anchorDefaultsKey)
    }
}

enum RelayError: LocalizedError {
    case healthDataUnavailable
    case badEndpoint(String)

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "Health data is not available on this device."
        case .badEndpoint(let text):
            return "Not a usable WebSocket URL: " + text
        }
    }
}

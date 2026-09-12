import Foundation
import HealthKit

/// Live heart rate, by way of a workout session.
///
/// This is the only sanctioned route to sub-second heart rate on watchOS. The
/// sensor runs continuously during a workout and the readings are handed to the
/// live builder as they arrive, instead of being batched and synced to the
/// phone minutes later. `workout-processing` in the Info.plist is what keeps
/// this running with the wrist down.
///
/// The session is started as `.other` / `.indoor` and the workout is
/// **discarded** on stop rather than saved: this is telemetry, not exercise,
/// and it has no business appearing in the Activity rings.
///
/// Only heart rate is relayed this way. The builder's energy and distance are
/// temporary workout-session totals, not today's Activity totals. Blood oxygen
/// and respiratory rate are not workout-collected metrics on watchOS — the
/// Watch samples those periodically on its own schedule, so they reach the
/// WebApp through HealthKit on the phone instead.
@MainActor
final class WorkoutSessionManager: NSObject, ObservableObject {

    /// One live reading, ready for the phone.
    var onSample: (([VitalsSample]) -> Void)?

    @Published private(set) var isRunning = false
    @Published private(set) var heartRate: Double?
    @Published private(set) var lastError: String?
    @Published private(set) var startedAt: Date?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    /// The one metric whose live-workout meaning matches the wire contract.
    /// Energy and distance from this builder are scan-session totals, not the
    /// daily Activity totals displayed by the phone and WebApp.
    private static let liveMetrics: [VitalsMetric] = [.heartRate]

    // MARK: - Authorisation

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        // Workout share access is not optional: HKWorkoutSession refuses to
        // start without permission to write the workout it creates, even when
        // that workout is discarded at the end.
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = Set(Self.liveMetrics.compactMap { $0.quantityType as HKObjectType? })
        try await store.requestAuthorization(toShare: share, read: read)
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning, HKHealthStore.isHealthDataAvailable() else { return }
        lastError = nil

        do {
            try await requestAuthorization()

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .indoor

            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: store,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder

            let start = Date()
            session.startActivity(with: start)
            _ = try await builder.beginCollection(at: start)

            isRunning = true
            startedAt = start
        } catch {
            lastError = error.localizedDescription
            await teardown()
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        session?.end()
        await teardown()
    }

    private func teardown() async {
        if let builder {
            _ = try? await builder.endCollection(at: Date())
            // Discard, never finish. Saving would put a phantom "Other"
            // workout in Health for every relay session. discardWorkout is
            // synchronous and non-throwing, unlike its neighbours here.
            builder.discardWorkout()
        }
        builder = nil
        session = nil
        heartRate = nil
        startedAt = nil
    }

    // MARK: - Collection

    fileprivate func collect(_ types: Set<HKSampleType>, from builder: HKLiveWorkoutBuilder) {
        var batch: [VitalsSample] = []
        let now = Date()

        for metric in Self.liveMetrics {
            guard
                let type = metric.quantityType,
                types.contains(type),
                let statistics = builder.statistics(for: type)
            else { continue }

            // Live metrics are rates; the newest builder reading is the value.
            guard let quantity = statistics.mostRecentQuantity() else { continue }
            let value = metric.wireValue(from: quantity)

            heartRate = value

            batch.append(
                VitalsSample(
                    metric: metric,
                    value: value,
                    start: statistics.startDate,
                    end: statistics.endDate == statistics.startDate ? now : statistics.endDate,
                    source: .watchLive
                )
            )
        }

        guard !batch.isEmpty else { return }
        onSample?(batch)
    }
}

// HealthKit delivers these on its own queue.
extension WorkoutSessionManager: HKLiveWorkoutBuilderDelegate {

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor in self.collect(collectedTypes, from: workoutBuilder) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

extension WorkoutSessionManager: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            // watchOS can end a session on its own — low battery, or the user
            // starting a real workout in another app. Reflecting that here
            // keeps the UI honest instead of showing a session that has died.
            if toState == .ended || toState == .stopped {
                self.isRunning = false
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
            self.isRunning = false
            await self.teardown()
        }
    }
}

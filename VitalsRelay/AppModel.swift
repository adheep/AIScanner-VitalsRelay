import Combine
import Foundation
import SwiftUI
import UIKit

/// Everything the one screen needs, and the wiring between the three moving
/// parts: HealthKit in, the Watch link in, the socket out.
@MainActor
final class AppModel: ObservableObject {

    // MARK: - Settings, persisted

    @Published var endpointText: String {
        didSet { defaults.set(endpointText, forKey: Keys.endpoint) }
    }
    @Published var allowSelfSigned: Bool {
        didSet { defaults.set(allowSelfSigned, forKey: Keys.allowSelfSigned) }
    }
    /// Foreground relaying is the reliable path, and a locked phone stops
    /// relaying. Defaulting this on saves discovering that the hard way.
    @Published var keepScreenAwake: Bool {
        didSet {
            defaults.set(keepScreenAwake, forKey: Keys.keepAwake)
            applyIdleTimer()
        }
    }

    // MARK: - Live state

    @Published private(set) var isRelaying = false
    @Published private(set) var latest: [VitalsMetric: VitalsSample] = [:]
    @Published private(set) var warnings: [String] = []
    @Published private(set) var healthAuthorized = false

    let socket: VitalsSocket
    let watch: PhoneConnectivity
    private let health = HealthRelayService()
    private var bag = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let endpoint = "relay.endpoint"
        static let allowSelfSigned = "relay.allowSelfSigned"
        static let keepAwake = "relay.keepAwake"
        static let deviceId = "relay.deviceId"
    }

    var endpoint: RelayEndpoint { RelayEndpoint(raw: endpointText) }

    /// Metrics in a stable display order, so tiles do not reshuffle as
    /// readings arrive.
    var orderedLatest: [VitalsSample] {
        VitalsMetric.allCases.compactMap { latest[$0] }
    }

    init() {
        let storedEndpoint = defaults.string(forKey: Keys.endpoint) ?? ""
        endpointText = storedEndpoint
        allowSelfSigned = defaults.object(forKey: Keys.allowSelfSigned) as? Bool ?? true
        keepScreenAwake = defaults.object(forKey: Keys.keepAwake) as? Bool ?? true

        // identifierForVendor resets when every app from this vendor is
        // uninstalled, which for a sideloaded app happens every time the
        // 7-day profile lapses. Pinning it in defaults keeps the WebApp
        // seeing one stable device across reinstalls.
        let deviceId: String
        if let stored = defaults.string(forKey: Keys.deviceId) {
            deviceId = stored
        } else {
            deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            defaults.set(deviceId, forKey: Keys.deviceId)
        }

        socket = VitalsSocket(
            deviceId: deviceId,
            deviceName: UIDevice.current.name,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        )
        watch = PhoneConnectivity()

        wireUp()
    }

    private func wireUp() {
        // Nested ObservableObjects do not propagate their changes to a parent,
        // so the parent republishes them by hand. Without this the status row
        // never updates.
        socket.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        watch.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)

        health.onSamples = { [weak self] samples in
            self?.ingest(samples)
        }
        health.onWarning = { [weak self] message in
            self?.note(message)
        }
        watch.onSamples = { [weak self] samples in
            self?.ingest(samples)
        }

        watch.activate()
        applyIdleTimer()
    }

    // MARK: - Start / stop

    func start() async {
        guard !isRelaying else { return }
        guard endpoint.isValid else {
            note("Enter the address of your WebApp first.")
            return
        }

        do {
            try await health.requestAuthorization()
            healthAuthorized = true
        } catch {
            note(error.localizedDescription)
            // Keep going. The Watch link does not depend on phone HealthKit
            // authorisation, so a refusal here still leaves a working relay.
        }

        isRelaying = true
        socket.connect(to: endpoint, allowSelfSigned: allowSelfSigned)
        health.start()
        watch.setWatchRelay(active: true)
        applyIdleTimer()
    }

    func stop() {
        guard isRelaying else { return }
        isRelaying = false
        health.stop()
        watch.setWatchRelay(active: false)
        socket.disconnect()
        applyIdleTimer()
    }

    // MARK: - Data in

    private func ingest(_ samples: [VitalsSample]) {
        for sample in samples {
            // Newer readings win. A live Watch reading may also replace an
            // older HealthKit value even if clock/sync jitter gives it a
            // slightly earlier timestamp. A later HealthKit reading must be
            // allowed through after a live session ends.
            if let existing = latest[sample.metric] {
                let livePreferred = sample.source == .watchLive && existing.source != .watchLive
                let newer = sample.end >= existing.end
                guard livePreferred || newer else { continue }
            }
            latest[sample.metric] = sample
        }
        socket.enqueue(samples)
    }

    private func note(_ message: String) {
        // Deduped across the whole list, not just the tail: the same warning
        // arrives once per metric, and the list is rendered with the string
        // itself as the SwiftUI identity.
        guard !warnings.contains(message) else { return }
        warnings.append(message)
        if warnings.count > 5 {
            warnings.removeFirst(warnings.count - 5)
        }
    }

    func clearWarnings() {
        warnings.removeAll()
    }

    // MARK: - Screen

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake && isRelaying
    }
}

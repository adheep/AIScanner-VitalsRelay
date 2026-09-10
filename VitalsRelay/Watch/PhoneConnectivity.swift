import Foundation
import WatchConnectivity

/// The phone's end of the Watch link.
///
/// The watch app pushes live heart rate here rather than writing it to
/// HealthKit and waiting for a sync, which is the entire point of having a
/// watch app at all. If it never installs — sideloading a watchOS bundle is
/// unreliable — nothing here fires and the phone falls back to HealthKit on
/// its own. That degradation is silent by design.
///
/// Payloads carry JSON `Data` rather than a plist dictionary so the exact same
/// `VitalsSample` encoder is used on both sides of the link and on the socket.
@MainActor
final class PhoneConnectivity: NSObject, ObservableObject {

    /// Live samples handed over by the Watch.
    var onSamples: (([VitalsSample]) -> Void)?

    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false
    /// Last time anything at all arrived from the Watch.
    @Published private(set) var lastContact: Date?

    private var session: WCSession?

    /// Human-readable summary for the status row in the UI.
    var statusLabel: String {
        guard WCSession.isSupported() else { return "Not supported" }
        if !isPaired { return "No Watch paired" }
        if !isWatchAppInstalled { return "Watch app not installed" }
        return isReachable ? "Live" : "Paired, not reachable"
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    /// Tells the watch app to start or stop its workout session. Best effort:
    /// if the Watch is asleep or out of range this does nothing, and the user
    /// can start it from the watch face instead.
    func setWatchRelay(active: Bool) {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["command": active ? "start" : "stop"], replyHandler: nil) { _ in
            // Unreachable mid-send is expected and not worth surfacing.
        }
    }

    private func refreshState(_ session: WCSession) {
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }

    private func ingest(_ payload: [String: Any]) {
        lastContact = Date()
        guard
            let data = payload["samples"] as? Data,
            let samples = try? VitalsCoding.decoder.decode([VitalsSample].self, from: data),
            !samples.isEmpty
        else { return }
        onSamples?(samples)
    }
}

// WCSession calls back on its own queue, so every method hops to the main
// actor before touching published state.
extension PhoneConnectivity: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in self.refreshState(session) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Fires when the user switches to a different paired Watch. Reactivating
    /// is the documented requirement, not an optimisation.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshState(session) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshState(session) }
    }

    /// Live path. Delivered immediately, and wakes this app if it is backgrounded.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.ingest(message) }
    }

    /// Fallback path the Watch uses when the phone was unreachable. Queued and
    /// delivered later, so these samples are older than they look — the
    /// timestamps inside each sample remain the truth.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.ingest(userInfo) }
    }
}

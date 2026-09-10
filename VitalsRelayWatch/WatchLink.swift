import Foundation
import WatchConnectivity

/// The Watch's end of the link to the phone.
///
/// Two delivery routes, picked per batch:
///
///   sendMessage      when the phone is reachable. Immediate, and it wakes the
///                    phone app if it has been backgrounded — which is what
///                    keeps the socket alive without the phone in your hand.
///   transferUserInfo when it is not. Queued by the system and delivered on the
///                    next handshake, so a walk out of Bluetooth range loses
///                    nothing.
///
/// Batched on a one-second timer. A workout session emits heart rate at roughly
/// 1 Hz and WatchConnectivity is not cheap per message.
@MainActor
final class WatchLink: NSObject, ObservableObject {

    /// "start" / "stop", sent by the phone app.
    var onCommand: ((String) -> Void)?

    @Published private(set) var isReachable = false
    @Published private(set) var sentBatches = 0
    @Published private(set) var queuedForLater = 0

    private var session: WCSession?
    private var pending: [VitalsSample] = []
    private var timer: Timer?

    /// Ceiling on the offline queue. transferUserInfo persists across launches
    /// and will happily accumulate for hours; past this point old vitals are
    /// worth less than the delivery backlog costs.
    private let maxOutstandingTransfers = 20
    private let batchInterval: TimeInterval = 1.0

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()

        timer = Timer.scheduledTimer(withTimeInterval: batchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    func enqueue(_ samples: [VitalsSample]) {
        pending.append(contentsOf: samples)
        // One second of readings is at most a handful; anything beyond this is
        // a stalled flush, and the newest samples are the ones worth keeping.
        if pending.count > 60 {
            pending.removeFirst(pending.count - 60)
        }
    }

    private func flush() {
        guard
            let session,
            session.activationState == .activated,
            !pending.isEmpty,
            let data = try? VitalsCoding.encoder.encode(pending)
        else { return }

        let payload: [String: Any] = ["samples": data]
        pending.removeAll()

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { [weak self] _ in
                // Reachability can lapse between the check and the send. Fall
                // back rather than dropping the batch.
                Task { @MainActor in self?.queue(payload) }
            }
            sentBatches += 1
        } else {
            queue(payload)
        }
    }

    private func queue(_ payload: [String: Any]) {
        guard let session, session.outstandingUserInfoTransfers.count < maxOutstandingTransfers else { return }
        session.transferUserInfo(payload)
        queuedForLater = session.outstandingUserInfoTransfers.count
    }
}

extension WatchLink: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in self.isReachable = session.isReachable }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.isReachable = session.isReachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = message["command"] as? String else { return }
        Task { @MainActor in self.onCommand?(command) }
    }
}

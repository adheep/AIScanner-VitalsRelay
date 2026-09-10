import Foundation

/// The uplink to the WebApp.
///
/// Deliberately unclever: one URLSessionWebSocketTask, JSON text frames, an
/// exponential backoff reconnect and a small drop-oldest outbox. A phone on
/// wifi walking out of range and back is the normal case, not the exception,
/// so reconnection is the feature rather than an error path.
///
/// Samples are coalesced over a short window before sending. A workout session
/// emits heart rate roughly once a second and HealthKit can hand over several
/// metrics in the same tick; one frame per tick beats one frame per reading.
@MainActor
final class VitalsSocket: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case connecting
        case open
        /// Disconnected, will retry. Seconds remaining is for the UI only.
        case waiting(retryIn: Int)
        case failed(String)

        var isLive: Bool { self == .open }

        var label: String {
            switch self {
            case .idle:                 return "Not connected"
            case .connecting:           return "Connecting…"
            case .open:                 return "Connected"
            case .waiting(let seconds): return "Reconnecting in \(seconds)s"
            case .failed(let message):  return message
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var sentSamples = 0
    @Published private(set) var sentFrames = 0
    @Published private(set) var lastSentAt: Date?

    /// Drop-oldest bound on the outbox. Buffering more than this while offline
    /// only delays fresh readings behind stale ones nobody will look at.
    private let outboxLimit = 200
    /// Coalescing window. Long enough to batch a burst, short enough that the
    /// browser still reads as live.
    private let flushInterval: TimeInterval = 0.25
    /// Keepalive. The WebApp's uvicorn runs ws_ping_interval=20, so staying
    /// under that keeps NAT and the server's own timer both happy.
    private let pingInterval: TimeInterval = 15

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var trustDelegate: LocalTrustDelegate?

    private var outbox: [VitalsSample] = []
    private var flushTimer: Timer?
    private var pingTimer: Timer?
    private var retryTimer: Timer?
    private var retryAttempt = 0
    private var endpoint: RelayEndpoint?
    private var allowSelfSigned = true
    private var intentionallyClosed = false

    private let deviceId: String
    private let deviceName: String
    private let appVersion: String

    init(deviceId: String, deviceName: String, appVersion: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.appVersion = appVersion
        super.init()
    }

    // MARK: - Connection

    func connect(to endpoint: RelayEndpoint, allowSelfSigned: Bool) {
        guard endpoint.url != nil else {
            state = .failed(RelayError.badEndpoint(endpoint.raw).localizedDescription)
            return
        }
        self.endpoint = endpoint
        self.allowSelfSigned = allowSelfSigned
        intentionallyClosed = false
        retryAttempt = 0
        openSocket()
    }

    func disconnect() {
        intentionallyClosed = true
        teardown()
        outbox.removeAll()
        state = .idle
    }

    private func openSocket() {
        guard let url = endpoint?.url else { return }
        teardown(keepingState: true)
        state = .connecting

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15

        // A self-signed cert on a LAN box is the normal case for `run.py
        // --https`, and there is no CA on the phone that will ever vouch for
        // it. The exception is pinned to the one host the user typed.
        let delegate = LocalTrustDelegate(
            allowedHost: allowSelfSigned ? endpoint?.host : nil
        )
        trustDelegate = delegate

        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        // URLSessionWebSocketTask has no "did open" callback without adopting
        // the full delegate; the handshake is confirmed by the hello frame
        // going out without throwing.
        Task { await self.sendHello() }
        listen()
    }

    private func sendHello() async {
        let hello = HelloEnvelope(
            deviceId: deviceId,
            deviceName: deviceName,
            appVersion: appVersion,
            sentAt: Date(),
            metrics: VitalsMetric.allCases.map(\.rawValue)
        )
        do {
            try await send(VitalsCoding.encoder.encode(hello))
            state = .open
            retryAttempt = 0
            startTimers()
            flush()
        } catch {
            handleFailure(error)
        }
    }

    /// Text frames, not binary.
    ///
    /// The payload is UTF-8 JSON either way, but a text frame is what
    /// Starlette's `receive_text()` and a browser's `event.data` both expect
    /// without extra handling — and it is readable in a packet capture when
    /// something goes wrong.
    private func send(_ data: Data) async throws {
        guard let task, let json = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(json))
    }

    /// Recursive receive. The server has nothing it must say, but a socket with
    /// no reader never observes that the peer went away.
    private func listen() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.intentionallyClosed else { return }
                switch result {
                case .success:
                    // Inbound frames are ignored on purpose: this is a one-way
                    // feed, and accepting commands from the network would be a
                    // meaningfully larger surface than it is worth.
                    self.listen()
                case .failure(let error):
                    self.handleFailure(error)
                }
            }
        }
    }

    // MARK: - Sending

    func enqueue(_ samples: [VitalsSample]) {
        guard !samples.isEmpty else { return }
        outbox.append(contentsOf: samples)
        if outbox.count > outboxLimit {
            outbox.removeFirst(outbox.count - outboxLimit)
        }
    }

    private func flush() {
        guard state.isLive, !outbox.isEmpty, task != nil else { return }

        let batch = outbox
        outbox.removeAll()

        let envelope = VitalsEnvelope(
            deviceId: deviceId,
            deviceName: deviceName,
            sentAt: Date(),
            samples: batch
        )

        Task { @MainActor in
            do {
                try await self.send(VitalsCoding.encoder.encode(envelope))
                self.sentSamples += batch.count
                self.sentFrames += 1
                self.lastSentAt = Date()
            } catch {
                // Put the batch back at the front so nothing is lost to a
                // transient send failure, then let the retry path take over.
                self.outbox.insert(contentsOf: batch, at: 0)
                if self.outbox.count > self.outboxLimit {
                    self.outbox.removeFirst(self.outbox.count - self.outboxLimit)
                }
                self.handleFailure(error)
            }
        }
    }

    private func startTimers() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(
            timeInterval: flushInterval,
            target: self,
            selector: #selector(flushTimerFired),
            userInfo: nil,
            repeats: true
        )
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(
            timeInterval: pingInterval,
            target: self,
            selector: #selector(pingTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func flushTimerFired() { flush() }

    @objc private func pingTimerFired() {
        // The receive loop owns disconnect detection. The ping keeps the path
        // alive without capturing this main-actor object in a Sendable callback.
        task?.sendPing { _ in }
    }

    // MARK: - Failure and retry

    private func handleFailure(_ error: Error) {
        guard !intentionallyClosed else { return }
        // One dropped connection surfaces as several failures at once — the
        // receive loop, the in-flight send and the next ping all report it.
        // Without this guard the backoff would race through to its 30-second
        // ceiling on the first disconnect.
        if case .waiting = state { return }
        teardown(keepingState: true)
        scheduleRetry(reason: error.localizedDescription)
    }

    private func scheduleRetry(reason: String) {
        retryAttempt += 1
        // 1, 2, 4, 8, 16, capped at 30. Fast enough that stepping back into
        // wifi range reconnects while you are still looking at the screen.
        let delay = min(pow(2.0, Double(retryAttempt - 1)), 30.0)
        state = .waiting(retryIn: Int(delay))

        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(
            timeInterval: delay,
            target: self,
            selector: #selector(retryTimerFired),
            userInfo: nil,
            repeats: false
        )
        // Surface the underlying reason once, rather than replacing the
        // countdown with it — the countdown is the more useful of the two.
        if retryAttempt == 1 {
            lastFailureReason = reason
        }
    }

    /// Most recent transport error, for the diagnostics line in the UI.
    @Published private(set) var lastFailureReason: String?

    @objc private func retryTimerFired() {
        guard !intentionallyClosed else { return }
        openSocket()
    }

    private func teardown(keepingState: Bool = false) {
        flushTimer?.invalidate(); flushTimer = nil
        pingTimer?.invalidate();  pingTimer = nil
        retryTimer?.invalidate(); retryTimer = nil

        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        trustDelegate = nil

        if !keepingState { state = .idle }
    }
}

/// Accepts a self-signed certificate, but only from the exact host the user
/// typed into the endpoint field.
///
/// This is a real trust decision, so it is scoped as tightly as it can be:
/// `allowedHost` is nil when the user has not opted in, and any host other than
/// that one falls through to normal validation.
private final class LocalTrustDelegate: NSObject, URLSessionDelegate {
    private let allowedHost: String?

    init(allowedHost: String?) {
        self.allowedHost = allowedHost
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let allowedHost,
            challenge.protectionSpace.host == allowedHost,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

import Foundation

/// The address of the WebApp, and the small pile of forgiveness needed to let
/// someone type it on a phone keyboard.
///
/// All of these are accepted and mean the same thing:
///
///     192.168.1.42
///     192.168.1.42:8000
///     http://192.168.1.42:8000
///     ws://192.168.1.42:8000/ws/vitals
///     wss://desktop.local:8000/ws/vitals
///
/// Typing a full ws:// URL correctly on a phone, once, to test a LAN service is
/// a needless source of "it just says failed".
struct RelayEndpoint: Equatable {

    /// Where the WebApp is expected to accept the vitals stream. Change this if
    /// you mount the ingest route somewhere else.
    static let defaultPath = "/ws/vitals"
    static let defaultPort = 8000

    var raw: String

    init(raw: String) {
        self.raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil when the text cannot be salvaged into a URL.
    var url: URL? {
        guard !raw.isEmpty else { return nil }

        var text = raw
        // Bare host, or host:port. Percent-encoding and IPv6 brackets are the
        // caller's problem; everything else gets a scheme bolted on.
        if !text.contains("://") {
            text = "ws://" + text
        }

        guard var components = URLComponents(string: text) else { return nil }

        switch components.scheme?.lowercased() {
        case "http":        components.scheme = "ws"
        case "https":       components.scheme = "wss"
        case "ws", "wss":   break
        default:            return nil
        }

        guard let host = components.host, !host.isEmpty else { return nil }

        if components.port == nil {
            components.port = Self.defaultPort
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = Self.defaultPath
        }
        return components.url
    }

    var isValid: Bool { url != nil }

    /// The host as the TLS layer will see it, used to scope the self-signed
    /// certificate exception to exactly one machine.
    var host: String? { url?.host }

    var isSecure: Bool { url?.scheme == "wss" }

    /// What to show under the text field, so a typo is visible before connecting.
    var resolvedDescription: String {
        url?.absoluteString ?? "not a usable address"
    }
}

import Foundation
import Network

/// Une sonde de latence : le temps d'ouverture d'une connexion TCP vers un hôte.
///
/// iOS ne laisse pas une app envoyer de ping ICMP sans droits particuliers. L'ouverture
/// d'une connexion TCP donne un aller-retour réseau comparable ; la première mesure
/// compte aussi la résolution du nom.
enum LatencyProbe {
    /// L'hôte et le port à sonder, tirés de ce que l'utilisateur a saisi. Une adresse
    /// collée telle quelle (« https://www.apple.com/ ») donne son hôte ; un port écrit
    /// (« exemple.fr:8443 ») est gardé. `nil` si rien d'utilisable : pas de sonde alors,
    /// plutôt qu'une sonde qui échoue et passerait pour une perte de paquets.
    static func endpoint(from input: String) -> (host: String, port: UInt16)? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        if let end = text.firstIndex(where: { "/?#".contains($0) }) {
            text = String(text[..<end])
        }
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        var host = text
        var port: UInt16 = 443
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let value = UInt16(rest.dropFirst()), value > 0 else { return nil }
                port = value
            }
            guard !host.isEmpty, host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
            return (host, port)
        }
        if let colon = text.lastIndex(of: ":"), text.filter({ $0 == ":" }).count == 1 {
            guard let value = UInt16(text[text.index(after: colon)...]), value > 0 else { return nil }
            host = String(text[..<colon])
            port = value
        }
        let allowed = host.allSatisfy { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == ":") && !$0.isWhitespace }
        guard !host.isEmpty, allowed, !host.hasPrefix("."), !host.hasPrefix("-") else { return nil }
        return (host, port)
    }

    /// Le temps de connexion en millisecondes, ou `nil` sans réponse dans le délai.
    static func measure(host: String, port: UInt16 = 443, timeout: TimeInterval = 3) async -> Double? {
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "app.fluxa.latency-probe")
        let started = DispatchTime.now()

        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            @Sendable func finish(_ result: Double?) {
                // La continuation n'est reprise qu'une fois, quel que soit le premier arrivé.
                guard once.claim() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
                    finish(Double(elapsed) / 1_000_000)
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
            connection.start(queue: queue)
        }
    }
}

/// Un verrou à usage unique : `claim` ne renvoie `true` qu'au premier appel.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

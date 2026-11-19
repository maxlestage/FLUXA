import Foundation
import Network

/// Une sonde de latence : le temps d'ouverture d'une connexion TCP vers un hôte.
///
/// iOS ne laisse pas une app envoyer de ping ICMP sans droits particuliers. L'ouverture
/// d'une connexion TCP donne un aller-retour réseau comparable ; la première mesure
/// compte aussi la résolution du nom.
enum LatencyProbe {
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

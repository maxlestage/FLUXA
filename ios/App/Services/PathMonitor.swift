import FluxaCore
import Foundation
import Network

/// Ce que le système dit du chemin réseau courant.
struct PathDetails: Equatable {
    var kind: NetworkKind = .offline
    var isOnline = false
    /// Réseau facturé à l'usage : cellulaire ou partage de connexion d'un autre appareil.
    var isExpensive = false
    /// Mode « Données réduites » activé.
    var isConstrained = false
    /// La génération du réseau mobile (« 5G »), quand le système la donne.
    var radio: String?

    /// « Réseau mobile · 5G », « Wi-Fi »…
    var title: String {
        if kind == .cellular, let radio {
            return "\(kind.title) · \(radio)"
        }
        return kind.title
    }
}

/// Suit les changements de réseau avec `NWPathMonitor`.
@MainActor
final class PathMonitor {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "app.fluxa.path-monitor")

    func start(onChange: @escaping @MainActor (PathDetails) -> Void) {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let details = PathMonitor.details(of: path)
            Task { @MainActor in
                onChange(details)
            }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    private nonisolated static func details(of path: NWPath) -> PathDetails {
        let online = path.status == .satisfied
        let kind: NetworkKind
        if !online {
            kind = .offline
        } else if path.usesInterfaceType(.wifi) {
            kind = .wifi
        } else if path.usesInterfaceType(.cellular) {
            kind = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            kind = .wired
        } else {
            kind = .other
        }
        return PathDetails(
            kind: kind,
            isOnline: online,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            radio: kind == .cellular ? RadioTechnology.current() : nil
        )
    }
}

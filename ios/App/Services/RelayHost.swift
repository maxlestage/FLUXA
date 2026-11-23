import FluxaCore
import Foundation
import NetworkExtension

/// Les plafonds à donner au relais, en bits par seconde. `nil` : sans plafond.
struct RelayLimits: Equatable {
    var download: UInt64?
    var upload: UInt64?
    /// Par adresse. Un appareil sans plafond dans les deux sens voit le sien retiré.
    var devices: [String: (download: UInt64?, upload: UInt64?)] = [:]

    static func == (lhs: RelayLimits, rhs: RelayLimits) -> Bool {
        lhs.download == rhs.download && lhs.upload == rhs.upload
            && lhs.devices.keys.sorted() == rhs.devices.keys.sorted()
            && lhs.devices.allSatisfy { key, value in
                rhs.devices[key]?.download == value.download && rhs.devices[key]?.upload == value.upload
            }
    }

    /// Le message que comprend l'extension (voir PacketTunnelProvider).
    var message: Data {
        let devices = self.devices.keys.sorted().map { address -> [String: Any] in
            let limit = self.devices[address]!
            return ["address": address, "download": limit.download ?? 0, "upload": limit.upload ?? 0]
        }
        let body: [String: Any] = [
            "command": "limits", "download": download ?? 0, "upload": upload ?? 0, "devices": devices,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }
}

/// Là où tourne le relais : dans l'app, ou dans l'extension réseau.
@MainActor
protocol RelayHost: AnyObject {
    /// Vrai si le relais continue quand FLUXA passe en arrière-plan.
    var keepsRunningInBackground: Bool { get }
    /// Ouvre le relais avec ces plafonds. Renvoie un message d'erreur, ou `nil`.
    func open(limits: RelayLimits) async -> String?
    func close() async
    func apply(_ limits: RelayLimits) async
    func status() async -> RelayStatus?
    /// Vrai si le relais est déjà en service (extension restée active).
    func isRunning() async -> Bool
}

/// Le relais dans le processus de l'app : il s'arrête quand iOS suspend l'app.
@MainActor
final class InAppRelayHost: RelayHost {
    let keepsRunningInBackground = false
    private let allowLoopback: Bool

    init(allowLoopback: Bool) {
        self.allowLoopback = allowLoopback
    }

    func open(limits: RelayLimits) async -> String? {
        let code = RelayBridge.start(allowLoopback: allowLoopback)
        guard code == 0 else { return AppModel.relayProblem(code) }
        await apply(limits)
        return nil
    }

    func close() async {
        RelayBridge.stop()
    }

    func apply(_ limits: RelayLimits) async {
        RelayBridge.setLimit(downloadBps: limits.download, uploadBps: limits.upload)
        for (address, limit) in limits.devices {
            RelayBridge.setDeviceLimit(address: address, downloadBps: limit.download, uploadBps: limit.upload)
        }
    }

    func status() async -> RelayStatus? {
        RelayBridge.status()
    }

    func isRunning() async -> Bool {
        RelayBridge.status()?.running == true
    }
}

/// Le relais dans l'extension réseau : il reste en service en arrière-plan, signalé par
/// l'icône VPN. Le tunnel ne transporte aucun trafic de l'iPhone.
@MainActor
final class TunnelRelayHost: RelayHost {
    let keepsRunningInBackground = true
    private var manager: NETunnelProviderManager?

    private static var extensionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "app.fluxa.ios") + ".relay"
    }

    /// Vrai si la configuration du relais est installée (l'utilisateur l'a autorisée).
    static func isConfigured() async -> Bool {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        return managers.contains {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionIdentifier
        }
    }

    /// Installe la configuration du relais sans l'ouvrir : iOS demande l'autorisation la
    /// première fois. Renvoie `true` si elle est installée.
    static func installConfiguration() async -> Bool {
        (try? await TunnelRelayHost().loadManager(limits: nil)) != nil
    }

    private func loadManager(limits: RelayLimits?) async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first ?? NETunnelProviderManager()
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = Self.extensionIdentifier
        configuration.serverAddress = "Relais de partage"
        if let limits {
            configuration.providerConfiguration = ["limits": limits.message]
        }
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "Relais de partage FLUXA"
        manager.isEnabled = true
        // La première fois, iOS demande l'autorisation d'ajouter la configuration.
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        return manager
    }

    func open(limits: RelayLimits) async -> String? {
        do {
            let manager = try await loadManager(limits: limits)
            if manager.connection.status != .connected {
                try manager.connection.startVPNTunnel()
            }
            // Juste après la demande, l'état peut encore se lire « déconnecté » : seul un
            // arrêt après un début de connexion, ou une configuration invalide, est un échec.
            let deadline = Date().addingTimeInterval(15)
            var started = false
            while manager.connection.status != .connected, Date() < deadline {
                switch manager.connection.status {
                case .connecting, .reasserting:
                    started = true
                case .invalid:
                    return "La configuration du relais est invalide."
                case .disconnected, .disconnecting:
                    if started {
                        let reason = await Self.lastError(of: manager)
                        return "L’extension du relais s’est arrêtée au démarrage\(reason)."
                    }
                default:
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard manager.connection.status == .connected else {
                let reason = await Self.lastError(of: manager)
                return "L’extension du relais n’a pas démarré à temps\(reason)."
            }
            await apply(limits)
            return nil
        } catch {
            let nsError = error as NSError
            if nsError.domain == NEVPNErrorDomain, nsError.code == NEVPNError.configurationReadWriteFailed.rawValue {
                return "Autorisation refusée : acceptez l’ajout de la configuration du relais pour qu’il tourne en arrière-plan."
            }
            return "L’extension du relais n’a pas pu démarrer (\(error.localizedDescription))."
        }
    }

    /// La raison du dernier arrêt du tunnel donnée par iOS, en fin de phrase, ou rien.
    private static func lastError(of manager: NETunnelProviderManager) async -> String {
        let error: Error? = await withCheckedContinuation { continuation in
            manager.connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error)
            }
        }
        guard let error else { return "" }
        return " (\(error.localizedDescription))"
    }

    func close() async {
        if manager == nil {
            manager = try? await NETunnelProviderManager.loadAllFromPreferences().first
        }
        manager?.connection.stopVPNTunnel()
    }

    func apply(_ limits: RelayLimits) async {
        _ = await send(limits.message)
    }

    func status() async -> RelayStatus? {
        guard let data = await send(Data(#"{"command":"status"}"#.utf8)) else { return nil }
        return RelayStatus.decode(data)
    }

    func isRunning() async -> Bool {
        if manager == nil {
            manager = try? await NETunnelProviderManager.loadAllFromPreferences().first
        }
        return manager?.connection.status == .connected
    }

    private func send(_ message: Data) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(message) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

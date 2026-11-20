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
            // Le tunnel se connecte en une à deux secondes.
            for _ in 0..<40 where manager.connection.status != .connected {
                try await Task.sleep(for: .milliseconds(250))
                if manager.connection.status == .disconnected || manager.connection.status == .invalid {
                    return "L’extension du relais n’a pas démarré."
                }
            }
            guard manager.connection.status == .connected else {
                return "L’extension du relais ne répond pas."
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
        return RelayStatus.decode(String(decoding: data, as: UTF8.self))
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

import FluxaShaper
import Foundation
import NetworkExtension

/// L'extension réseau qui garde le relais de partage en service quand FLUXA est en
/// arrière-plan.
///
/// iOS suspend les apps en arrière-plan, mais laisse tourner une extension de tunnel tant
/// que l'utilisateur la garde active. Le relais Rust (ios/Shaper/src/relay.rs) tourne donc
/// ici. Le tunnel lui-même ne transporte rien : aucune route ne lui est confiée, le trafic
/// de l'iPhone continue en direct. L'icône VPN signale que le relais est en service.
///
/// L'app pilote l'extension par messages JSON (`sendProviderMessage`) :
///   {"command":"status"}
///   {"command":"limits","download":bps,"upload":bps,"devices":[{"address":"…","download":bps,"upload":bps}]}
/// La réponse est l'état du relais (JSON de `fluxa_relay_status`).
final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let port: UInt16 = 8888

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        let code = fluxa_relay_start(Self.port, 0)
        guard code == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        // Les plafonds enregistrés avec la configuration : un redémarrage du tunnel par le
        // système les retrouve sans l'app.
        if let stored = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["limits"] as? Data {
            apply(stored)
        }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.255"])
        // Aucune route : le tunnel ne transporte pas le trafic de l'iPhone.
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        try await setTunnelNetworkSettings(settings)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        fluxa_relay_stop()
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
            return nil
        }
        if message["command"] as? String == "limits" {
            apply(messageData)
        }
        guard let pointer = fluxa_relay_status() else { return nil }
        defer { fluxa_shaper_free(pointer) }
        return Data(String(cString: pointer).utf8)
    }

    /// Applique un message de plafonds : le plafond global, puis celui de chaque appareil
    /// (zéro dans les deux sens : le plafond de l'appareil est retiré).
    private func apply(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        fluxa_relay_set_limit(Self.number(message["download"]), Self.number(message["upload"]))
        for device in message["devices"] as? [[String: Any]] ?? [] {
            guard let address = device["address"] as? String else { continue }
            _ = fluxa_relay_set_device_limit(address, Self.number(device["download"]), Self.number(device["upload"]))
        }
    }

    private static func number(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }
}

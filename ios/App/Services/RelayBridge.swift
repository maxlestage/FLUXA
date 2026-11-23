import FluxaShaper
import Foundation

/// Le relais de partage, écrit en Rust (ios/Shaper/src/relay.rs) et piloté par son ABI C.
///
/// Un mandataire HTTP, HTTPS et SOCKS5 sur l'iPhone : les appareils du partage de
/// connexion réglés sur lui y font passer leur trafic, que le relais plafonne et compte
/// par appareil. Il ne sert que les appareils du partage.
enum RelayBridge {
    /// Le port du relais.
    static let port: UInt16 = 8888

    /// L'adresse que l'iPhone prend sur le réseau du partage de connexion.
    static let defaultAddress = "172.20.10.1"

    /// Ouvre le relais. Renvoie 0, ou le code d'erreur du système.
    static func start(allowLoopback: Bool) -> Int32 {
        fluxa_relay_start(port, allowLoopback ? 1 : 0)
    }

    static func stop() {
        fluxa_relay_stop()
    }

    /// Le plafond de tout le trafic relayé. `nil` : sans plafond.
    static func setLimit(downloadBps: UInt64?, uploadBps: UInt64?) {
        fluxa_relay_set_limit(downloadBps ?? 0, uploadBps ?? 0)
    }

    /// Le plafond d'un appareil. `nil` dans les deux sens : le plafond est retiré.
    @discardableResult
    static func setDeviceLimit(address: String, downloadBps: UInt64?, uploadBps: UInt64?) -> Int32 {
        fluxa_relay_set_device_limit(address, downloadBps ?? 0, uploadBps ?? 0)
    }

    static func status() -> RelayStatus? {
        guard let pointer = fluxa_relay_status() else { return nil }
        defer { fluxa_shaper_free(pointer) }
        // Une seule copie : les octets du relais vont droit au décodeur.
        return RelayStatus.decode(Data(bytes: pointer, count: strlen(pointer)))
    }
}

/// L'état du relais. Les plafonds sont en octets par seconde, zéro : sans plafond.
struct RelayStatus: Decodable, Equatable {
    struct Client: Decodable, Equatable, Identifiable {
        let address: String
        let connections: Int
        let toDeviceBytes: UInt64
        let fromDeviceBytes: UInt64
        let idleSeconds: Double
        let downloadLimit: UInt64
        let uploadLimit: UInt64

        var id: String { address }

        enum CodingKeys: String, CodingKey {
            case address, connections
            case toDeviceBytes = "to_device_bytes"
            case fromDeviceBytes = "from_device_bytes"
            case idleSeconds = "idle_seconds"
            case downloadLimit = "download_limit"
            case uploadLimit = "upload_limit"
        }
    }

    let running: Bool
    let port: UInt16?
    /// Les connexions relayées en ce moment, et leur maximum (au-delà, refusées).
    let activeConnections: Int?
    let maxConnections: Int?
    let downloadLimit: UInt64?
    let uploadLimit: UInt64?
    let addresses: [String]?
    let clients: [Client]?

    enum CodingKeys: String, CodingKey {
        case running, port, addresses, clients
        case activeConnections = "active_connections"
        case maxConnections = "max_connections"
        case downloadLimit = "download_limit"
        case uploadLimit = "upload_limit"
    }

    /// Le décodeur, gardé d'un relevé à l'autre. Les clés du relais sont écrites une fois
    /// pour toutes : aucune n'est convertie à la volée à chaque relevé.
    static let decoder = JSONDecoder()

    static func decode(_ data: Data) -> RelayStatus? {
        try? decoder.decode(RelayStatus.self, from: data)
    }

    static func decode(_ json: String) -> RelayStatus? {
        decode(Data(json.utf8))
    }

    /// L'adresse à donner aux appareils : celle du pont du partage, ou l'adresse habituelle.
    var address: String {
        addresses?.first ?? RelayBridge.defaultAddress
    }
}

/// Le débit d'un appareil relayé, calculé entre deux relevés de l'état du relais.
struct RelayRate: Equatable {
    var toDeviceBps: Double?
    var fromDeviceBps: Double?

    /// Le débit entre deux cumuls, ou `nil` si un compteur a reculé (relais rouvert).
    static func between(
        _ before: RelayStatus.Client?, _ after: RelayStatus.Client, seconds: Double
    ) -> RelayRate {
        guard let before, seconds > 0,
              after.toDeviceBytes >= before.toDeviceBytes,
              after.fromDeviceBytes >= before.fromDeviceBytes
        else { return RelayRate() }
        return RelayRate(
            toDeviceBps: Double(after.toDeviceBytes - before.toDeviceBytes) * 8 / seconds,
            fromDeviceBps: Double(after.fromDeviceBytes - before.fromDeviceBytes) * 8 / seconds
        )
    }
}

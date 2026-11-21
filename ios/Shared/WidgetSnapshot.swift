import Foundation
import Security

/// Ce que l'app laisse aux widgets : son dernier relevé, et son heure.
///
/// Un widget ne mesure rien lui-même : iOS ne lui en donne pas les moyens. Il affiche ce
/// relevé, que l'app range dans un trousseau partagé par les apps de l'équipe, avec l'heure
/// à laquelle il a été fait. Sans relevé, il invite à ouvrir FLUXA.
struct WidgetSnapshot: Codable, Equatable {
    struct Plan: Codable, Equatable {
        var usedBytes: UInt64
        var allowanceBytes: UInt64
        var remainingBytes: UInt64
        var fractionUsed: Double
        var cycleEnd: Date
    }

    struct Relay: Codable, Equatable {
        /// Les appareils qui passaient par le relais au moment du relevé.
        var devices: Int
        var toDevicesBps: Double?
        var cap: String
    }

    var updatedAt: Date
    var network: String
    var isOnline: Bool
    var downloadBps: Double?
    var uploadBps: Double?
    var todayBytes: UInt64
    var plan: Plan?
    var relay: Relay?

    /// Le relevé en JSON, tel qu'il est rangé.
    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data?) -> WidgetSnapshot? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Le dernier relevé rangé par l'app, ou `nil`.
    static func load() -> WidgetSnapshot? {
        decode(SharedKeychain.read())
    }

    /// Range le relevé pour les widgets. Renvoie `false` si le trousseau partagé n'est pas
    /// disponible (app non signée, dans le simulateur par exemple).
    @discardableResult
    func publish() -> Bool {
        guard let data = encoded() else { return false }
        return SharedKeychain.write(data)
    }

    /// Un relevé d'exemple, pour l'aperçu de la galerie des widgets. Il n'est jamais
    /// montré comme une mesure réelle.
    static let example = WidgetSnapshot(
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        network: "Réseau mobile · 5G",
        isOnline: true,
        downloadBps: 42_800_000,
        uploadBps: 8_400_000,
        todayBytes: 1_240_000_000,
        plan: Plan(
            usedBytes: 12_400_000_000, allowanceBytes: 50_000_000_000, remainingBytes: 37_600_000_000,
            fractionUsed: 0.248, cycleEnd: Date(timeIntervalSince1970: 1_801_000_000)),
        relay: nil
    )
}

/// Le trousseau partagé par l'app et ses widgets.
///
/// Un groupe de trousseau préfixé par l'identifiant de l'équipe est autorisé d'office pour
/// toutes les apps de l'équipe : il ne demande aucun enregistrement sur le portail Apple,
/// contrairement à un groupe d'apps. Le relevé reste lisible écran verrouillé, pour les
/// widgets de l'écran verrouillé.
enum SharedKeychain {
    private static let service = "fluxa.widgets"
    private static let account = "snapshot"

    /// Le groupe (clé `FluxaKeychainGroup` des Info.plist : « ÉQUIPE.fluxa.shared »).
    static var group: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FluxaKeychainGroup") as? String,
              !group.hasPrefix(".")
        else { return nil }
        return group
    }

    private static func query(_ group: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
        ]
    }

    static func read() -> Data? {
        guard let group else { return nil }
        var request = query(group)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data) -> Bool {
        guard let group else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query(group) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = query(group).merging(attributes) { _, new in new }
            return SecItemAdd(added as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

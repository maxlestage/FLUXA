import Foundation

/// Ce que l'app laisse aux widgets : son dernier relevé, et son heure.
///
/// Un widget ne mesure rien lui-même : iOS ne lui en donne pas les moyens. Il affiche ce
/// relevé, enregistré par l'app dans le conteneur partagé (groupe d'apps), avec l'heure à
/// laquelle il a été fait. Sans relevé, il invite à ouvrir FLUXA.
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

    static let key = "widgetSnapshot"

    /// Le groupe d'apps partagé par l'app et ses widgets (clé `FluxaAppGroup` des Info.plist).
    static var groupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "FluxaAppGroup") as? String
    }

    static var store: UserDefaults? {
        groupIdentifier.flatMap { UserDefaults(suiteName: $0) }
    }

    static func load(from defaults: UserDefaults? = store) -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    @discardableResult
    func save(to defaults: UserDefaults? = WidgetSnapshot.store) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let defaults, let data = try? encoder.encode(self) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
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

import ActivityKit
import Foundation

/// L'activité en direct du relais de partage : sur l'écran verrouillé et dans la Dynamic
/// Island, tant que le relais est ouvert.
///
/// Une app suspendue ne peut pas mettre à jour son activité, et FLUXA n'a pas de serveur
/// pour le faire à sa place. L'activité montre donc depuis quand le relais est ouvert (le
/// système fait avancer ce compteur seul) et le dernier relevé de l'app, avec son ancienneté.
struct RelayActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Les appareils qui passaient par le relais au dernier relevé.
        var devices: Int
        var toDevicesBps: Double?
        /// Le plafond du trafic relayé, en texte (« ↓ 5 Mb/s · ↑ 2 Mb/s », « Sans plafond »).
        var cap: String
        var updatedAt: Date
    }

    /// L'ouverture du relais.
    var startedAt: Date
}

/// Les phrases de l'activité, séparées des vues pour être testées.
enum RelayActivityText {
    static func devices(_ count: Int) -> String {
        switch count {
        case 0: "Aucun appareil"
        case 1: "1 appareil"
        default: "\(count) appareils"
        }
    }

    /// Le débit vers les appareils, ou un tiret s'il n'est pas mesuré.
    static func rate(_ bps: Double?) -> String {
        Format.rate(bps)
    }

    /// Les appareils et leur débit, pour VoiceOver : « 2 appareils, 3,4 Mb/s vers eux ».
    static func spokenTraffic(_ state: RelayActivityAttributes.ContentState) -> String {
        let devices = Self.devices(state.devices)
        guard state.devices > 0 else { return devices }
        guard let bps = state.toDevicesBps else { return devices + ", débit vers eux non mesuré" }
        return devices + ", \(Format.rate(bps)) vers \(state.devices > 1 ? "eux" : "lui")"
    }

    /// Le débit seul, pour VoiceOver, là où les appareils sont dits à côté.
    static func spokenRate(_ bps: Double?) -> String {
        bps.map { "Débit vers les appareils : \(Format.rate($0))" } ?? "Débit vers les appareils non mesuré"
    }

    /// Le plafond, pour VoiceOver : les flèches et le point médian deviennent des mots.
    static func spokenCap(_ cap: String) -> String {
        guard cap.contains("↓") || cap.contains("↑") else { return cap }
        return "Plafond : "
            + cap.replacingOccurrences(of: "↓", with: "descendant")
            .replacingOccurrences(of: "↑", with: "montant")
            .replacingOccurrences(of: " · ", with: ", ")
    }
}

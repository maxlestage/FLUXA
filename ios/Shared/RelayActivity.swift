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
}

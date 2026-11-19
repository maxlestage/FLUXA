import CoreTelephony
import Foundation

/// La génération du réseau mobile (4G, 5G…), telle que CoreTelephony la donne.
enum RadioTechnology {
    private static let info = CTTelephonyNetworkInfo()

    /// `nil` sans carte SIM active, en Wi-Fi seul sur un appareil sans réseau mobile, ou
    /// dans le simulateur : l'app affiche alors « Réseau mobile », sans deviner.
    static func current() -> String? {
        guard let technologies = info.serviceCurrentRadioAccessTechnology else { return nil }
        // Avec deux lignes, la ligne de données est celle que le système désigne.
        let identifier = info.dataServiceIdentifier ?? technologies.keys.sorted().first
        guard let identifier, let technology = technologies[identifier] else { return nil }
        return generation(of: technology)
    }

    static func generation(of technology: String) -> String? {
        switch technology {
        case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA:
            "5G"
        case CTRadioAccessTechnologyLTE:
            "4G"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD:
            "3G"
        case CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyCDMA1x:
            "2G"
        default:
            nil
        }
    }
}

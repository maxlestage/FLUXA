import FluxaCore

// Les noms français de ce que le moteur renvoie.

extension NetworkKind {
    var title: String {
        switch self {
        case .offline: "Hors ligne"
        case .wifi: "Wi-Fi"
        case .cellular: "Réseau mobile"
        case .wired: "Ethernet"
        case .other: "Autre réseau"
        }
    }
}

extension NetworkKind {
    /// La famille d'interfaces qui porte ce réseau.
    var interfaceClass: InterfaceClass? {
        switch self {
        case .wifi: .wifi
        case .cellular: .cellular
        case .wired: .wired
        case .other: .other
        case .offline: nil
        }
    }
}

extension InterfaceClass {
    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .cellular: "Réseau mobile"
        case .wired: "Ethernet"
        case .other: "Autre"
        case .sharing: "Partage de connexion"
        }
    }
}

extension ApplyStatus {
    var title: String {
        switch self {
        case .applied: "Appliqué"
        case .partial: "Partiel"
        case .simulated: "Simulé"
        case .unsupported: "Réservé à iOS"
        }
    }

    var pill: StatusPill.Kind {
        switch self {
        case .applied: .supported
        case .partial, .simulated: .simulated
        case .unsupported: .reserved
        }
    }
}

extension Support {
    var title: String {
        switch self {
        case .supported: "Pris en charge"
        case .conditional: "Sous conditions"
        case .unsupported: "Réservé à iOS"
        }
    }

    var pill: StatusPill.Kind {
        switch self {
        case .supported: .supported
        case .conditional: .simulated
        case .unsupported: .reserved
        }
    }
}

extension LimitMode {
    var title: String {
        switch self {
        case .hardLimit: "Plafond strict"
        case .softLimit: "Débit cible"
        case .fairShare: "Partage équitable"
        case .priority: "Priorités"
        case .scheduled: "Plage horaire"
        case .emergency: "Réduction d’urgence"
        }
    }
}

extension Capability {
    var title: String {
        switch self {
        case .internetMonitoring: "Mesurer la connexion de l’iPhone"
        case .speedTest: "Tester le débit Internet"
        case .charts: "Tracer les graphiques et l’historique"
        case .profiles: "Gérer des profils de débit"
        case .localVPN: "Créer un VPN local facultatif"
        case .hotspotActivation: "Activer le partage depuis une app"
        case .hotspotClientDiscovery: "Identifier les appareils connectés"
        case .hotspotLimit: "Limiter le débit du partage"
        case .perDeviceShaping: "Limiter un appareil en particulier"
        case .clientDisconnect: "Déconnecter un appareil du partage"
        }
    }
}

extension EngineEvent.Level {
    var title: String {
        switch self {
        case .info: "Info"
        case .warning: "Attention"
        case .error: "Erreur"
        }
    }
}

extension DeviceKind {
    var title: String {
        switch self {
        case .computer: "Ordinateur"
        case .phone: "Téléphone"
        case .tablet: "Tablette"
        case .television: "Téléviseur"
        case .console: "Console"
        case .other: "Autre"
        }
    }

    /// Le symbole SF qui le représente.
    var symbol: String {
        switch self {
        case .computer: "laptopcomputer"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .television: "tv"
        case .console: "gamecontroller"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}

import Foundation

// Les règles fixes du moteur : préréglages, bornes, capacités d'iOS, simulation.

enum Rules {
    // MARK: Profils

    /// Les sept préréglages de la V1. Des points de départ modifiables, pas des
    /// débits garantis.
    static let builtinProfiles: [Profile] = [
        preset("economy", "Économie", 1, 0.5),
        preset("very-slow", "Très lent", 2, 1),
        preset("browsing", "Navigation", 5, 2),
        preset("standard", "Standard", 15, 5),
        preset("streaming", "Streaming", 25, 10),
        preset("performance", "Performance", 50, 20),
        Profile(id: "maximum", name: "Maximum", downloadBps: nil, uploadBps: nil, isBuiltin: true),
    ]

    private static func preset(_ id: String, _ name: String, _ down: Double, _ up: Double) -> Profile {
        Profile(
            id: id,
            name: name,
            downloadBps: Limits.bps(fromMbps: down),
            uploadBps: Limits.bps(fromMbps: up),
            isBuiltin: true
        )
    }

    // MARK: Validation

    /// Vérifie un plafond en bit/s. `nil` : sans plafond.
    static func validate(bps: UInt64?) throws {
        guard let bps else { return }
        guard (Limits.minimumBps...Limits.maximumBps).contains(bps) else {
            throw FluxaError.rateOutOfRange(bps: bps)
        }
    }

    static func validate(_ policy: BandwidthPolicy) throws {
        try validate(bps: policy.downloadBps)
        try validate(bps: policy.uploadBps)
        if let seconds = policy.durationSeconds, seconds < Limits.minimumDurationSeconds {
            throw FluxaError.durationTooShort(seconds: seconds)
        }
    }

    /// Convertit un plafond saisi en Mb/s. Une valeur qui n'est pas un nombre, négative
    /// ou hors de la plage est refusée avant toute conversion.
    static func bps(fromMbps mbps: Double?) throws -> UInt64? {
        guard let mbps else { return nil }
        guard mbps.isFinite, mbps >= 0 else {
            throw FluxaError.rateOutOfRange(bps: 0)
        }
        guard mbps <= Limits.mbps(fromBps: Limits.maximumBps) else {
            throw FluxaError.rateOutOfRange(bps: mbps < 1e12 ? Limits.bps(fromMbps: mbps) : .max)
        }
        let bps = Limits.bps(fromMbps: mbps)
        try validate(bps: bps)
        return bps
    }

    // MARK: Simulation

    /// L'effet d'un plafond sur un débit mesuré. Un débit cible (`softLimit`) laisse
    /// utiliser la bande passante disponible : sur un flux seul, il ne réduit rien.
    static func effect(measuredBps: Double?, capBps: UInt64?, mode: LimitMode) -> DirectionEffect? {
        guard let measuredBps else { return nil }
        var result = measuredBps
        if let capBps, mode != .softLimit {
            result = min(measuredBps, Double(capBps))
        }
        return DirectionEffect(measuredBps: measuredBps, capBps: capBps, resultBps: result)
    }

    // MARK: Limites

    static let globalLimitReason =
        "iOS ne laisse aucune app limiter le débit du partage de connexion. "
        + "Le plafond est enregistré et son effet est simulé, rien n’est appliqué."

    static let deviceLimitReason =
        "iOS ne laisse aucune app limiter un appareil relié au partage de connexion. "
        + "La demande est enregistrée, sans effet."

    // MARK: Capacités

    /// Ce qu'une app ordinaire peut faire sur iPhone.
    static func status(of capability: Capability) -> CapabilityStatus {
        let (support, note): (Support, String) = {
            switch capability {
            case .internetMonitoring:
                return (.supported, "L’app mesure la connexion de l’iPhone à partir des compteurs du système.")
            case .speedTest:
                return (.supported, "Une app peut mesurer le débit Internet de l’iPhone.")
            case .charts:
                return (.supported, "Les mesures s’affichent en graphiques, en direct et dans l’historique.")
            case .profiles:
                return (.supported, "Les profils de débit se règlent et s’enregistrent dans l’app.")
            case .localVPN:
                return (
                    .conditional,
                    "Possible avec une extension réseau et votre accord. Un VPN local ne traite que le trafic de l’iPhone, pas celui du partage."
                )
            case .hotspotActivation:
                return (.unsupported, "iOS réserve l’activation du partage de connexion à l’utilisateur, dans Réglages.")
            case .hotspotClientDiscovery:
                return (.unsupported, "iOS ne fournit pas la liste des appareils reliés au partage de connexion.")
            case .hotspotLimit:
                return (.unsupported, "iOS ne laisse aucune app agir sur le trafic du partage de connexion.")
            case .perDeviceShaping:
                return (.unsupported, "iOS ne laisse aucune app limiter un appareil relié au partage.")
            case .clientDisconnect:
                return (.unsupported, "iOS ne laisse aucune app déconnecter un appareil du partage.")
            }
        }()
        return CapabilityStatus(capability: capability, support: support, note: note)
    }

    /// Les cinq clés du cahier des charges, dans son ordre. `true` : possible sur
    /// iPhone, y compris sous conditions ; `false` : réservé au système.
    static let jsonCapabilities: [(key: String, capability: Capability)] = [
        ("internet_monitoring", .internetMonitoring),
        ("hotspot_activation", .hotspotActivation),
        ("hotspot_client_discovery", .hotspotClientDiscovery),
        ("per_device_shaping", .perDeviceShaping),
        ("local_vpn", .localVPN),
    ]

    static func capabilitiesJSON() -> String {
        let lines = jsonCapabilities.map { entry -> String in
            let possible = status(of: entry.capability).support != .unsupported
            return "    \"\(entry.key)\": \(possible)"
        }
        return """
            {
              "platform": "ios",
              "capabilities": {
            \(lines.joined(separator: ",\n"))
              }
            }
            """
    }
}

extension FluxaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rateOutOfRange:
            return "Le plafond doit être compris entre 0,1 et 1 000 Mb/s."
        case .durationTooShort:
            return "La durée doit être d’au moins une minute."
        case .emptyName:
            return "Donnez un nom au profil."
        case .unknownProfile:
            return "Ce profil n’existe plus."
        case .builtinProfile:
            return "Un préréglage se modifie, mais ne se supprime pas."
        case .invalidRule(let reason):
            return reason
        case .store(let detail):
            return "Les données n’ont pas pu être enregistrées : \(detail)"
        }
    }
}

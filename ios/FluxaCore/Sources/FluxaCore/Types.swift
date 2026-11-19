import Foundation

// Les types publics de FluxaCore : ce que l'interface lit et envoie au moteur.
// Les débits sont en bits par seconde, les volumes en octets.

// MARK: - Réseau

/// Le réseau par lequel l'iPhone sort sur Internet.
public enum NetworkKind: String, Codable, CaseIterable, Sendable {
    case offline, wifi, cellular, wired, other
}

/// La famille d'une interface réseau.
public enum InterfaceClass: String, Codable, CaseIterable, Sendable {
    case wifi, cellular, wired, other
    /// Le pont du partage de connexion vers les appareils reliés. Il ne porte pas le
    /// trafic Internet de l'iPhone : le moteur le suit à part (voir `Plan.swift`).
    case sharing
}

/// La largeur des compteurs d'octets fournis par le système. Un compteur de 32 bits
/// repasse par zéro tous les 4 Go : le moteur en tient compte.
public enum CounterWidth: Sendable {
    case bits32, bits64
}

/// Un relevé des compteurs d'une interface, cumulés depuis le démarrage de l'appareil.
public struct InterfaceReading: Equatable, Sendable {
    public let name: String
    public let kind: InterfaceClass
    public let receivedBytes: UInt64
    public let sentBytes: UInt64

    public init(name: String, kind: InterfaceClass, receivedBytes: UInt64, sentBytes: UInt64) {
        self.name = name
        self.kind = kind
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

/// L'état du réseau à un instant. Une valeur absente n'a pas encore été mesurée :
/// l'interface l'affiche comme telle, jamais comme un zéro.
public struct NetworkSnapshot: Equatable, Sendable {
    public var kind: NetworkKind
    public var isOnline: Bool
    public var isMonitoring: Bool
    public var downloadBps: Double?
    public var uploadBps: Double?
    public var latencyMs: Double?
    public var jitterMs: Double?
    /// Part des sondes de latence restées sans réponse, de 0 à 100.
    public var packetLossPercent: Double?
    /// Les octets reçus et envoyés depuis minuit, d'après les compteurs relevés.
    public var receivedBytesToday: UInt64
    public var sentBytesToday: UInt64
    public var measuredAt: Date?

    public init(
        kind: NetworkKind = .offline,
        isOnline: Bool = false,
        isMonitoring: Bool = false,
        downloadBps: Double? = nil,
        uploadBps: Double? = nil,
        latencyMs: Double? = nil,
        jitterMs: Double? = nil,
        packetLossPercent: Double? = nil,
        receivedBytesToday: UInt64 = 0,
        sentBytesToday: UInt64 = 0,
        measuredAt: Date? = nil
    ) {
        self.kind = kind
        self.isOnline = isOnline
        self.isMonitoring = isMonitoring
        self.downloadBps = downloadBps
        self.uploadBps = uploadBps
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.packetLossPercent = packetLossPercent
        self.receivedBytesToday = receivedBytesToday
        self.sentBytesToday = sentBytesToday
        self.measuredAt = measuredAt
    }
}

/// Un débit mesuré, pour la courbe en direct.
public struct ThroughputSample: Identifiable, Equatable, Sendable {
    public let date: Date
    public let downloadBps: Double
    public let uploadBps: Double
    public var id: Date { date }

    public init(date: Date, downloadBps: Double, uploadBps: Double) {
        self.date = date
        self.downloadBps = downloadBps
        self.uploadBps = uploadBps
    }
}

// MARK: - Limites

/// La façon de limiter.
public enum LimitMode: String, Codable, CaseIterable, Sendable {
    case hardLimit, softLimit, fairShare, priority, scheduled, emergency
}

/// Un plafond demandé. `nil` : pas de plafond dans ce sens, ou pas de limite de durée.
public struct BandwidthPolicy: Codable, Equatable, Sendable {
    public var downloadBps: UInt64?
    public var uploadBps: UInt64?
    public var mode: LimitMode
    public var durationSeconds: UInt64?

    public init(
        downloadBps: UInt64? = nil,
        uploadBps: UInt64? = nil,
        mode: LimitMode = .hardLimit,
        durationSeconds: UInt64? = nil
    ) {
        self.downloadBps = downloadBps
        self.uploadBps = uploadBps
        self.mode = mode
        self.durationSeconds = durationSeconds
    }
}

/// Ce que le système a réellement fait d'une demande.
public enum ApplyStatus: String, Codable, CaseIterable, Sendable {
    /// Le système a confirmé l'application.
    case applied
    /// Une partie seulement est appliquée.
    case partial
    /// Rien n'est appliqué : l'app montre l'effet qu'aurait le plafond.
    case simulated
    /// Le système ne permet pas cette opération.
    case unsupported
}

/// La réponse à une demande de limite. `effective` reste `nil` tant que le système
/// n'a pas confirmé : une règle configurée n'est jamais présentée comme appliquée.
public struct ApplyResult: Codable, Equatable, Sendable {
    public var requested: BandwidthPolicy
    public var effective: BandwidthPolicy?
    public var status: ApplyStatus
    /// Pourquoi la demande n'est pas appliquée telle quelle.
    public var reason: String?
    public var capability: Capability
    public var date: Date

    public init(
        requested: BandwidthPolicy,
        effective: BandwidthPolicy?,
        status: ApplyStatus,
        reason: String?,
        capability: Capability,
        date: Date
    ) {
        self.requested = requested
        self.effective = effective
        self.status = status
        self.reason = reason
        self.capability = capability
        self.date = date
    }
}

/// Les bornes d'un plafond et d'une durée.
public enum Limits {
    public static let minimumBps: UInt64 = 100_000
    public static let maximumBps: UInt64 = 1_000_000_000
    public static let minimumDurationSeconds: UInt64 = 60

    /// Un débit en Mb/s converti en bit/s. Une valeur négative ou non numérique donne 0,
    /// que la validation refuse ensuite : une saisie ne fait jamais planter l'app.
    public static func bps(fromMbps mbps: Double) -> UInt64 {
        let bps = (mbps * 1_000_000).rounded()
        guard bps.isFinite, bps > 0 else { return 0 }
        return bps >= 1e18 ? 1_000_000_000_000_000_000 : UInt64(bps)
    }

    public static func mbps(fromBps bps: UInt64) -> Double {
        Double(bps) / 1_000_000
    }
}

// MARK: - Capacités

/// Ce qu'une app peut, ou ne peut pas, faire sur la plateforme.
public enum Capability: String, Codable, CaseIterable, Sendable {
    case internetMonitoring
    case speedTest
    case charts
    case profiles
    case localVPN
    case hotspotActivation
    case hotspotClientDiscovery
    case hotspotLimit
    case perDeviceShaping
    case clientDisconnect
}

public enum Support: String, Codable, CaseIterable, Sendable {
    case supported, conditional, unsupported
}

public struct CapabilityStatus: Identifiable, Equatable, Sendable {
    public let capability: Capability
    public let support: Support
    /// Une phrase qui explique le statut, en français.
    public let note: String
    public var id: String { capability.rawValue }

    public init(capability: Capability, support: Support, note: String) {
        self.capability = capability
        self.support = support
        self.note = note
    }
}

// MARK: - Profils et simulation

/// Un profil de débit. Les sept préréglages sont modifiables ; `isBuiltin` empêche
/// seulement de les supprimer.
public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var downloadBps: UInt64?
    public var uploadBps: UInt64?
    public var isBuiltin: Bool

    public init(id: String, name: String, downloadBps: UInt64?, uploadBps: UInt64?, isBuiltin: Bool) {
        self.id = id
        self.name = name
        self.downloadBps = downloadBps
        self.uploadBps = uploadBps
        self.isBuiltin = isBuiltin
    }

    public var policy: BandwidthPolicy {
        BandwidthPolicy(downloadBps: downloadBps, uploadBps: uploadBps)
    }
}

/// L'effet d'un plafond sur un débit mesuré, dans un sens.
public struct DirectionEffect: Equatable, Sendable {
    public let measuredBps: Double
    public let capBps: UInt64?
    /// Le débit après le plafond : jamais plus que le débit mesuré.
    public let resultBps: Double
    public var isReduced: Bool { resultBps < measuredBps }

    public init(measuredBps: Double, capBps: UInt64?, resultBps: Double) {
        self.measuredBps = measuredBps
        self.capBps = capBps
        self.resultBps = resultBps
    }
}

/// La simulation d'une limite. Un sens absent n'a pas de débit mesuré.
public struct Simulation: Equatable, Sendable {
    public let download: DirectionEffect?
    public let upload: DirectionEffect?

    public init(download: DirectionEffect?, upload: DirectionEffect?) {
        self.download = download
        self.upload = upload
    }
}

// MARK: - Historique

public enum HistoryStep: String, Codable, CaseIterable, Sendable {
    case minute, hour, day
}

/// Les mesures d'une minute, d'une heure ou d'un jour.
public struct Aggregate: Identifiable, Codable, Equatable, Sendable {
    public var start: Date
    public var averageDownloadBps: Double
    public var averageUploadBps: Double
    public var peakDownloadBps: Double
    public var peakUploadBps: Double
    public var receivedBytes: UInt64
    public var sentBytes: UInt64
    public var sampleCount: Int
    public var id: Date { start }

    public init(
        start: Date,
        averageDownloadBps: Double,
        averageUploadBps: Double,
        peakDownloadBps: Double,
        peakUploadBps: Double,
        receivedBytes: UInt64,
        sentBytes: UInt64,
        sampleCount: Int
    ) {
        self.start = start
        self.averageDownloadBps = averageDownloadBps
        self.averageUploadBps = averageUploadBps
        self.peakDownloadBps = peakDownloadBps
        self.peakUploadBps = peakUploadBps
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.sampleCount = sampleCount
    }
}

/// Le bilan d'une période.
public struct UsageSummary: Equatable, Sendable {
    public var receivedBytes: UInt64
    public var sentBytes: UInt64
    public var averageDownloadBps: Double?
    public var averageUploadBps: Double?
    public var peakDownloadBps: Double?
    public var peakUploadBps: Double?

    public init(
        receivedBytes: UInt64 = 0,
        sentBytes: UInt64 = 0,
        averageDownloadBps: Double? = nil,
        averageUploadBps: Double? = nil,
        peakDownloadBps: Double? = nil,
        peakUploadBps: Double? = nil
    ) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.averageDownloadBps = averageDownloadBps
        self.averageUploadBps = averageUploadBps
        self.peakDownloadBps = peakDownloadBps
        self.peakUploadBps = peakUploadBps
    }
}

// MARK: - Diagnostic

public struct EngineEvent: Identifiable, Equatable, Sendable {
    public enum Level: String, Sendable {
        case info, warning, error
    }

    public let id: Int
    public let date: Date
    public let level: Level
    public let message: String

    public init(id: Int, date: Date, level: Level, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

public struct Diagnostics: Equatable, Sendable {
    public var engineVersion: String
    public var isMonitoring: Bool
    public var minuteAggregates: Int
    public var hourAggregates: Int
    public var dayAggregates: Int
    public var policyRecords: Int
    /// Où les données sont enregistrées, pour l'afficher dans le diagnostic.
    public var storeLocation: String?
    /// Les événements récents, du plus récent au plus ancien.
    public var events: [EngineEvent]

    public init(
        engineVersion: String,
        isMonitoring: Bool,
        minuteAggregates: Int,
        hourAggregates: Int,
        dayAggregates: Int,
        policyRecords: Int,
        storeLocation: String?,
        events: [EngineEvent]
    ) {
        self.engineVersion = engineVersion
        self.isMonitoring = isMonitoring
        self.minuteAggregates = minuteAggregates
        self.hourAggregates = hourAggregates
        self.dayAggregates = dayAggregates
        self.policyRecords = policyRecords
        self.storeLocation = storeLocation
        self.events = events
    }
}

// MARK: - Erreurs

public enum FluxaError: Error, Equatable, Sendable {
    /// Un plafond hors de la plage de 0,1 à 1 000 Mb/s.
    case rateOutOfRange(bps: UInt64)
    /// Une durée de moins d'une minute.
    case durationTooShort(seconds: UInt64)
    case emptyName
    case unknownProfile(id: String)
    /// Un préréglage se modifie, mais ne se supprime pas.
    case builtinProfile(id: String)
    /// Une règle d'automatisation refusée, avec la raison en français.
    case invalidRule(String)
    /// Un appareil du registre refusé, avec la raison en français.
    case invalidDevice(String)
    /// Un forfait refusé, avec la raison en français.
    case invalidPlan(String)
    case store(String)
}

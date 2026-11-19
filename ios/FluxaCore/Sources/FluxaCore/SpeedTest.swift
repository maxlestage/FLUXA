import Foundation

// Le test de débit : le calcul, sans réseau. L'app transfère les données ; ce fichier
// transforme les octets comptés en débit.

/// Le résultat d'un test de débit.
public struct SpeedTestResult: Identifiable, Codable, Equatable, Sendable {
    public var date: Date
    /// `nil` : cette phase a échoué ou n'a pas été lancée.
    public var downloadBps: Double?
    public var uploadBps: Double?
    public var latencyMs: Double?
    public var networkKind: NetworkKind
    /// Le serveur de test, pour que l'historique dise contre quoi la mesure a été faite.
    public var server: String
    public var downloadedBytes: UInt64
    public var uploadedBytes: UInt64
    public var id: Date { date }

    public init(
        date: Date,
        downloadBps: Double?,
        uploadBps: Double?,
        latencyMs: Double?,
        networkKind: NetworkKind,
        server: String,
        downloadedBytes: UInt64,
        uploadedBytes: UInt64
    ) {
        self.date = date
        self.downloadBps = downloadBps
        self.uploadBps = uploadBps
        self.latencyMs = latencyMs
        self.networkKind = networkKind
        self.server = server
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
    }
}

/// Le débit d'un transfert en cours, à partir des octets comptés au fil du temps.
///
/// Le début d'un transfert sous-estime le débit : la connexion s'ouvre et TCP monte en
/// régime. Les octets de cette période d'amorçage sont écartés du calcul.
public struct SpeedMeter: Equatable, Sendable {
    /// La durée d'amorçage écartée, en secondes.
    public let warmUp: TimeInterval
    public private(set) var totalBytes: UInt64 = 0
    private var measuredBytes: UInt64 = 0
    private var lastTime: TimeInterval = 0

    public init(warmUp: TimeInterval = 1.5) {
        self.warmUp = max(0, warmUp)
    }

    /// Ajoute des octets transférés, `time` secondes après le début de la phase.
    public mutating func add(bytes: Int, at time: TimeInterval) {
        guard bytes > 0, time.isFinite, time >= 0 else { return }
        totalBytes += UInt64(bytes)
        lastTime = max(lastTime, time)
        if time > warmUp {
            measuredBytes += UInt64(bytes)
        }
    }

    /// Le débit en bit/s, une fois l'amorçage passé. `nil` tant qu'il n'y a pas assez de
    /// recul (moins d'un quart de seconde mesuré) : un chiffre trop tôt serait faux.
    public var bps: Double? {
        let measured = lastTime - warmUp
        guard measured >= 0.25, measuredBytes > 0 else { return nil }
        return Double(measuredBytes) * 8 / measured
    }

    /// Le débit à l'instant `time`, pour l'affichage en cours de test : le temps avance
    /// même quand aucun octet n'arrive.
    public func bps(at time: TimeInterval) -> Double? {
        let measured = max(lastTime, time) - warmUp
        guard measured >= 0.25, measuredBytes > 0 else { return nil }
        return Double(measuredBytes) * 8 / measured
    }
}

import Foundation

/// Le moteur de FLUXA : il reçoit les relevés du système, calcule les débits, tient
/// l'historique et les profils, et dit ce qui est réellement appliqué.
///
/// Il n'accède pas au système lui-même : l'app lui donne les compteurs des interfaces,
/// le type de réseau et les mesures de latence. Il s'utilise depuis un seul fil
/// d'exécution (l'acteur principal de l'app).
///
/// CONTRAT : les signatures publiques de ce fichier sont utilisées par l'interface.
public final class FluxaEngine {
    public static let version = "0.1.0"

    /// Nombre de sondes de latence gardées pour la gigue et les pertes.
    static let latencyProbes = 12
    /// Durée couverte par la courbe en direct.
    static let recentWindow: TimeInterval = 60
    /// Nombre de réponses gardées dans le journal des limites.
    static let policyLogCapacity = 500
    /// Nombre d'événements gardés pour le diagnostic.
    static let eventCapacity = 200

    private let store: any EngineStore
    private let calendar: Calendar
    private let now: () -> Date

    private var state: EngineState
    private var meter: InterfaceMeter
    private var latency = LatencyWindow(capacity: FluxaEngine.latencyProbes)
    private var pathKind: NetworkKind = .offline
    private var pathOnline = false
    /// Le dernier débit calculé. `nil` : rien de mesuré sur le réseau actif.
    private var lastRate: ThroughputSample?
    private var samples: [ThroughputSample] = []
    /// La minute de la dernière mesure, pour enregistrer quand elle se termine.
    private var currentMinute: Date?
    /// Le cumul du jour, recalculé quand la journée change.
    private var today: (start: Date, received: UInt64, sent: UInt64)?
    private var events: [EngineEvent] = []
    private var nextEventID = 1

    /// - Parameters:
    ///   - store: où l'état est enregistré. Un état illisible n'empêche pas de
    ///     démarrer : le moteur repart à vide et le note dans ses événements.
    ///   - counterWidth: la largeur des compteurs d'octets du système.
    ///   - calendar: le calendrier des journées (minuit local).
    ///   - now: l'horloge, remplaçable dans les tests.
    public init(
        store: any EngineStore,
        counterWidth: CounterWidth = .bits32,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.calendar = calendar
        self.now = now
        self.meter = InterfaceMeter(width: counterWidth)

        var loadFailure: String?
        do {
            self.state = try store.load() ?? EngineState()
        } catch {
            self.state = EngineState()
            loadFailure = Self.describe(error)
        }
        state.restoreBuiltinProfiles()

        let date = now()
        log(.info, "Moteur démarré.", at: date)
        if let loadFailure {
            log(.error, "Données enregistrées illisibles : démarrage à vide. \(loadFailure)", at: date)
        }
        applyRetention(at: date)
        expireLimitIfNeeded(at: date)
    }

    // MARK: Capacités

    /// Ce qu'une app peut faire sur iPhone, dans l'ordre de `Capability.allCases`.
    public var capabilities: [CapabilityStatus] {
        Capability.allCases.map(Rules.status(of:))
    }

    /// Les capacités au format du cahier des charges :
    /// `{"platform":"ios","capabilities":{"internet_monitoring":true,…}}`, indenté.
    public func capabilitiesJSON() -> String {
        Rules.capabilitiesJSON()
    }

    // MARK: Mesure

    public private(set) var isMonitoring = false

    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        log(.info, "Mesure démarrée.")
    }

    public func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        // Au redémarrage, le premier relevé ne servira que de base.
        meter.reset()
        latency.clear()
        lastRate = nil
        currentMinute = nil
        log(.info, "Mesure arrêtée.")
        saveQuietly()
    }

    /// Le type de réseau, tel que le système le signale.
    public func updatePath(kind: NetworkKind, isOnline: Bool) {
        if kind != pathKind {
            // Les mesures de l'ancien réseau ne décrivent pas le nouveau.
            latency.clear()
            lastRate = nil
            log(.info, "Réseau : \(kind.eventLabel).")
        }
        pathKind = kind
        pathOnline = isOnline
    }

    /// Donne au moteur un relevé des compteurs de toutes les interfaces. Le premier
    /// relevé sert de base : il ne produit pas de débit. Un compteur qui repart de
    /// zéro (redémarrage de l'interface) ou qui déborde ne produit pas de pic.
    /// Sans effet quand la mesure est arrêtée.
    @discardableResult
    public func ingest(_ readings: [InterfaceReading]) -> NetworkSnapshot {
        guard isMonitoring else { return snapshot }
        let date = now()
        expireLimitIfNeeded(at: date)

        guard let deltas = meter.push(readings, at: date) else {
            // Relevé de base, ou reprise après une interruption : aucun débit à annoncer.
            lastRate = nil
            return snapshot
        }
        guard let family = pathKind.interfaceClass else { return snapshot }
        // Seules les interfaces du réseau actif comptent.
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var measured = false
        for delta in deltas.interfaces where delta.kind == family {
            received = received.saturatingAdd(delta.receivedBytes)
            sent = sent.saturatingAdd(delta.sentBytes)
            measured = true
        }
        guard measured else {
            lastRate = nil
            return snapshot
        }

        let measurement = Measurement(
            date: date, seconds: deltas.seconds, receivedBytes: received, sentBytes: sent)
        let sample = ThroughputSample(
            date: date, downloadBps: measurement.downloadBps, uploadBps: measurement.uploadBps)
        lastRate = sample
        samples.append(sample)
        samples.removeAll { $0.date <= date.addingTimeInterval(-Self.recentWindow) }
        record(measurement)
        return snapshot
    }

    /// Le résultat d'une sonde de latence, en millisecondes. `nil` : pas de réponse.
    public func recordLatency(_ milliseconds: Double?) {
        guard isMonitoring else { return }
        latency.push(milliseconds)
    }

    public var snapshot: NetworkSnapshot {
        let totals = todayTotals(at: now())
        return NetworkSnapshot(
            kind: pathKind,
            isOnline: pathOnline,
            isMonitoring: isMonitoring,
            downloadBps: lastRate?.downloadBps,
            uploadBps: lastRate?.uploadBps,
            latencyMs: latency.latest,
            jitterMs: latency.jitter,
            packetLossPercent: latency.lossRatio.map { $0 * 100 },
            receivedBytesToday: totals.received,
            sentBytesToday: totals.sent,
            measuredAt: lastRate?.date
        )
    }

    /// Les débits des 60 dernières secondes au plus, du plus ancien au plus récent.
    public var recentSamples: [ThroughputSample] {
        let oldest = now().addingTimeInterval(-Self.recentWindow)
        return samples.filter { $0.date > oldest }
    }

    // MARK: Profils et limites

    /// Les sept préréglages, puis les profils créés par l'utilisateur.
    public var profiles: [Profile] { state.profiles }

    public var activeProfileID: String? { state.activeProfileID }

    /// La réponse à la dernière demande de limite.
    public var lastApplyResult: ApplyResult? { state.lastApplyResult }

    /// Crée un profil (`id` absent) ou modifie un profil existant. Les débits sont en
    /// Mb/s ; `nil` : sans plafond dans ce sens.
    @discardableResult
    public func saveProfile(
        id: String?,
        name: String,
        downloadMbps: Double?,
        uploadMbps: Double?
    ) throws -> Profile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FluxaError.emptyName }
        let downloadBps = try Rules.bps(fromMbps: downloadMbps)
        let uploadBps = try Rules.bps(fromMbps: uploadMbps)

        let profile: Profile
        if let id {
            guard let index = state.profiles.firstIndex(where: { $0.id == id }) else {
                throw FluxaError.unknownProfile(id: id)
            }
            // Un préréglage modifié reste un préréglage.
            state.profiles[index].name = name
            state.profiles[index].downloadBps = downloadBps
            state.profiles[index].uploadBps = uploadBps
            profile = state.profiles[index]
        } else {
            profile = Profile(
                id: state.makeProfileID(),
                name: name,
                downloadBps: downloadBps,
                uploadBps: uploadBps,
                isBuiltin: false
            )
            state.profiles.append(profile)
        }

        if state.activeProfileID == profile.id {
            // Le profil actif vient de changer : sa limite suit.
            request(profile.policy, forDevice: false)
        }
        saveQuietly()
        return profile
    }

    public func deleteProfile(id: String) throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else {
            throw FluxaError.unknownProfile(id: id)
        }
        guard !state.profiles[index].isBuiltin else {
            throw FluxaError.builtinProfile(id: id)
        }
        state.profiles.remove(at: index)
        if state.activeProfileID == id {
            // La limite du profil disparaît avec lui.
            state.activeProfileID = nil
            state.lastApplyResult = nil
        }
        saveQuietly()
    }

    /// Active un profil. Sur iPhone, le résultat est `simulated` : le plafond est
    /// enregistré, pas appliqué au partage de connexion.
    @discardableResult
    public func activateProfile(id: String) throws -> ApplyResult {
        guard let profile = state.profiles.first(where: { $0.id == id }) else {
            throw FluxaError.unknownProfile(id: id)
        }
        try Rules.validate(profile.policy)
        let result = request(profile.policy, forDevice: false)
        state.activeProfileID = id
        saveQuietly()
        return result
    }

    /// Demande une limite globale. Même réponse que pour un profil : `simulated`.
    @discardableResult
    public func apply(_ policy: BandwidthPolicy) throws -> ApplyResult {
        try Rules.validate(policy)
        let result = request(policy, forDevice: false)
        // Une limite réglée à la main remplace le profil actif.
        state.activeProfileID = nil
        saveQuietly()
        return result
    }

    /// Demande une limite pour un appareil relié au partage : `unsupported` sur iPhone.
    @discardableResult
    public func applyToDevice(_ policy: BandwidthPolicy) throws -> ApplyResult {
        try Rules.validate(policy)
        let result = request(policy, forDevice: true)
        saveQuietly()
        return result
    }

    /// Vérifie une limite sans la demander.
    public func validate(_ policy: BandwidthPolicy) throws {
        try Rules.validate(policy)
    }

    /// L'effet qu'aurait une limite sur le débit mesuré à l'instant.
    public func simulate(_ policy: BandwidthPolicy) -> Simulation {
        Simulation(
            download: Rules.effect(
                measuredBps: lastRate?.downloadBps, capBps: policy.downloadBps, mode: policy.mode),
            upload: Rules.effect(
                measuredBps: lastRate?.uploadBps, capBps: policy.uploadBps, mode: policy.mode)
        )
    }

    /// Les réponses aux demandes de limite, de la plus récente à la plus ancienne.
    public func policyLog(limit: Int) -> [ApplyResult] {
        guard limit > 0 else { return [] }
        return Array(state.policyLog.suffix(limit).reversed())
    }

    // MARK: Historique

    /// Les agrégats dont le début est dans `[from, to[`, du plus ancien au plus récent.
    public func history(from: Date, to: Date, step: HistoryStep) -> [Aggregate] {
        series(for: step).slice(from: from, to: to).map(\.aggregate)
    }

    public func usage(from: Date, to: Date) -> UsageSummary {
        // La suite la plus fine qui couvre encore le début de la période.
        let date = now()
        let step: HistoryStep
        if from >= minuteCutoff(at: date) {
            step = .minute
        } else if from >= hourCutoff(at: date) {
            step = .hour
        } else {
            step = .day
        }
        let buckets = series(for: step).slice(from: from, to: to)
        guard let first = buckets.first else { return UsageSummary() }
        var total = Bucket(start: first.start)
        for bucket in buckets {
            total.merge(bucket)
        }
        return UsageSummary(
            receivedBytes: total.receivedBytes,
            sentBytes: total.sentBytes,
            averageDownloadBps: total.averageDownloadBps,
            averageUploadBps: total.averageUploadBps,
            peakDownloadBps: total.peakDownloadBps,
            peakUploadBps: total.peakUploadBps
        )
    }

    // MARK: Données

    /// Enregistre l'état. L'app l'appelle en passant à l'arrière-plan ; le moteur
    /// enregistre aussi de lui-même à la fin de chaque minute.
    public func flush() throws {
        try save()
    }

    /// Efface les mesures et le journal des limites. Les profils restent.
    public func eraseHistory() throws {
        state.minutes.removeAll()
        state.hours.removeAll()
        state.days.removeAll()
        state.policyLog.removeAll()
        samples.removeAll()
        today = nil
        events.removeAll()
        log(.info, "Historique effacé.")
        try save()
    }

    /// Efface tout : mesures, journal, profils créés et réglages.
    public func eraseAll() throws {
        state = EngineState()
        state.restoreBuiltinProfiles()
        samples.removeAll()
        today = nil
        events.removeAll()
        log(.info, "Toutes les données ont été effacées.")
        do {
            try store.erase()
        } catch {
            let detail = Self.describe(error)
            log(.error, "Effacement impossible : \(detail)")
            throw FluxaError.store(detail)
        }
    }

    public func diagnostics() -> Diagnostics {
        Diagnostics(
            engineVersion: Self.version,
            isMonitoring: isMonitoring,
            minuteAggregates: state.minutes.count,
            hourAggregates: state.hours.count,
            dayAggregates: state.days.count,
            policyRecords: state.policyLog.count,
            storeLocation: store.location,
            events: events.reversed()
        )
    }

    // MARK: - Interne

    /// Répond à une demande de limite et la consigne. Sur iPhone, aucun adaptateur ne
    /// peut confirmer une application : `effective` reste `nil`.
    @discardableResult
    private func request(_ policy: BandwidthPolicy, forDevice: Bool) -> ApplyResult {
        let result = ApplyResult(
            requested: policy,
            effective: nil,
            status: forDevice ? .unsupported : .simulated,
            reason: forDevice ? Rules.deviceLimitReason : Rules.globalLimitReason,
            capability: forDevice ? .perDeviceShaping : .hotspotLimit,
            date: now()
        )
        state.lastApplyResult = result
        state.policyLog.append(result)
        if state.policyLog.count > Self.policyLogCapacity {
            state.policyLog.removeFirst(state.policyLog.count - Self.policyLogCapacity)
        }
        log(
            .info,
            forDevice ? "Limite par appareil : non prise en charge." : "Limite globale : simulée.",
            at: result.date)
        return result
    }

    /// Retire la limite en cours quand sa durée est écoulée.
    private func expireLimitIfNeeded(at date: Date) {
        guard let result = state.lastApplyResult, let seconds = result.requested.durationSeconds
        else { return }
        guard date >= result.date.addingTimeInterval(Double(seconds)) else { return }
        state.lastApplyResult = nil
        state.activeProfileID = nil
        log(.info, "Limite arrivée à échéance.", at: date)
    }

    /// Range une mesure dans sa minute, son heure et son jour.
    private func record(_ measurement: Measurement) {
        let date = measurement.date
        let minute = Self.minuteStart(of: date)
        if let currentMinute, currentMinute != minute {
            // La minute précédente est terminée : purge et enregistrement.
            applyRetention(at: date)
            saveQuietly()
        }
        currentMinute = minute

        state.minutes.add(measurement, at: minute)
        state.hours.add(measurement, at: hourStart(of: date))
        let day = calendar.startOfDay(for: date)
        state.days.add(measurement, at: day)

        if let totals = today, totals.start == day {
            today = (
                day, totals.received.saturatingAdd(measurement.receivedBytes),
                totals.sent.saturatingAdd(measurement.sentBytes)
            )
        } else {
            today = nil
        }
    }

    /// Les octets mesurés depuis minuit, d'après les minutes de la journée.
    private func todayTotals(at date: Date) -> (received: UInt64, sent: UInt64) {
        let day = calendar.startOfDay(for: date)
        if let totals = today, totals.start == day {
            return (totals.received, totals.sent)
        }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for bucket in state.minutes.slice(from: day, to: .distantFuture) {
            received = received.saturatingAdd(bucket.receivedBytes)
            sent = sent.saturatingAdd(bucket.sentBytes)
        }
        today = (day, received, sent)
        return (received, sent)
    }

    private func series(for step: HistoryStep) -> BucketSeries {
        switch step {
        case .minute: return state.minutes
        case .hour: return state.hours
        case .day: return state.days
        }
    }

    static func minuteStart(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private func hourStart(of date: Date) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start
            ?? Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    // Conservation : minutes 7 jours, heures 30 jours, jours 12 mois.

    private func minuteCutoff(at date: Date) -> Date {
        date.addingTimeInterval(-7 * 86_400)
    }

    private func hourCutoff(at date: Date) -> Date {
        date.addingTimeInterval(-30 * 86_400)
    }

    private func dayCutoff(at date: Date) -> Date {
        calendar.date(byAdding: .month, value: -12, to: date) ?? date.addingTimeInterval(-365 * 86_400)
    }

    private func applyRetention(at date: Date) {
        let minutes = state.minutes.removeAll(before: minuteCutoff(at: date))
        let hours = state.hours.removeAll(before: hourCutoff(at: date))
        let days = state.days.removeAll(before: dayCutoff(at: date))
        if minutes + hours + days > 0 {
            log(.info, "Purge : \(minutes) minutes, \(hours) heures, \(days) jours.", at: date)
        }
    }

    private func save() throws {
        do {
            try store.save(state)
        } catch {
            let detail = Self.describe(error)
            log(.error, "Enregistrement impossible : \(detail)")
            throw FluxaError.store(detail)
        }
    }

    /// Enregistre sans interrompre : un échec est noté, et le prochain enregistrement
    /// (fin de minute, passage à l'arrière-plan) reprend tout l'état.
    private func saveQuietly() {
        try? save()
    }

    private func log(_ level: EngineEvent.Level, _ message: String, at date: Date? = nil) {
        events.append(EngineEvent(id: nextEventID, date: date ?? now(), level: level, message: message))
        nextEventID += 1
        if events.count > Self.eventCapacity {
            events.removeFirst(events.count - Self.eventCapacity)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? FluxaError, case .store(let detail) = error {
            return detail
        }
        return error.localizedDescription
    }
}

/// Où le moteur enregistre son état.
public protocol EngineStore: AnyObject {
    /// L'état enregistré, ou `nil` s'il n'y en a pas encore.
    func load() throws -> EngineState?
    func save(_ state: EngineState) throws
    func erase() throws
    /// Une description de l'emplacement, pour le diagnostic.
    var location: String? { get }
}

/// Tout ce que le moteur enregistre : agrégats, profils, réglages, journal.
/// Son contenu appartient au moteur.
public struct EngineState: Codable, Equatable, Sendable {
    /// Version du format enregistré.
    static let currentVersion = 1

    var version = EngineState.currentVersion
    /// Les préréglages (modifiables), puis les profils de l'utilisateur.
    var profiles: [Profile] = []
    var nextProfileNumber = 1
    var activeProfileID: String?
    var lastApplyResult: ApplyResult?
    /// Les réponses aux demandes de limite, de la plus ancienne à la plus récente.
    var policyLog: [ApplyResult] = []
    var minutes = BucketSeries()
    var hours = BucketSeries()
    var days = BucketSeries()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, profiles, nextProfileNumber, activeProfileID, lastApplyResult, policyLog
        case minutes, hours, days
    }

    // Un champ absent prend sa valeur par défaut : un fichier écrit par une version
    // plus ancienne reste lisible. Un format plus récent est refusé.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= EngineState.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: values,
                debugDescription: "Format \(version) plus récent que cette version de l'app.")
        }
        profiles = try values.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        nextProfileNumber = try values.decodeIfPresent(Int.self, forKey: .nextProfileNumber) ?? 1
        activeProfileID = try values.decodeIfPresent(String.self, forKey: .activeProfileID)
        lastApplyResult = try values.decodeIfPresent(ApplyResult.self, forKey: .lastApplyResult)
        policyLog = try values.decodeIfPresent([ApplyResult].self, forKey: .policyLog) ?? []
        minutes = try values.decodeIfPresent(BucketSeries.self, forKey: .minutes) ?? BucketSeries()
        hours = try values.decodeIfPresent(BucketSeries.self, forKey: .hours) ?? BucketSeries()
        days = try values.decodeIfPresent(BucketSeries.self, forKey: .days) ?? BucketSeries()
    }

    /// Remet les sept préréglages en tête, dans leur ordre. Un préréglage déjà présent
    /// garde les valeurs que l'utilisateur lui a données.
    mutating func restoreBuiltinProfiles() {
        let builtinIDs = Set(Rules.builtinProfiles.map(\.id))
        let builtins = Rules.builtinProfiles.map { preset -> Profile in
            guard var saved = profiles.first(where: { $0.id == preset.id }) else { return preset }
            saved.isBuiltin = true
            return saved
        }
        var custom: [Profile] = []
        for var profile in profiles where !builtinIDs.contains(profile.id) {
            guard !custom.contains(where: { $0.id == profile.id }) else { continue }
            profile.isBuiltin = false
            custom.append(profile)
        }
        profiles = builtins + custom
        if activeProfileID.map({ id in !profiles.contains { $0.id == id } }) ?? false {
            activeProfileID = nil
        }
    }

    /// Un identifiant neuf pour un profil créé par l'utilisateur.
    mutating func makeProfileID() -> String {
        var id: String
        repeat {
            id = "custom-\(nextProfileNumber)"
            nextProfileNumber += 1
        } while profiles.contains { $0.id == id }
        return id
    }
}

/// Un stockage dans un fichier JSON, écrit de façon atomique.
public final class FileStore: EngineStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> EngineState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(EngineState.self, from: data)
        } catch {
            throw FluxaError.store("fichier illisible (\(url.lastPathComponent)).")
        }
    }

    public func save(_ state: EngineState) throws {
        do {
            let data = try JSONEncoder().encode(state)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Écriture atomique : le fichier précédent reste intact si l'écriture échoue.
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            // Chiffré par iOS tant que l'iPhone est verrouillé.
            options.insert(.completeFileProtectionUnlessOpen)
            #endif
            try data.write(to: url, options: options)
        } catch {
            throw FluxaError.store("écriture impossible (\(url.lastPathComponent)).")
        }
    }

    public func erase() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FluxaError.store("suppression impossible (\(url.lastPathComponent)).")
        }
    }

    public var location: String? { url.path }
}

/// Un stockage en mémoire, pour les tests et les aperçus.
public final class MemoryStore: EngineStore {
    private var state: EngineState?

    public init() {}
    public func load() throws -> EngineState? { state }
    public func save(_ state: EngineState) throws { self.state = state }
    public func erase() throws { state = nil }
    public var location: String? { nil }
}

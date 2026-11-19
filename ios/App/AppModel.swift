import FluxaCore
import Foundation
import Observation

/// L'état de l'app : il relie le moteur aux services du système et aux écrans.
///
/// Chaque seconde, au premier plan, il relève les compteurs des interfaces et les donne
/// au moteur. Toutes les cinq secondes, il lance une sonde de latence ; moins souvent en
/// mode économie d'énergie ou données réduites.
///
/// Une propriété observée n'est réécrite que si sa valeur change : les écrans qui la
/// lisent ne se redessinent pas pour rien.
@MainActor
@Observable
final class AppModel {
    private let engine: FluxaEngine
    private let pathMonitor = PathMonitor()
    private let notifier = Notifier()
    let speedTest = SpeedTestRunner()
    private var sampling: Task<Void, Never>?
    private var ticks = 0
    private var probing = false
    /// L'heure de démarrage de l'iPhone, lue à chaque reprise de la mesure.
    private var bootTime: Date?

    private(set) var snapshot = NetworkSnapshot()
    private(set) var samples: [ThroughputSample] = []
    private(set) var interfaces: [InterfaceReading] = []
    private(set) var path = PathDetails()
    private(set) var profiles: [Profile] = []
    private(set) var activeProfileID: String?
    private(set) var lastApply: ApplyResult?
    /// Change à chaque écriture dans l'historique, pour que les écrans le relisent.
    private(set) var historyRevision = 0
    /// Le partage de connexion en cours, d'après l'interface de pont du système : un
    /// signe indirect, qui peut manquer (voir `InterfaceCounters`).
    private(set) var sharing: SharingStatus?
    private(set) var sharingSessions: [SharingSession] = []
    /// Ce qui a été échangé pendant que l'app ne mesurait pas, à la dernière reprise.
    private(set) var absence: AbsenceUsage?
    /// Le forfait mobile et son état. `nil` : pas de forfait réglé.
    private(set) var plan: PlanStatus?
    /// L'intervalle entre deux sondes de latence, en secondes.
    private(set) var probeInterval = AppModel.probeIntervals.normal
    private(set) var rules: [AutomationRule] = []
    private(set) var automationEvents: [AutomationEvent] = []
    private(set) var speedTests: [SpeedTestResult] = []
    private(set) var devices: [Device] = []
    private(set) var notificationAccess = Notifier.Access.unknown
    var errorMessage: String?

    /// Prévenir par une notification quand une règle se déclenche.
    var notifiesAutomations: Bool {
        didSet { UserDefaults.standard.set(notifiesAutomations, forKey: Self.notifiesKey) }
    }

    /// L'adresse du serveur du test de débit. Réglable dans les réglages.
    var speedTestServer: String {
        didSet { UserDefaults.standard.set(speedTestServer, forKey: Self.speedTestServerKey) }
    }

    /// L'hôte de la sonde de latence. Réglable dans les réglages.
    var latencyHost: String {
        didSet { UserDefaults.standard.set(latencyHost, forKey: Self.latencyHostKey) }
    }

    static let defaultLatencyHost = "www.apple.com"
    /// Secondes entre deux sondes : en temps normal, en mode économie d'énergie, et en
    /// mode données réduites.
    static let probeIntervals = (normal: 5, lowPower: 15, lowData: 30)
    private static let latencyHostKey = "latencyHost"
    private static let notifiesKey = "notifiesAutomations"
    private static let speedTestServerKey = "speedTestServer"

    init() {
        let opened = Self.openStore()
        engine = FluxaEngine(store: opened.store)
        latencyHost = UserDefaults.standard.string(forKey: Self.latencyHostKey) ?? Self.defaultLatencyHost
        notifiesAutomations = UserDefaults.standard.bool(forKey: Self.notifiesKey)
        speedTestServer = UserDefaults.standard.string(forKey: Self.speedTestServerKey)
            ?? SpeedTestRunner.defaultServer
        refreshProfiles()
        refreshAutomations()
        speedTests = engine.speedTests
        devices = engine.devices
        sharingSessions = engine.sharingSessions(limit: Self.sharingSessionLimit)
        plan = engine.planStatus()
        snapshot = engine.snapshot
        // Un souci à l'ouverture de la base est dit dès le premier écran.
        errorMessage = opened.problem
    }

    /// Ouvre la base SQLite de l'app. Les mesures d'une version précédente, gardées dans
    /// un fichier JSON, y sont reprises au premier lancement.
    ///
    /// Si la base ne peut pas être ouverte, l'app continue avec un fichier à part plutôt
    /// que de ne rien enregistrer, et le dit.
    private static func openStore() -> (store: any EngineStore, problem: String?) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = folder.appendingPathComponent("fluxa.json")
        do {
            let store = try SQLiteStore(url: folder.appendingPathComponent("fluxa.sqlite"))
            // Un ancien fichier illisible est laissé en place : rien n'est perdu.
            _ = try? store.importLegacyFile(at: legacy)
            return (store, nil)
        } catch {
            let reason = describe(error)
            return (
                FileStore(url: folder.appendingPathComponent("fluxa-secours.json")),
                "La base de données de FLUXA n’a pas pu être ouverte (\(reason)). Les mesures de cette session sont enregistrées à part."
            )
        }
    }

    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID }
    }

    var sharingDetected: Bool { sharing != nil }

    private static let sharingSessionLimit = 10

    var capabilities: [CapabilityStatus] { engine.capabilities }
    var capabilitiesJSON: String { engine.capabilitiesJSON() }
    var diagnostics: Diagnostics { engine.diagnostics() }

    // MARK: Mesure

    func start() {
        guard sampling == nil else { return }
        bootTime = InterfaceCounters.bootTime()
        engine.start()
        pathMonitor.start { [weak self] details in
            guard let self else { return }
            self.path = details
            self.engine.updatePath(kind: details.kind, isOnline: details.isOnline)
            self.snapshot = self.engine.snapshot
        }
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        sampling?.cancel()
        sampling = nil
        pathMonitor.stop()
        engine.stop()
        do {
            try engine.flush()
        } catch {
            errorMessage = Self.describe(error)
        }
        snapshot = engine.snapshot
        sharing = nil
        sharingSessions = engine.sharingSessions(limit: Self.sharingSessionLimit)
    }

    private func sample() {
        var interfaces = InterfaceCounters.read()
        #if targetEnvironment(simulator)
        // Dans le simulateur, les interfaces sont celles du Mac : `en0` y est souvent de
        // l'Ethernet. Elles prennent la famille du réseau courant, pour que la mesure vive.
        if let family = path.kind.interfaceClass {
            interfaces = interfaces.map {
                InterfaceReading(
                    name: $0.name,
                    kind: $0.kind == .sharing ? .sharing : family,
                    receivedBytes: $0.receivedBytes,
                    sentBytes: $0.sentBytes
                )
            }
        }
        #endif
        let snapshot = engine.ingest(interfaces, bootTime: bootTime)
        set(\.interfaces, interfaces)
        set(\.snapshot, snapshot)
        set(\.samples, engine.recentSamples)
        refreshSharing()
        let absence = engine.lastAbsence
        if absence != self.absence {
            self.absence = absence
            // Un rattrapage entre dans l'historique : les écrans qui le lisent se relisent.
            historyRevision += 1
        }
        runAutomations()
        if ticks % 10 == 0 {
            set(\.plan, engine.planStatus())
        }
        ticks += 1
        if ticks % 60 == 0 {
            historyRevision += 1
        }
        set(\.probeInterval, Self.probeInterval(
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            lowData: path.isConstrained
        ))
        if ticks % probeInterval == 1 {
            probeLatency()
        }
    }

    /// L'intervalle des sondes selon les modes du système : la sonde coûte un peu de
    /// batterie et de données, elle ralentit quand l'utilisateur demande d'économiser.
    static func probeInterval(lowPower: Bool, lowData: Bool) -> Int {
        if lowData { return probeIntervals.lowData }
        if lowPower { return probeIntervals.lowPower }
        return probeIntervals.normal
    }

    private func refreshSharing() {
        let status = engine.sharingStatus
        // Une session qui se termine rejoint la liste des sessions passées.
        if (status == nil) != (sharing == nil) {
            sharingSessions = engine.sharingSessions(limit: Self.sharingSessionLimit)
        }
        set(\.sharing, status)
    }

    /// Écrit une propriété observée seulement si sa valeur change.
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private func probeLatency() {
        // Sans hôte, pas de sonde : une absence de réglage n'est pas une perte de paquets.
        let host = latencyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !probing, path.isOnline, !host.isEmpty else { return }
        probing = true
        Task { [weak self] in
            let milliseconds = await LatencyProbe.measure(host: host)
            guard let self else { return }
            self.probing = false
            guard self.sampling != nil else { return }
            self.engine.recordLatency(milliseconds)
            self.snapshot = self.engine.snapshot
        }
    }

    // MARK: Profils et limites

    private func refreshProfiles() {
        profiles = engine.profiles
        activeProfileID = engine.activeProfileID
        lastApply = engine.lastApplyResult
    }

    func activate(_ profile: Profile) {
        perform { _ = try engine.activateProfile(id: profile.id) }
    }

    /// Enregistre un profil. Renvoie le message d'erreur, ou `nil` si c'est fait.
    ///
    /// L'erreur revient à l'appelant au lieu de passer par l'alerte générale : la saisie se
    /// fait dans une feuille, au-dessus de laquelle cette alerte ne s'afficherait pas.
    func saveProfile(id: String?, name: String, downloadMbps: Double?, uploadMbps: Double?) -> String? {
        do {
            _ = try engine.saveProfile(id: id, name: name, downloadMbps: downloadMbps, uploadMbps: uploadMbps)
            refreshProfiles()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func delete(_ profile: Profile) {
        perform { try engine.deleteProfile(id: profile.id) }
        // Un profil supprimé est détaché des appareils qui le portaient.
        devices = engine.devices
        refreshAutomations()
    }

    func profile(id: String?) -> Profile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Les règles et les appareils qui utilisent ce profil, pour prévenir avant de le supprimer.
    func usage(of profile: Profile) -> ProfileUsage {
        engine.profileUsage(id: profile.id)
    }

    // MARK: Appareils

    /// Enregistre un appareil. Renvoie le message d'erreur, ou `nil` si c'est fait.
    func saveDevice(_ device: Device) -> String? {
        do {
            try engine.saveDevice(device)
            devices = engine.devices
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func deleteDevice(_ device: Device) {
        perform { try engine.deleteDevice(id: device.id) }
        devices = engine.devices
    }

    func limitStatus(for device: Device) -> ApplyResult? {
        engine.limitStatus(for: device)
    }

    @discardableResult
    func apply(_ policy: BandwidthPolicy) -> Bool {
        perform { _ = try engine.apply(policy) }
    }

    /// Le message d'erreur d'une limite invalide, ou `nil` si elle est correcte.
    func problem(with policy: BandwidthPolicy) -> String? {
        do {
            try engine.validate(policy)
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func simulate(_ policy: BandwidthPolicy) -> Simulation {
        engine.simulate(policy)
    }

    func policyLog(limit: Int = 20) -> [ApplyResult] {
        engine.policyLog(limit: limit)
    }

    // MARK: Automatisations

    private func refreshAutomations() {
        rules = engine.automationRules
        automationEvents = engine.automationLog(limit: 30)
    }

    /// Évalue les règles sur l'état du moment, et signale ce qu'elles viennent de faire.
    private func runAutomations() {
        let events = engine.evaluateAutomations()
        guard !events.isEmpty else { return }
        refreshProfiles()
        refreshAutomations()
        if notifiesAutomations {
            notifier.post(events)
        }
    }

    /// Enregistre une règle. Renvoie le message d'erreur, ou `nil` si c'est fait.
    func saveRule(_ rule: AutomationRule) -> String? {
        do {
            try engine.saveRule(rule)
            refreshAutomations()
            runAutomations()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func deleteRule(_ rule: AutomationRule) {
        perform { try engine.deleteRule(id: rule.id) }
        refreshAutomations()
    }

    func setRule(_ rule: AutomationRule, enabled: Bool) {
        var changed = rule
        changed.isEnabled = enabled
        if let problem = saveRule(changed) {
            errorMessage = problem
        }
        refreshProfiles()
    }

    func refreshNotificationAccess() async {
        notificationAccess = await notifier.access()
    }

    /// Active ou coupe les notifications. L'autorisation du système est demandée à la
    /// première activation ; si elle est refusée, l'option reste coupée.
    func setNotifications(_ enabled: Bool) async {
        guard enabled else {
            notifiesAutomations = false
            return
        }
        let granted = await notifier.requestAccess()
        notificationAccess = await notifier.access()
        notifiesAutomations = granted
    }

    // MARK: Forfait mobile

    var dataPlan: DataPlan? { plan?.plan }

    /// Enregistre le forfait, ou le retire (`nil`). Renvoie le message d'erreur, ou `nil`.
    func setDataPlan(_ plan: DataPlan?) -> String? {
        do {
            try engine.setDataPlan(plan)
            self.plan = engine.planStatus()
            refreshAutomations()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// Recale le volume du cycle sur ce que l'opérateur indique.
    func calibratePlan(usedBytes: UInt64) -> String? {
        do {
            try engine.calibratePlan(usedBytes: usedBytes)
            plan = engine.planStatus()
            runAutomations()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    // MARK: Test de débit

    func startSpeedTest() {
        speedTest.start(server: speedTestServer, networkKind: path.kind) { [weak self] result in
            guard let self else { return }
            self.engine.recordSpeedTest(result)
            self.speedTests = self.engine.speedTests
        }
    }

    // MARK: Historique et données

    func history(from: Date, to: Date, step: HistoryStep) -> [Aggregate] {
        engine.history(from: from, to: to, step: step)
    }

    func usage(from: Date, to: Date) -> UsageSummary {
        engine.usage(from: from, to: to)
    }

    func compareUsage(from: Date, to: Date) -> UsageComparison {
        engine.compareUsage(from: from, to: to)
    }

    func usageByNetwork(from: Date, to: Date) -> [NetworkUsage] {
        engine.usageByNetwork(from: from, to: to)
    }

    func absences(limit: Int = 20) -> [AbsenceUsage] {
        engine.absences(limit: limit)
    }

    func exportCSV(from: Date, to: Date, step: HistoryStep) -> String {
        engine.exportCSV(from: from, to: to, step: step)
    }

    func eraseHistory() {
        perform { try engine.eraseHistory() }
        refreshAutomations()
        refreshMeasuredState()
        speedTests = engine.speedTests
        samples = engine.recentSamples
        snapshot = engine.snapshot
    }

    func eraseAll() {
        perform { try engine.eraseAll() }
        refreshAutomations()
        refreshMeasuredState()
        speedTests = engine.speedTests
        devices = engine.devices
        latencyHost = Self.defaultLatencyHost
        speedTestServer = SpeedTestRunner.defaultServer
        samples = engine.recentSamples
        snapshot = engine.snapshot
    }

    /// Relit ce qui dépend des mesures enregistrées, après un effacement.
    private func refreshMeasuredState() {
        absence = engine.lastAbsence
        sharing = engine.sharingStatus
        sharingSessions = engine.sharingSessions(limit: Self.sharingSessionLimit)
        plan = engine.planStatus()
    }

    // MARK: Erreurs

    @discardableResult
    private func perform(_ action: () throws -> Void) -> Bool {
        do {
            try action()
            refreshProfiles()
            historyRevision += 1
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

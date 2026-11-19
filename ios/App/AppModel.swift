import FluxaCore
import Foundation
import Observation

/// L'état de l'app : il relie le moteur aux services du système et aux écrans.
///
/// Chaque seconde, au premier plan, il relève les compteurs des interfaces et les donne
/// au moteur. Toutes les cinq secondes, il lance une sonde de latence.
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

    private(set) var snapshot = NetworkSnapshot()
    private(set) var samples: [ThroughputSample] = []
    private(set) var interfaces: [InterfaceReading] = []
    private(set) var path = PathDetails()
    private(set) var profiles: [Profile] = []
    private(set) var activeProfileID: String?
    private(set) var lastApply: ApplyResult?
    /// Change à chaque écriture dans l'historique, pour que les écrans le relisent.
    private(set) var historyRevision = 0
    /// Un signe indirect que le partage de connexion est en service (voir `InterfaceCounters`).
    private(set) var sharingDetected = false
    private(set) var rules: [AutomationRule] = []
    private(set) var automationEvents: [AutomationEvent] = []
    private(set) var speedTests: [SpeedTestResult] = []
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
    private static let latencyHostKey = "latencyHost"
    private static let notifiesKey = "notifiesAutomations"
    private static let speedTestServerKey = "speedTestServer"

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        engine = FluxaEngine(store: FileStore(url: folder.appendingPathComponent("fluxa.json")))
        latencyHost = UserDefaults.standard.string(forKey: Self.latencyHostKey) ?? Self.defaultLatencyHost
        notifiesAutomations = UserDefaults.standard.bool(forKey: Self.notifiesKey)
        speedTestServer = UserDefaults.standard.string(forKey: Self.speedTestServerKey)
            ?? SpeedTestRunner.defaultServer
        refreshProfiles()
        refreshAutomations()
        speedTests = engine.speedTests
        snapshot = engine.snapshot
    }

    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID }
    }

    var capabilities: [CapabilityStatus] { engine.capabilities }
    var capabilitiesJSON: String { engine.capabilitiesJSON() }
    var diagnostics: Diagnostics { engine.diagnostics() }

    // MARK: Mesure

    func start() {
        guard sampling == nil else { return }
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
    }

    private func sample() {
        interfaces = InterfaceCounters.read()
        #if targetEnvironment(simulator)
        // Dans le simulateur, les interfaces sont celles du Mac : `en0` y est souvent de
        // l'Ethernet. Elles prennent la famille du réseau courant, pour que la mesure vive.
        if let family = path.kind.interfaceClass {
            interfaces = interfaces.map {
                InterfaceReading(
                    name: $0.name,
                    kind: family,
                    receivedBytes: $0.receivedBytes,
                    sentBytes: $0.sentBytes
                )
            }
        }
        #endif
        snapshot = engine.ingest(interfaces)
        samples = engine.recentSamples
        sharingDetected = InterfaceCounters.sharingInterfaceIsUp()
        runAutomations()
        ticks += 1
        if ticks % 60 == 0 {
            historyRevision += 1
        }
        if ticks % 5 == 1 {
            probeLatency()
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

    func eraseHistory() {
        perform { try engine.eraseHistory() }
        refreshAutomations()
        speedTests = engine.speedTests
        samples = engine.recentSamples
        snapshot = engine.snapshot
    }

    func eraseAll() {
        perform { try engine.eraseAll() }
        refreshAutomations()
        speedTests = engine.speedTests
        latencyHost = Self.defaultLatencyHost
        speedTestServer = SpeedTestRunner.defaultServer
        samples = engine.recentSamples
        snapshot = engine.snapshot
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

import BackgroundTasks
import FluxaCore
import Foundation
import Observation
import UIKit

/// L'état de l'app : il relie le moteur aux services du système et aux écrans.
///
/// Chaque seconde, au premier plan, il relève les compteurs des interfaces et les donne
/// au moteur. Toutes les cinq secondes, il lance une sonde de latence ; moins souvent sur
/// réseau mobile, en mode économie d'énergie ou données réduites.
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
    /// L'état du relais de partage, relevé chaque seconde quand il est ouvert.
    private(set) var relayStatus: RelayStatus?
    /// Le débit de chaque appareil relayé, par adresse.
    private(set) var relayRates: [String: RelayRate] = [:]
    private(set) var relayError: String?
    /// Un relais qui tourne, mais pas comme prévu (extension refusée, relais dans l'app).
    private(set) var relayNotice: String?
    private var relayHost: any RelayHost = AppModel.preferredRelayHost()
    private var relayOpening = false
    /// Les plafonds donnés au relais en dernier, pour le resynchroniser quand le plafond
    /// affiché change par un autre chemin (automatisation, échéance, profil modifié).
    private var relaySentLimits: RelayLimits?
    /// La dernière relance automatique d'un relais arrêté sans qu'on le demande.
    private var relayLastReopen: Date?
    /// L'ouverture du relais en cours, pour l'activité en direct.
    private var relayOpenedAt: Date?
    private let widgets = WidgetPublisher()
    private let relayActivity = RelayActivityController()

    /// Montrer le relais sur l'écran verrouillé et dans la Dynamic Island.
    var showsRelayActivity: Bool {
        didSet {
            UserDefaults.standard.set(showsRelayActivity, forKey: Self.relayActivityKey)
            updateRelayActivity(force: true)
        }
    }
    private var relayRefreshing = false
    private var relayPreviousSample: (date: Date, clients: [String: RelayStatus.Client])?

    /// Le relais ouvert à la demande de l'utilisateur, rouvert au retour dans l'app.
    var relayEnabled: Bool {
        didSet { UserDefaults.standard.set(relayEnabled, forKey: Self.relayKey) }
    }

    /// L'écran reste allumé tant que le relais est ouvert : iOS suspend l'app sinon.
    var keepsScreenOnForRelay: Bool {
        didSet {
            UserDefaults.standard.set(keepsScreenOnForRelay, forKey: Self.keepsScreenOnKey)
            updateIdleTimer()
        }
    }

    /// Le profil de chaque appareil relayé, par adresse.
    private(set) var relayDeviceProfiles: [String: String] {
        didSet { UserDefaults.standard.set(relayDeviceProfiles, forKey: Self.relayDeviceProfilesKey) }
    }

    /// Le nom donné à chaque appareil relayé, par adresse.
    private(set) var relayDeviceNames: [String: String] {
        didSet { UserDefaults.standard.set(relayDeviceNames, forKey: Self.relayDeviceNamesKey) }
    }
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
    /// Secondes entre deux sondes : en temps normal, sur un réseau facturé à l'usage (réseau
    /// mobile : chaque sonde y réveille la radio, qui reste active plusieurs secondes), en
    /// mode économie d'énergie, et en mode données réduites.
    static let probeIntervals = (normal: 5, metered: 15, lowPower: 15, lowData: 30)
    private static let latencyHostKey = "latencyHost"
    private static let notifiesKey = "notifiesAutomations"
    private static let speedTestServerKey = "speedTestServer"
    private static let relayKey = "relayEnabled"
    private static let keepsScreenOnKey = "relayKeepsScreenOn"
    private static let relayDeviceProfilesKey = "relayDeviceProfiles"
    private static let relayDeviceNamesKey = "relayDeviceNames"
    private static let relayActivityKey = "relayLiveActivity"

    init() {
        let opened = Self.openStore()
        engine = FluxaEngine(store: opened.store)
        latencyHost = UserDefaults.standard.string(forKey: Self.latencyHostKey) ?? Self.defaultLatencyHost
        notifiesAutomations = UserDefaults.standard.bool(forKey: Self.notifiesKey)
        speedTestServer = UserDefaults.standard.string(forKey: Self.speedTestServerKey)
            ?? SpeedTestRunner.defaultServer
        relayEnabled = UserDefaults.standard.bool(forKey: Self.relayKey)
        keepsScreenOnForRelay = UserDefaults.standard.object(forKey: Self.keepsScreenOnKey) as? Bool ?? true
        relayDeviceProfiles = UserDefaults.standard.dictionary(forKey: Self.relayDeviceProfilesKey) as? [String: String] ?? [:]
        relayDeviceNames = UserDefaults.standard.dictionary(forKey: Self.relayDeviceNamesKey) as? [String: String] ?? [:]
        showsRelayActivity = UserDefaults.standard.object(forKey: Self.relayActivityKey) as? Bool ?? true
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
        if relayEnabled {
            Task { await resumeRelay() }
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
        // Avant la suspension : le dernier relevé pour les widgets et l'activité en direct.
        widgets.publish(widgetSnapshot(), force: true)
        updateRelayActivity(force: true)
        scheduleRelayRefresh()
        // iOS suspend l'app en arrière-plan : un relais dans l'app se ferme et se rouvre au
        // retour ; celui de l'extension réseau continue.
        if !relayHost.keepsRunningInBackground {
            RelayBridge.stop()
            relayStatus = nil
            engine.relayStopped()
            refreshProfiles()
        }
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
        syncRelayLimits()
        if ticks % Self.relayPollInterval(screenVisible: relayScreenVisible) == 0 {
            refreshRelay()
        }
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
        if ticks % 30 == 0 {
            widgets.publish(widgetSnapshot())
        }
        set(\.probeInterval, Self.probeInterval(
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            lowData: path.isConstrained,
            metered: path.isExpensive
        ))
        if ticks % probeInterval == 1 {
            probeLatency()
        }
    }

    /// L'intervalle des sondes selon les modes du système : la sonde coûte un peu de
    /// batterie et de données, elle ralentit quand l'utilisateur demande d'économiser.
    static func probeInterval(lowPower: Bool, lowData: Bool, metered: Bool = false) -> Int {
        if lowData { return probeIntervals.lowData }
        if lowPower { return probeIntervals.lowPower }
        if metered { return probeIntervals.metered }
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
        applyRelayLimits()
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
        let done = perform { _ = try engine.apply(policy) }
        applyRelayLimits()
        return done
    }

    // MARK: Relais de partage

    var relayIsRunning: Bool { relayStatus?.running == true }

    /// Vrai tant que l'écran du relais est affiché : son état y est relevé chaque seconde.
    var relayScreenVisible = false

    /// Secondes entre deux relevés de l'état du relais : chaque seconde à l'écran du relais,
    /// toutes les 5 secondes sinon. Avec l'extension réseau, chaque relevé réveille un
    /// second processus ; le débit reste juste, calculé sur le temps réellement écoulé.
    static func relayPollInterval(screenVisible: Bool) -> Int {
        screenVisible ? 1 : 5
    }

    /// Retente l'ouverture après un échec.
    func retryRelay() {
        relayEnabled = true
        relayError = nil
        Task { await openRelay() }
    }

    /// Vrai si le relais en service continue en arrière-plan (extension réseau).
    var relayRunsInBackground: Bool { relayIsRunning && relayHost.keepsRunningInBackground }

    /// Ouvre ou ferme le relais, à la demande de l'utilisateur.
    func setRelay(_ enabled: Bool) {
        relayEnabled = enabled
        Task {
            if enabled {
                await openRelay()
            } else {
                await closeRelay()
            }
        }
    }

    /// Sur iPhone, le relais tourne dans l'extension réseau ; dans le simulateur, où les
    /// extensions de tunnel ne tournent pas, et si l'extension est refusée, dans l'app.
    private static func preferredRelayHost() -> any RelayHost {
        #if targetEnvironment(simulator)
        return InAppRelayHost(allowLoopback: true)
        #else
        return TunnelRelayHost()
        #endif
    }

    private func openRelay() async {
        guard !relayOpening else { return }
        relayOpening = true
        defer { relayOpening = false }
        relayPreviousSample = nil
        relayRates = [:]
        let limits = relayLimits()
        // Chaque ouverture retente l'extension réseau, même après un repli dans l'app, et
        // libère d'abord le port qu'un relais de l'app tiendrait encore.
        relayHost = Self.preferredRelayHost()
        if relayHost.keepsRunningInBackground {
            RelayBridge.stop()
        }
        var problem = await relayHost.open(limits: limits)
        relayNotice = nil
        if let failure = problem, relayHost.keepsRunningInBackground {
            if await relayHost.isRunning() {
                // L'extension a fini par démarrer : c'est elle qui sert.
                await relayHost.apply(limits)
                problem = nil
            } else {
                // L'extension n'a pas démarré : le relais tourne dans l'app, au premier plan.
                let tunnel = relayHost
                relayHost = InAppRelayHost(allowLoopback: false)
                problem = await relayHost.open(limits: limits)
                if problem == Self.relayProblem(EADDRINUSE), await tunnel.isRunning() {
                    // Le port est pris par l'extension, démarrée entre-temps : on la reprend.
                    relayHost = tunnel
                    await tunnel.apply(limits)
                    problem = nil
                } else if problem == nil {
                    relayNotice = "\(failure) Le relais tourne dans l’app : gardez FLUXA ouvert."
                }
            }
        }
        relayError = problem
        if problem == nil {
            relaySentLimits = limits
            relayOpenedAt = relayOpenedAt ?? Date()
            confirmRelayLimit()
        }
        await refreshRelayNow()
        updateRelayActivity(force: true)
        updateIdleTimer()
    }

    /// Reprend un relais resté en service dans l'extension pendant que l'app était fermée.
    private func resumeRelay() async {
        // L'extension a pu rester en service, ou démarrer, pendant que l'app était fermée :
        // elle passe avant un éventuel repli dans l'app.
        let preferred = Self.preferredRelayHost()
        if preferred.keepsRunningInBackground, await preferred.isRunning() {
            relayHost = preferred
        }
        if await relayHost.isRunning() {
            let limits = relayLimits()
            await relayHost.apply(limits)
            relaySentLimits = limits
            confirmRelayLimit()
            await refreshRelayNow()
            updateIdleTimer()
        } else {
            await openRelay()
        }
    }

    private func closeRelay() async {
        await relayHost.close()
        // La prochaine ouverture retente l'extension.
        relayHost = Self.preferredRelayHost()
        relayStatus = nil
        relayRates = [:]
        relayPreviousSample = nil
        relaySentLimits = nil
        relayLastReopen = nil
        relayOpenedAt = nil
        relayActivity.end()
        relayNotice = nil
        relayError = nil
        engine.relayStopped()
        refreshProfiles()
        updateIdleTimer()
    }

    /// Le relais doit être ouvert mais ne répond plus (iOS a arrêté l'extension, par
    /// exemple faute de mémoire) : l'app le relance, au plus toutes les 30 secondes.
    private func reopenStoppedRelay(wasRunning: Bool) {
        let now = Date()
        guard relayEnabled, relayError == nil, !relayOpening, wasRunning || relayLastReopen != nil,
              Self.shouldReopenRelay(lastAttempt: relayLastReopen, now: now)
        else { return }
        relayLastReopen = now
        Task {
            await openRelay()
            if relayIsRunning {
                relayNotice = "Le relais s’était arrêté : FLUXA l’a rouvert."
            }
        }
    }

    static func shouldReopenRelay(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= 30
    }

    static func relayProblem(_ code: Int32) -> String {
        switch code {
        case EADDRINUSE:
            return "Le port \(RelayBridge.port) est déjà utilisé : le relais n’a pas pu s’ouvrir."
        case EACCES, EPERM:
            return "iOS a refusé l’ouverture du relais (erreur \(code))."
        default:
            return "Le relais n’a pas pu s’ouvrir (erreur \(code))."
        }
    }

    /// Le plafond en cours et celui de chaque appareil.
    private func relayLimits() -> RelayLimits {
        let policy = engine.lastApplyResult?.requested ?? activeProfile?.policy
        var limits = RelayLimits(download: policy?.downloadBps, upload: policy?.uploadBps)
        for (address, profileID) in relayDeviceProfiles {
            let profile = profiles.first { $0.id == profileID }
            limits.devices[address] = (profile?.downloadBps, profile?.uploadBps)
        }
        return limits
    }

    /// Le relais pose réellement le plafond : la limite est consignée comme partielle.
    private func confirmRelayLimit() {
        let policy = engine.lastApplyResult?.requested ?? activeProfile?.policy
        guard let policy, policy.downloadBps != nil || policy.uploadBps != nil else { return }
        _ = try? engine.confirmRelayLimit(policy)
        refreshProfiles()
        historyRevision += 1
    }

    /// Donne au relais en service les plafonds du moment.
    private func applyRelayLimits() {
        guard relayIsRunning else { return }
        let limits = relayLimits()
        relaySentLimits = limits
        Task {
            await relayHost.apply(limits)
            confirmRelayLimit()
        }
    }

    /// Nomme un appareil relayé. Un nom vide le retire : l'adresse reprend sa place.
    func setRelayName(_ name: String, for address: String) {
        relayDeviceNames[address] = RelayText.cleanName(name)
    }

    /// Le profil d'un appareil relayé. `nil` : plus de plafond propre à l'appareil.
    func setRelayProfile(_ profileID: String?, for address: String) {
        relayDeviceProfiles[address] = profileID
        guard relayIsRunning else { return }
        var limits = relayLimits()
        // Un appareil sans profil voit son plafond retiré.
        if profileID == nil {
            limits.devices[address] = (nil, nil)
        }
        relaySentLimits = relayLimits()
        Task { await relayHost.apply(limits) }
    }

    /// Si le plafond affiché a changé sans passer par le relais (règle qui change de
    /// profil, limite arrivée à échéance, profil actif modifié), le relais le reçoit :
    /// l'app n'affiche jamais un plafond que le relais n'applique pas.
    private func syncRelayLimits() {
        guard relayIsRunning, !relayOpening else { return }
        if Self.relayNeedsUpdate(sent: relaySentLimits, wanted: relayLimits()) {
            applyRelayLimits()
        }
    }

    static func relayNeedsUpdate(sent: RelayLimits?, wanted: RelayLimits) -> Bool {
        sent != wanted
    }

    /// Relève l'état du relais, sans chevaucher le relevé précédent.
    private func refreshRelay() {
        guard relayEnabled, relayError == nil, !relayOpening, !relayRefreshing else { return }
        relayRefreshing = true
        Task {
            await refreshRelayNow()
            relayRefreshing = false
        }
    }

    private func refreshRelayNow() async {
        guard let status = await relayHost.status(), status.running else {
            let wasRunning = relayStatus != nil
            set(\.relayStatus, nil)
            reopenStoppedRelay(wasRunning: wasRunning)
            return
        }
        let now = Date()
        let clients = status.clients ?? []
        if let previous = relayPreviousSample {
            let seconds = now.timeIntervalSince(previous.date)
            var rates: [String: RelayRate] = [:]
            for client in clients {
                rates[client.address] = RelayRate.between(previous.clients[client.address], client, seconds: seconds)
            }
            set(\.relayRates, rates)
        }
        relayPreviousSample = (now, Dictionary(uniqueKeysWithValues: clients.map { ($0.address, $0) }))
        set(\.relayStatus, status)
        updateRelayActivity()
    }

    // MARK: Widgets et activité en direct

    /// Le relevé du moment, tel que les widgets l'affichent.
    func widgetSnapshot(now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(
            updatedAt: now,
            network: path.title,
            isOnline: snapshot.isOnline,
            downloadBps: snapshot.downloadBps,
            uploadBps: snapshot.uploadBps,
            todayBytes: snapshot.receivedBytesToday + snapshot.sentBytesToday,
            plan: plan.map {
                WidgetSnapshot.Plan(
                    usedBytes: $0.usedBytes, allowanceBytes: $0.plan.allowanceBytes,
                    remainingBytes: $0.remainingBytes, fractionUsed: $0.fractionUsed, cycleEnd: $0.cycleEnd)
            },
            relay: relayIsRunning ? relayWidgetState() : nil
        )
    }

    private func relayWidgetState() -> WidgetSnapshot.Relay {
        let state = relayActivityState(now: Date())
        return WidgetSnapshot.Relay(devices: state.devices, toDevicesBps: state.toDevicesBps, cap: state.cap)
    }

    /// L'état du relais pour l'activité en direct : appareils actifs, débit vers eux,
    /// plafond, et l'heure du relevé.
    func relayActivityState(now: Date) -> RelayActivityAttributes.ContentState {
        let active = (relayStatus?.clients ?? []).filter { $0.connections > 0 }
        let measured = active.compactMap { relayRates[$0.address]?.toDeviceBps }
        return RelayActivityAttributes.ContentState(
            devices: active.count,
            toDevicesBps: measured.isEmpty ? nil : measured.reduce(0, +),
            cap: RelayText.cap(lastApply?.requested ?? activeProfile?.policy),
            updatedAt: now
        )
    }

    // MARK: Rafraîchissement en arrière-plan

    /// La tâche qu'iOS lance de temps en temps quand l'app est suspendue (au mieux toutes
    /// les quinze minutes, sans garantie).
    static var relayRefreshIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "app.fluxa.ios") + ".relay-refresh"
    }

    /// Demande un réveil si le relais tourne en arrière-plan avec son activité en direct.
    private func scheduleRelayRefresh() {
        guard relayRunsInBackground, showsRelayActivity else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.relayRefreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// App réveillée en arrière-plan : l'état réel du relais est demandé à l'extension, deux
    /// fois à une seconde d'écart pour en tirer le débit, et l'activité est mise à jour.
    func refreshRelayInBackground() async {
        guard relayEnabled, showsRelayActivity, relayHost.keepsRunningInBackground,
              await relayHost.isRunning(),
              let first = await relayHost.status(), first.running
        else { return }
        try? await Task.sleep(for: .seconds(1))
        guard let second = await relayHost.status(), second.running else { return }
        let state = Self.relayActivityState(
            first: first, second: second, seconds: 1,
            cap: RelayText.cap(lastApply?.requested ?? activeProfile?.policy), now: Date())
        if relayActivity.isRunning {
            relayActivity.update(state, force: true)
        } else {
            relayActivity.start(state, since: relayOpenedAt ?? Date())
        }
        scheduleRelayRefresh()
    }

    /// L'état de l'activité à partir de deux relevés du relais : appareils actifs et débit
    /// vers eux entre les deux. Sans écart mesurable, pas de débit inventé.
    static func relayActivityState(
        first: RelayStatus, second: RelayStatus, seconds: Double, cap: String, now: Date
    ) -> RelayActivityAttributes.ContentState {
        let before = Dictionary(uniqueKeysWithValues: (first.clients ?? []).map { ($0.address, $0) })
        let active = (second.clients ?? []).filter { $0.connections > 0 }
        let rates = active.compactMap { RelayRate.between(before[$0.address], $0, seconds: seconds).toDeviceBps }
        return RelayActivityAttributes.ContentState(
            devices: active.count,
            toDevicesBps: rates.isEmpty ? nil : rates.reduce(0, +),
            cap: cap,
            updatedAt: now
        )
    }

    private func updateRelayActivity(force: Bool = false) {
        guard showsRelayActivity, relayIsRunning else {
            if relayActivity.isRunning {
                relayActivity.end()
            }
            return
        }
        let state = relayActivityState(now: Date())
        if relayActivity.isRunning {
            relayActivity.update(state, force: force)
        } else {
            relayActivity.start(state, since: relayOpenedAt ?? Date())
        }
    }

    private func updateIdleTimer() {
        // L'extension réseau tient le relais en arrière-plan : l'écran peut s'éteindre.
        UIApplication.shared.isIdleTimerDisabled =
            relayStatus != nil && keepsScreenOnForRelay && !relayHost.keepsRunningInBackground
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

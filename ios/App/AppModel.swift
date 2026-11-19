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
    var errorMessage: String?

    /// L'hôte de la sonde de latence. Réglable dans les réglages.
    var latencyHost: String {
        didSet { UserDefaults.standard.set(latencyHost, forKey: Self.latencyHostKey) }
    }

    static let defaultLatencyHost = "www.apple.com"
    private static let latencyHostKey = "latencyHost"

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        engine = FluxaEngine(store: FileStore(url: folder.appendingPathComponent("fluxa.json")))
        latencyHost = UserDefaults.standard.string(forKey: Self.latencyHostKey) ?? Self.defaultLatencyHost
        refreshProfiles()
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
        ticks += 1
        if ticks % 60 == 0 {
            historyRevision += 1
        }
        if ticks % 5 == 1 {
            probeLatency()
        }
    }

    private func probeLatency() {
        guard !probing, path.isOnline else { return }
        probing = true
        let host = latencyHost
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

    /// Renvoie `true` si le profil est enregistré.
    @discardableResult
    func saveProfile(id: String?, name: String, downloadMbps: Double?, uploadMbps: Double?) -> Bool {
        perform {
            _ = try engine.saveProfile(id: id, name: name, downloadMbps: downloadMbps, uploadMbps: uploadMbps)
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

    // MARK: Historique et données

    func history(from: Date, to: Date, step: HistoryStep) -> [Aggregate] {
        engine.history(from: from, to: to, step: step)
    }

    func usage(from: Date, to: Date) -> UsageSummary {
        engine.usage(from: from, to: to)
    }

    func eraseHistory() {
        perform { try engine.eraseHistory() }
        samples = engine.recentSamples
        snapshot = engine.snapshot
    }

    func eraseAll() {
        perform { try engine.eraseAll() }
        latencyHost = Self.defaultLatencyHost
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

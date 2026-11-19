import XCTest

@testable import FluxaCore

final class StoreTests: XCTestCase {
    private func reopen(_ store: any EngineStore, _ clock: TestClock) -> FluxaEngine {
        FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
    }

    /// Un moteur avec des mesures, un profil créé, un préréglage modifié et des demandes.
    private func filled(_ store: any EngineStore, _ clock: TestClock) throws -> Bench {
        let bench = Bench(store: store, clock: clock).started()
        bench.measure(seconds: 75, down: 20, up: 4)
        try bench.engine.saveProfile(id: nil, name: "Visio", downloadMbps: 8, uploadMbps: 4)
        try bench.engine.saveProfile(id: "streaming", name: "Streaming 4K", downloadMbps: 30, uploadMbps: 10)
        try bench.engine.applyToDevice(BandwidthPolicy(downloadBps: 2_000_000))
        try bench.engine.activateProfile(id: "custom-1")
        return bench
    }

    func testAFreshStoreStartsEmpty() {
        let engine = Bench().engine
        let diagnostics = engine.diagnostics()
        XCTAssertEqual(diagnostics.engineVersion, FluxaEngine.version)
        XCTAssertEqual(
            [diagnostics.minuteAggregates, diagnostics.hourAggregates, diagnostics.dayAggregates,
             diagnostics.policyRecords], [0, 0, 0, 0])
        XCTAssertNil(diagnostics.storeLocation)
        XCTAssertEqual(diagnostics.events.map(\.message), ["Moteur démarré."])
        XCTAssertEqual(engine.profiles.count, 7)
        XCTAssertEqual(engine.snapshot, NetworkSnapshot())
    }

    func testTheStateSurvivesARestart() throws {
        let store = MemoryStore()
        let clock = TestClock()
        let bench = try filled(store, clock)
        try bench.engine.flush()

        let reopened = reopen(store, clock)
        XCTAssertEqual(reopened.profiles, bench.engine.profiles)
        XCTAssertEqual(reopened.profiles[4].name, "Streaming 4K")
        XCTAssertTrue(reopened.profiles[4].isBuiltin)
        XCTAssertEqual(reopened.activeProfileID, "custom-1")
        XCTAssertEqual(reopened.lastApplyResult, bench.engine.lastApplyResult)
        XCTAssertEqual(reopened.lastApplyResult?.status, .simulated)
        XCTAssertEqual(reopened.policyLog(limit: 10), bench.engine.policyLog(limit: 10))
        XCTAssertEqual(reopened.policyLog(limit: 10).map(\.status), [.simulated, .unsupported])
        for step in HistoryStep.allCases {
            XCTAssertEqual(
                reopened.history(from: .distantPast, to: .distantFuture, step: step),
                bench.engine.history(from: .distantPast, to: .distantFuture, step: step), "\(step)")
        }
        XCTAssertEqual(reopened.history(from: .distantPast, to: .distantFuture, step: .minute).count, 2)
        // Un nouveau profil ne reprend pas un identifiant déjà donné.
        XCTAssertEqual(
            try reopened.saveProfile(id: nil, name: "Jeu", downloadMbps: 1, uploadMbps: 1).id, "custom-2")
    }

    func testTheFileStoreRoundTrips() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileStore(url: url)
        XCTAssertEqual(store.location, url.path)
        XCTAssertNil(try store.load(), "pas encore de fichier")

        let clock = TestClock()
        let bench = try filled(store, clock)
        try bench.engine.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "le dossier est créé au besoin")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["fluxa.json"], "aucun fichier temporaire ne reste")

        let reopened = reopen(FileStore(url: url), clock)
        XCTAssertEqual(reopened.profiles, bench.engine.profiles)
        XCTAssertEqual(reopened.lastApplyResult, bench.engine.lastApplyResult)
        XCTAssertEqual(
            reopened.history(from: .distantPast, to: .distantFuture, step: .minute),
            bench.engine.history(from: .distantPast, to: .distantFuture, step: .minute))
        XCTAssertEqual(reopened.snapshot.receivedBytesToday, 75 * 2_500_000)
        XCTAssertEqual(reopened.diagnostics().storeLocation, url.path)

        try store.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNoThrow(try store.erase(), "effacer deux fois ne gêne pas")
    }

    func testAggregatesAreStoredCompactly() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bench = Bench(store: FileStore(url: url)).started()
        bench.measure(seconds: 5, down: 20, up: 4)
        try bench.engine.flush()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, 2, "le format qui porte le forfait et le volume par réseau")
        let minutes = object?["minutes"] as? [[Any]]
        XCTAssertEqual(minutes?.count, 1)
        XCTAssertEqual(minutes?.first?.count, 7, "sept nombres par période")
        let networkHours = object?["networkHours"] as? [[Any]]
        XCTAssertEqual(networkHours?.count, 1)
        XCTAssertEqual(networkHours?.first?.count, 4, "début, réseau, reçu, envoyé")
        XCTAssertEqual(networkHours?.first?[1] as? String, "cellular")
    }

    func testAnUnreadableFileStartsEmptyAndSaysSo() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ ceci n'est pas du JSON".utf8).write(to: url)

        let store = FileStore(url: url)
        XCTAssertThrowsError(try store.load())
        let engine = reopen(store, TestClock())
        XCTAssertEqual(engine.profiles.count, 7)
        XCTAssertNil(engine.activeProfileID)
        let events = engine.diagnostics().events
        XCTAssertEqual(events.first?.level, .error)
        XCTAssertTrue(events.first?.message.contains("illisibles") ?? false)
        // Le moteur reste utilisable et réécrit un fichier sain.
        try engine.activateProfile(id: "standard")
        try engine.flush()
        XCTAssertEqual(reopen(FileStore(url: url), TestClock()).activeProfileID, "standard")
    }

    func testAStoreThatFailsToLoadDoesNotCrash() {
        let store = FailingStore()
        store.failsOnLoad = true
        let engine = reopen(store, TestClock())
        XCTAssertEqual(engine.profiles.count, 7)
        XCTAssertEqual(engine.diagnostics().events.first?.level, .error)
        XCTAssertEqual(engine.diagnostics().storeLocation, "test")
    }

    func testANewerFormatIsRefusedAndAnOlderOneIsCompleted() throws {
        let newer = Data(#"{"version": 99, "profiles": []}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EngineState.self, from: newer))

        // Un fichier qui ne connaît que les profils : le reste prend ses valeurs par défaut.
        let partial = Data(
            #"{"profiles":[{"id":"perso","name":"Perso","downloadBps":3000000,"isBuiltin":false}],"activeProfileID":"perso"}"#
                .utf8)
        var state = try JSONDecoder().decode(EngineState.self, from: partial)
        XCTAssertEqual(state.policyLog, [])
        XCTAssertEqual(state.minutes.count, 0)
        state.restoreBuiltinProfiles()
        XCTAssertEqual(state.profiles.count, 8)
        XCTAssertEqual(state.profiles.last?.id, "perso")
        XCTAssertEqual(state.activeProfileID, "perso")
        XCTAssertEqual(EngineState(), EngineState())
    }

    func testBuiltinProfilesAreRestoredInOrder() {
        var state = EngineState()
        state.profiles = [
            Profile(id: "perso", name: "Perso", downloadBps: nil, uploadBps: nil, isBuiltin: true),
            Profile(id: "streaming", name: "Mon streaming", downloadBps: 30_000_000, uploadBps: nil, isBuiltin: false),
            Profile(id: "perso", name: "Doublon", downloadBps: nil, uploadBps: nil, isBuiltin: false),
        ]
        state.activeProfileID = "disparu"
        state.restoreBuiltinProfiles()
        XCTAssertEqual(
            state.profiles.map(\.id),
            ["economy", "very-slow", "browsing", "standard", "streaming", "performance", "maximum", "perso"])
        XCTAssertEqual(state.profiles[4].name, "Mon streaming", "les valeurs modifiées sont gardées")
        XCTAssertTrue(state.profiles[4].isBuiltin)
        XCTAssertFalse(state.profiles[7].isBuiltin, "seuls les sept préréglages sont protégés")
        XCTAssertNil(state.activeProfileID)
    }

    func testTheEngineSavesAtTheEndOfEachMinute() {
        let store = FailingStore()
        let bench = Bench(store: store).started()
        bench.measure(seconds: 59, down: 10, up: 1)
        XCTAssertEqual(store.saveCount, 0, "la première minute n'est pas finie")
        bench.measure(seconds: 1, down: 10, up: 1)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.saved?.minutes.count, 1)
        XCTAssertEqual(store.saved?.minutes.buckets.first?.sampleCount, 59)
        bench.measure(seconds: 120, down: 10, up: 1)
        XCTAssertEqual(store.saveCount, 3)
        // L'arrêt enregistre aussi, pour ne rien perdre de la minute en cours.
        bench.engine.stop()
        XCTAssertEqual(store.saveCount, 4)
        XCTAssertEqual(store.saved?.minutes.buckets.map(\.sampleCount).reduce(0, +), 180)
    }

    func testChangesToProfilesAndLimitsAreSavedAtOnce() throws {
        let store = FailingStore()
        let engine = reopen(store, TestClock())
        try engine.saveProfile(id: nil, name: "Visio", downloadMbps: 8, uploadMbps: 4)
        XCTAssertEqual(store.saved?.profiles.count, 8)
        try engine.activateProfile(id: "custom-1")
        XCTAssertEqual(store.saved?.activeProfileID, "custom-1")
        try engine.applyToDevice(BandwidthPolicy(downloadBps: 1_000_000))
        XCTAssertEqual(store.saved?.policyLog.count, 2)
        try engine.apply(BandwidthPolicy(downloadBps: 1_000_000))
        XCTAssertNil(store.saved?.activeProfileID)
        try engine.deleteProfile(id: "custom-1")
        XCTAssertEqual(store.saved?.profiles.count, 7)
    }

    func testASaveFailureIsLoggedAndFlushThrows() throws {
        let store = FailingStore()
        store.failsOnSave = true
        let bench = Bench(store: store).started()
        // Une demande aboutit même si le disque refuse : l'échec est noté.
        let result = try bench.engine.activateProfile(id: "standard")
        XCTAssertEqual(result.status, .simulated)
        XCTAssertEqual(bench.engine.diagnostics().events.first?.level, .error)
        XCTAssertTrue(bench.engine.diagnostics().events.first?.message.contains("disque plein") ?? false)
        bench.measure(seconds: 61, down: 10, up: 1)

        XCTAssertThrows(try bench.engine.flush(), .store("disque plein."))
        XCTAssertThrows(try bench.engine.eraseHistory(), .store("disque plein."))
        // Dès que le disque répond, tout l'état part d'un coup.
        store.failsOnSave = false
        try bench.engine.activateProfile(id: "economy")
        try bench.engine.flush()
        XCTAssertEqual(store.saved?.activeProfileID, "economy")
    }

    func testErasingTheHistoryKeepsProfilesAndTheCurrentLimit() throws {
        let store = MemoryStore()
        let clock = TestClock()
        let bench = try filled(store, clock)
        try bench.engine.eraseHistory()

        let diagnostics = bench.engine.diagnostics()
        XCTAssertEqual(
            [diagnostics.minuteAggregates, diagnostics.hourAggregates, diagnostics.dayAggregates,
             diagnostics.policyRecords], [0, 0, 0, 0])
        XCTAssertEqual(diagnostics.events.map(\.message), ["Historique effacé."])
        XCTAssertTrue(bench.engine.recentSamples.isEmpty)
        XCTAssertEqual(bench.engine.snapshot.receivedBytesToday, 0)
        XCTAssertEqual(bench.engine.profiles.count, 8)
        XCTAssertEqual(bench.engine.activeProfileID, "custom-1")
        XCTAssertEqual(bench.engine.lastApplyResult?.status, .simulated)
        XCTAssertTrue(bench.engine.isMonitoring, "la mesure continue")

        bench.measure(seconds: 2, down: 20, up: 4)
        XCTAssertEqual(bench.engine.snapshot.receivedBytesToday, 2 * 2_500_000)
        // L'effacement est enregistré : rien ne revient au redémarrage.
        let reopened = reopen(store, clock)
        XCTAssertTrue(reopened.policyLog(limit: 10).isEmpty)
        XCTAssertEqual(reopened.profiles.count, 8)
    }

    func testErasingEverythingLeavesTheOriginalPresets() throws {
        let store = MemoryStore()
        let clock = TestClock()
        let bench = try filled(store, clock)
        try bench.engine.flush()
        try bench.engine.eraseAll()

        XCTAssertEqual(bench.engine.profiles, Bench().engine.profiles)
        XCTAssertNil(bench.engine.activeProfileID)
        XCTAssertNil(bench.engine.lastApplyResult)
        XCTAssertTrue(bench.engine.policyLog(limit: 10).isEmpty)
        XCTAssertEqual(bench.engine.diagnostics().minuteAggregates, 0)
        XCTAssertEqual(bench.engine.snapshot.sentBytesToday, 0)
        XCTAssertNil(try store.load(), "le stockage est vidé")
        XCTAssertEqual(reopen(store, clock).profiles.count, 7)
        // Les identifiants repartent de un.
        XCTAssertEqual(
            try bench.engine.saveProfile(id: nil, name: "Neuf", downloadMbps: 1, uploadMbps: 1).id,
            "custom-1")
    }

    func testAnEraseFailureIsReported() {
        let store = FailingStore()
        store.failsOnErase = true
        let engine = reopen(store, TestClock())
        XCTAssertThrowsError(try engine.eraseAll()) { error in
            guard case .store = error as? FluxaError else { return XCTFail("\(error)") }
        }
    }

    func testEventsAreNewestFirstAndBounded() throws {
        let bench = Bench()
        bench.engine.start()
        bench.clock.advance(5)
        bench.engine.updatePath(kind: .wifi, isOnline: true)
        bench.engine.stop()
        var events = bench.engine.diagnostics().events
        XCTAssertEqual(
            events.map(\.message),
            ["Mesure arrêtée.", "Réseau : Wi-Fi.", "Mesure démarrée.", "Moteur démarré."])
        XCTAssertEqual(events.map(\.id), [4, 3, 2, 1])
        XCTAssertEqual(events.first?.date, noon.addingTimeInterval(5))
        XCTAssertTrue(events.allSatisfy { $0.level == .info })
        XCTAssertFalse(bench.engine.diagnostics().isMonitoring)

        for index in 0..<300 {
            bench.engine.updatePath(kind: index % 2 == 0 ? .cellular : .wifi, isOnline: true)
        }
        events = bench.engine.diagnostics().events
        XCTAssertEqual(events.count, FluxaEngine.eventCapacity)
        XCTAssertEqual(events.first?.id, 304)
        XCTAssertEqual(Set(events.map(\.id)).count, events.count, "identifiants uniques")
    }
}

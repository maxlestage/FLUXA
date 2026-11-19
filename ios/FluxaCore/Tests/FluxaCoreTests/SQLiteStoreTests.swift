import XCTest

@testable import FluxaCore

final class SQLiteStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("fluxa.sqlite") }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluxa-sqlite-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Un état riche, produit par le moteur lui-même : profils créés et modifiés, journal
    /// des limites, agrégats des trois pas, règles dont une en cours d'effet, appareils,
    /// tests de débit, réglages. Les dates ont des fractions de seconde.
    private func richState() throws -> EngineState {
        let memory = MemoryStore()
        let clock = TestClock(noon.addingTimeInterval(0.123456789))
        let bench = Bench(store: memory, clock: clock, counterWidth: .bits64).started()
        let engine = bench.engine

        bench.measure(seconds: 130, down: 20, up: 4)
        clock.advance(2 * hour)
        bench.rebase()
        bench.measure(seconds: 70, down: 42.8, up: 8.4)
        clock.advance(day)
        bench.rebase()
        bench.measure(seconds: 5, down: 1, up: 0.5)

        let visio = try engine.saveProfile(id: nil, name: "Visio « HD »", downloadMbps: 12.5, uploadMbps: nil)
        try engine.saveProfile(id: "streaming", name: "Streaming 4K", downloadMbps: 30, uploadMbps: 10)
        try engine.apply(BandwidthPolicy(downloadBps: 3_000_000, mode: .softLimit, durationSeconds: 86_400))
        try engine.applyToDevice(BandwidthPolicy(uploadBps: 500_000, mode: .priority))
        try engine.activateProfile(id: "standard")

        try engine.saveRule(
            AutomationRule(
                name: "Journée", trigger: .schedule(startMinute: 0, endMinute: 1_439, weekdays: []),
                action: .activateProfile(id: visio.id)))
        try engine.saveRule(
            AutomationRule(
                name: "Forfait", isEnabled: false, trigger: .dailyUsage(bytes: 2_000_000_000), action: .alert))
        try engine.saveRule(
            AutomationRule(
                name: "Semaine", trigger: .schedule(startMinute: 1_320, endMinute: 420, weekdays: [2, 3, 4, 5, 6]),
                action: .alert))
        XCTAssertEqual(engine.evaluateAutomations().count, 1, "la règle « Journée » est en cours d'effet")

        try engine.saveDevice(Device(name: "MacBook", kind: .computer, profileID: visio.id, note: "bureau"))
        try engine.saveDevice(Device(name: "Télé", kind: .television))
        engine.recordSpeedTest(
            SpeedTestResult(
                date: clock.date, downloadBps: 87_654_321.5, uploadBps: nil, latencyMs: 23.4,
                networkKind: .cellular, server: "test.example", downloadedBytes: .max, uploadedBytes: 0))
        engine.recordSpeedTest(
            SpeedTestResult(
                date: clock.date.addingTimeInterval(-hour), downloadBps: nil, uploadBps: 1_000, latencyMs: nil,
                networkKind: .wifi, server: "autre.example", downloadedBytes: 0, uploadedBytes: 42))
        try engine.flush()

        let state = try XCTUnwrap(try memory.load())
        XCTAssertEqual(state.minutes.count, 6)
        XCTAssertEqual(state.hours.count, 3)
        XCTAssertEqual(state.days.count, 2)
        XCTAssertEqual(state.activations.count, 1)
        XCTAssertEqual(state.policyLog.count, 4)
        return state
    }

    // MARK: Base neuve

    func testANewDatabaseIsEmptyAndCreatedWithItsSchema() throws {
        let store = try SQLiteStore(url: url)
        XCTAssertNil(try store.load(), "aucune donnée")
        XCTAssertEqual(store.location, url.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "le dossier est créé au besoin")

        let database = try SQLiteDatabase(path: url.path)
        XCTAssertEqual(try database.integer("PRAGMA user_version"), Int64(SQLiteStore.schemaVersion))
        XCTAssertEqual(try database.rows("PRAGMA journal_mode") { $0.text(0) }, ["wal"])
        let tables = try database.rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") {
            $0.text(0)
        }
        XCTAssertEqual(
            tables,
            [
                "app_settings", "automation_events", "bandwidth_profiles", "devices", "policy_applications",
                "rule_activations", "scheduled_rules", "speed_tests", "usage_records",
            ])
        XCTAssertEqual(Set(tables), Set(SQLiteStore.tables))
    }

    func testReopeningDoesNotRecreateTheSchema() throws {
        _ = try SQLiteStore(url: url)
        let again = try SQLiteStore(url: url)
        XCTAssertNil(try again.load())
    }

    // MARK: Aller-retour

    func testARichStateRoundTripsExactly() throws {
        let state = try richState()
        let store = try SQLiteStore(url: url)
        try store.save(state)
        XCTAssertEqual(try store.load(), state)

        // Par une autre instance, sur le même fichier.
        let reopened = try SQLiteStore(url: url)
        let loaded = try XCTUnwrap(try reopened.load())
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.profiles.map(\.id).suffix(1), ["custom-1"])
        XCTAssertEqual(loaded.profiles[4].name, "Streaming 4K")
        XCTAssertEqual(loaded.speedTests.first?.downloadedBytes, .max, "un entier non signé garde tous ses bits")
        XCTAssertNil(loaded.speedTests.first?.uploadBps, "une phase absente reste absente")

        // Lire, enregistrer, relire : le même état, et rien à écrire.
        try reopened.save(loaded)
        XCTAssertEqual(reopened.lastSaveChanges, 0)
        XCTAssertEqual(try reopened.load(), state)
    }

    func testTheDatabaseHasTypedColumns() throws {
        let state = try richState()
        try SQLiteStore(url: url).save(state)
        let database = try SQLiteDatabase(path: url.path)

        XCTAssertEqual(
            try database.rows("SELECT step, COUNT(*) FROM usage_records GROUP BY step ORDER BY step") {
                "\($0.text(0)):\($0.int(1))"
            }, ["day:2", "hour:3", "minute:6"])
        // Les volumes se somment en SQL : ce sont de vrais entiers.
        let received = try database.integer("SELECT SUM(received_bytes) FROM usage_records WHERE step = 'day'")
        XCTAssertEqual(UInt64(received), state.days.buckets.map(\.receivedBytes).reduce(0, +))
        XCTAssertEqual(
            try database.rows("SELECT name, download_bps, upload_bps, is_builtin FROM bandwidth_profiles WHERE id = 'custom-1'") {
                "\($0.text(0))|\($0.int(1))|\($0.isNull(2))|\($0.int(3))"
            }, ["Visio « HD »|12500000|true|0"])
        XCTAssertEqual(
            try database.rows("SELECT status FROM policy_applications ORDER BY seq") { $0.text(0) },
            ["simulated", "unsupported", "simulated", "simulated"])
        XCTAssertEqual(
            try database.rows("SELECT name, is_enabled FROM scheduled_rules ORDER BY position") {
                "\($0.text(0)):\($0.int(1))"
            }, ["Journée:1", "Forfait:0", "Semaine:1"])
        XCTAssertEqual(
            try database.rows("SELECT rule_id, applied_profile_id, previous_profile_id FROM rule_activations") {
                "\($0.text(0)) \($0.text(1)) \($0.text(2))"
            }, ["rule-1 custom-1 standard"])
        XCTAssertEqual(
            try database.rows("SELECT name, kind, profile_id, note FROM devices ORDER BY position") {
                "\($0.text(0))|\($0.text(1))|\($0.optionalText(2) ?? "-")|\($0.text(3))"
            }, ["MacBook|computer|custom-1|bureau", "Télé|television|-|"])
        XCTAssertEqual(
            try database.rows("SELECT server, network_kind FROM speed_tests ORDER BY tested_at DESC") {
                "\($0.text(0)) \($0.text(1))"
            }, ["test.example cellular", "autre.example wifi"])
        XCTAssertEqual(
            try database.rows("SELECT value FROM app_settings WHERE key = 'active_profile_id'") { $0.text(0) },
            ["custom-1"])
        XCTAssertEqual(try database.integer("SELECT COUNT(*) FROM automation_events"), 1)
    }

    func testAnEmptyStateIsStoredAsSuch() throws {
        let store = try SQLiteStore(url: url)
        try store.save(EngineState())
        XCTAssertEqual(try store.load(), EngineState(), "enregistré, donc plus une base neuve")
        XCTAssertEqual(try SQLiteStore(url: url).load(), EngineState())
    }

    // MARK: Incrémental

    func testSavingAgainWithoutChangeWritesNothing() throws {
        let state = try richState()
        let store = try SQLiteStore(url: url)
        try store.save(state)
        XCTAssertGreaterThan(store.lastSaveChanges, 30)

        let database = try SQLiteDatabase(path: url.path)
        let version = try database.integer("PRAGMA data_version")
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 0)
        XCTAssertEqual(try database.integer("PRAGMA data_version"), version, "le fichier n'a pas été touché")
    }

    func testOnlyChangedRowsAreWritten() throws {
        var state = try richState()
        let store = try SQLiteStore(url: url)
        try store.save(state)

        // Une mesure de plus dans une minute déjà connue : une seule ligne.
        let start = try XCTUnwrap(state.minutes.buckets.last?.start)
        state.minutes.add(
            Measurement(date: start, seconds: 1, receivedBytes: 1_000, sentBytes: 10), at: start)
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 1)

        // Une minute nouvelle : une ligne. Une minute purgée : une ligne.
        let next = start.addingTimeInterval(60)
        state.minutes.add(Measurement(date: next, seconds: 1, receivedBytes: 5, sentBytes: 5), at: next)
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 1)
        state.minutes.removeAll(before: state.minutes.buckets[1].start)
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 1)

        // Un appareil renommé, un réglage changé.
        state.devices[1].name = "Télévision"
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 1)
        state.activeProfileID = "economy"
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 1)
        state.activeProfileID = nil
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 1, "un réglage absent est une ligne supprimée")

        // Le journal perd sa plus vieille ligne et en gagne une : deux lignes, pas tout le journal.
        var entry = try XCTUnwrap(state.policyLog.last)
        entry.date = entry.date.addingTimeInterval(60)
        state.policyLog.removeFirst()
        state.policyLog.append(entry)
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 2)

        // Un profil supprimé au milieu : sa ligne, et celle du suivant qui change de place.
        state.profiles.remove(at: 6)
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 2)

        XCTAssertEqual(try SQLiteStore(url: url).load(), state, "la base suit l'état, changement après changement")
    }

    func testALogRewrittenFromScratchIsStillRight() throws {
        var state = try richState()
        let store = try SQLiteStore(url: url)
        try store.save(state)
        state.policyLog.reverse()
        state.automationLog.removeAll()
        try store.save(state)
        XCTAssertEqual(try SQLiteStore(url: url).load(), state)
        // Puis des ajouts simples.
        state.policyLog.append(state.policyLog[0])
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 1)
        XCTAssertEqual(try SQLiteStore(url: url).load(), state)
    }

    func testAnInstanceThatNeverLoadedStillSavesIncrementally() throws {
        var state = try richState()
        try SQLiteStore(url: url).save(state)
        // Une nouvelle instance enregistre sans avoir lu : elle lit d'abord la base.
        let store = try SQLiteStore(url: url)
        state.devices[0].note = "salon"
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 1)
        XCTAssertEqual(try SQLiteStore(url: url).load(), state)
    }

    func testAFailedSaveLeavesTheDatabaseUntouched() throws {
        var state = try richState()
        let store = try SQLiteStore(url: url)
        try store.save(state)

        // Une table disparaît derrière le dos du stockage : l'enregistrement échoue en route.
        let database = try SQLiteDatabase(path: url.path)
        try database.execute("DROP TABLE devices")
        state.profiles[0].name = "Éco"
        state.devices[0].name = "Portable"
        XCTAssertThrowsError(try store.save(state)) { error in
            guard case .store(let detail) = error as? FluxaError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("no such table"), detail)
        }
        // Les profils sont écrits avant les appareils : la transaction a tout annulé.
        XCTAssertEqual(
            try database.rows("SELECT name FROM bandwidth_profiles WHERE id = 'economy'") { $0.text(0) },
            ["Économie"])
    }

    // MARK: Effacement

    func testEraseEmptiesEveryTableAndTheStoreStaysUsable() throws {
        let state = try richState()
        let store = try SQLiteStore(url: url)
        try store.save(state)
        try store.erase()
        XCTAssertNil(try store.load())
        XCTAssertNil(try SQLiteStore(url: url).load())
        let database = try SQLiteDatabase(path: url.path)
        for table in SQLiteStore.tables {
            XCTAssertEqual(try database.integer("SELECT COUNT(*) FROM \(table)"), 0, table)
        }
        XCTAssertNoThrow(try store.erase(), "effacer deux fois ne gêne pas")

        try store.save(state)
        XCTAssertEqual(try SQLiteStore(url: url).load(), state)
    }

    // MARK: Refus

    func testANewerSchemaIsRefusedWithoutTouchingTheFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let database = try SQLiteDatabase(path: url.path)
            try database.execute("CREATE TABLE futur (x INTEGER); PRAGMA user_version = 99")
        }
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try SQLiteStore(url: url)) { error in
            guard case .store(let detail) = error as? FluxaError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("version plus récente"), detail)
            XCTAssertTrue(detail.contains("99"), detail)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        let database = try SQLiteDatabase(path: url.path)
        XCTAssertEqual(try database.integer("PRAGMA user_version"), 99)
        XCTAssertEqual(
            try database.rows("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) }, ["futur"])
    }

    func testAFileThatIsNotADatabaseIsRefusedClearly() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data(String(repeating: "ceci n'est pas une base SQLite\n", count: 200).utf8)
        try garbage.write(to: url)

        XCTAssertThrowsError(try SQLiteStore(url: url)) { error in
            guard case .store(let detail) = error as? FluxaError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("base illisible (fluxa.sqlite)"), detail)
            XCTAssertTrue(detail.contains("not a database"), detail)
        }
        XCTAssertEqual(try Data(contentsOf: url), garbage, "le fichier est laissé tel quel")
    }

    func testAnUnreadableRowIsReportedAndNothingIsOverwritten() throws {
        let state = try richState()
        try SQLiteStore(url: url).save(state)
        let database = try SQLiteDatabase(path: url.path)
        try database.execute("UPDATE policy_applications SET result_json = '{' WHERE seq = 1")

        let store = try SQLiteStore(url: url)
        XCTAssertThrows(try store.load(), .store("ligne illisible dans la table policy_applications."))
        // Le moteur démarre à vide et le dit ; ses enregistrements échouent sans rien écraser.
        let engine = FluxaEngine(store: store, calendar: calendar(), now: { noon })
        XCTAssertEqual(engine.diagnostics().events.first?.level, .error)
        XCTAssertThrowsError(try engine.flush())
        XCTAssertEqual(try database.integer("SELECT COUNT(*) FROM usage_records"), 11)
    }

    // MARK: Reprise de l'ancien fichier

    func testImportsALegacyFileOnce() throws {
        let state = try richState()
        let legacy = directory.appendingPathComponent("fluxa.json")
        try FileStore(url: legacy).save(state)

        let store = try SQLiteStore(url: url)
        XCTAssertTrue(try store.importLegacyFile(at: legacy))
        XCTAssertEqual(try store.load(), state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "l'ancien fichier est supprimé")
        XCTAssertFalse(try store.importLegacyFile(at: legacy), "plus rien à reprendre")
        XCTAssertEqual(try SQLiteStore(url: url).load(), state)
    }

    func testDoesNotImportOverExistingData() throws {
        let state = try richState()
        let legacy = directory.appendingPathComponent("fluxa.json")
        let store = try SQLiteStore(url: url)
        try store.save(EngineState())
        try FileStore(url: legacy).save(state)

        XCTAssertFalse(try store.importLegacyFile(at: legacy))
        XCTAssertEqual(try store.load(), EngineState(), "la base garde ce qu'elle avait")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "le fichier n'est pas supprimé")

        // Une nouvelle instance, qui n'a encore rien lu, ne reprend pas non plus.
        XCTAssertFalse(try SQLiteStore(url: url).importLegacyFile(at: legacy))
    }

    func testAMissingLegacyFileIsNotAnError() throws {
        let store = try SQLiteStore(url: url)
        XCTAssertFalse(try store.importLegacyFile(at: directory.appendingPathComponent("absent.json")))
        XCTAssertNil(try store.load())
    }

    func testAnUnreadableLegacyFileIsLeftInPlace() throws {
        let store = try SQLiteStore(url: url)
        let legacy = directory.appendingPathComponent("fluxa.json")
        let garbage = Data("{ ceci n'est pas du JSON".utf8)
        try garbage.write(to: legacy)

        XCTAssertThrows(try store.importLegacyFile(at: legacy), .store("fichier illisible (fluxa.json)."))
        XCTAssertEqual(try Data(contentsOf: legacy), garbage)
        XCTAssertNil(try store.load(), "la base reste vide")
    }

    // MARK: Avec le moteur

    func testTheEngineKeepsItsHistoryInTheDatabase() throws {
        let clock = TestClock()
        var received: UInt64 = 0
        do {
            let bench = Bench(store: try SQLiteStore(url: url), clock: clock).started()
            bench.measure(seconds: 150, down: 20, up: 4)  // deux fins de minute : deux enregistrements
            try bench.engine.activateProfile(id: "streaming")
            try bench.engine.saveDevice(Device(name: "MacBook", kind: .computer, profileID: "streaming"))
            try bench.engine.saveRule(
                AutomationRule(
                    name: "Nuit", trigger: .schedule(startMinute: 1_320, endMinute: 420, weekdays: []),
                    action: .activateProfile(id: "economy")))
            bench.engine.stop()
            received = bench.engine.snapshot.receivedBytesToday
            XCTAssertEqual(received, 150 * 2_500_000)
            XCTAssertEqual(bench.engine.diagnostics().storeLocation, url.path)
        }

        // L'app est fermée, puis rouverte le soir.
        clock.advance(10 * hour + 30 * minute)
        let engine = FluxaEngine(store: try SQLiteStore(url: url), calendar: calendar(), now: { clock.date })
        XCTAssertEqual(engine.diagnostics().events.map(\.level), [.info], "aucune erreur de lecture")
        XCTAssertEqual(engine.snapshot.receivedBytesToday, received)
        let minutes = engine.history(from: noon, to: noon.addingTimeInterval(hour), step: .minute)
        XCTAssertEqual(minutes.map(\.sampleCount), [59, 60, 31])
        XCTAssertEqual(minutes.first?.averageDownloadBps, 20_000_000)
        XCTAssertEqual(engine.history(from: .distantPast, to: .distantFuture, step: .day).first?.sampleCount, 150)
        XCTAssertEqual(engine.activeProfileID, "streaming")
        XCTAssertEqual(engine.lastApplyResult?.status, .simulated)
        XCTAssertEqual(engine.devices.map(\.name), ["MacBook"])
        XCTAssertEqual(
            engine.evaluateAutomations().map(\.message), ["Plage 22:00–07:00 commencée : profil Économie choisi."])

        // Effacer tout vide la base ; elle reste utilisable.
        try engine.eraseAll()
        XCTAssertNil(try SQLiteStore(url: url).load())
        try engine.saveDevice(Device(name: "Neuf"))
        XCTAssertEqual(try SQLiteStore(url: url).load()?.devices.map(\.id), ["device-1"])
    }

    func testTheEngineWritesOnlyAFewRowsPerMinute() throws {
        let store = try SQLiteStore(url: url)
        let bench = Bench(store: store).started()
        bench.measure(seconds: 60, down: 20, up: 4)
        let first = store.lastSaveChanges
        bench.measure(seconds: 60, down: 20, up: 4)
        // La minute terminée, l'heure et le jour : trois agrégats, quel que soit l'historique.
        XCTAssertEqual(store.lastSaveChanges, 3)
        XCTAssertGreaterThan(first, 3, "le premier enregistrement écrit aussi les préréglages et les réglages")
    }
}

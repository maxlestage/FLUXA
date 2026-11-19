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
                "absences", "app_settings", "automation_events", "bandwidth_profiles", "devices",
                "network_usage", "policy_applications", "rule_activations", "scheduled_rules",
                "sharing_sessions", "speed_tests", "usage_records",
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

    // MARK: Forfait, volume par réseau, rattrapage et partage (schéma 2)

    /// Un état qui porte tout ce que la version 2 ajoute, produit par le moteur : forfait
    /// recalé, volume par réseau sur deux heures, deux absences, une session de partage
    /// terminée et une en cours, point de reprise.
    private func planState() throws -> EngineState {
        let memory = MemoryStore()
        let clock = TestClock(noon.addingTimeInterval(0.25))
        let boot = noon.addingTimeInterval(-3 * day)
        let engine = FluxaEngine(store: memory, counterWidth: .bits64, calendar: calendar(), now: { clock.date })
        var mobile: UInt64 = 0
        var bridged: UInt64?
        let read = {
            var readings = [cellular(mobile, mobile / 8), wifi(mobile / 2, 7)]
            if let bridged {
                readings.append(
                    InterfaceReading(name: "bridge100", kind: .sharing, receivedBytes: bridged / 9, sentBytes: bridged))
            }
            engine.ingest(readings, bootTime: boot)
        }
        let pause = { (seconds: TimeInterval, grown: UInt64) in
            engine.stop()
            clock.advance(seconds)
            mobile += grown
            engine.start()
            read()
        }

        engine.updatePath(kind: .cellular, isOnline: true)
        engine.start()
        read()
        for second in 0..<20 {
            clock.advance(1)
            mobile += 1_000_000
            bridged = second < 5 ? nil : (second < 12 ? UInt64(second) * 40_000 : nil)
            read()
        }
        pause(hour, 800_000_000)
        engine.updatePath(kind: .wifi, isOnline: true)
        bridged = 0
        for _ in 0..<10 {
            clock.advance(1)
            mobile += 2_000_000
            bridged = (bridged ?? 0) + 123_457
            read()
        }
        pause(20 * minute, 5_000_000_000)

        try engine.setDataPlan(DataPlan(allowanceBytes: 100_000_000_000, resetDay: 31))
        try engine.calibratePlan(usedBytes: 12_345_678_901)
        try engine.saveRule(AutomationRule(name: "Forfait", trigger: .planUsage(percent: 80), action: .alert))
        try engine.flush()

        let state = try XCTUnwrap(try memory.load())
        XCTAssertEqual(state.networkHours.count, 2, "le mobile à midi, le Wi-Fi à 13 h")
        XCTAssertEqual(state.networkDays.count, 2)
        XCTAssertEqual(state.absences.count, 2)
        XCTAssertEqual(state.sharingSessions.count, 1)
        XCTAssertEqual(state.currentSharing?.isLowerBound, true, "le partage a continué pendant la pause")
        XCTAssertNotNil(state.checkpoint)
        XCTAssertNotNil(state.planCalibration)
        return state
    }

    func testThePlanStateRoundTripsExactly() throws {
        let state = try planState()
        let store = try SQLiteStore(url: url)
        try store.save(state)
        XCTAssertEqual(try store.load(), state)

        let reopened = try SQLiteStore(url: url)
        let loaded = try XCTUnwrap(try reopened.load())
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.dataPlan, DataPlan(allowanceBytes: 100_000_000_000, resetDay: 31))
        XCTAssertEqual(loaded.planCalibration?.usedBytes, 12_345_678_901)
        XCTAssertEqual(loaded.checkpoint?.counters.map(\.name), ["pdp_ip0", "en0", "bridge100"])
        XCTAssertEqual(loaded.rules.map(\.trigger), [.planUsage(percent: 80)])
        try reopened.save(loaded)
        XCTAssertEqual(reopened.lastSaveChanges, 0, "lire puis enregistrer n'écrit rien")

        // Le moteur relu donne les mêmes réponses.
        let clock = TestClock(noon.addingTimeInterval(2 * hour))
        let engine = FluxaEngine(store: reopened, calendar: calendar(), now: { clock.date })
        XCTAssertEqual(engine.diagnostics().events.map(\.level), [.info], "aucune erreur de lecture")
        XCTAssertEqual(engine.planStatus()?.calibratedBytes, 12_345_678_901)
        XCTAssertEqual(engine.absences(limit: 5).map(\.id), [2, 1])
        XCTAssertEqual(engine.sharingSessions(limit: 5).map(\.id), [1])
        XCTAssertEqual(
            engine.usageByNetwork(from: noon.addingTimeInterval(-hour), to: .distantFuture).map(\.kind),
            [.cellular, .wifi])
    }

    func testThePlanStateHasTypedColumns() throws {
        let state = try planState()
        try SQLiteStore(url: url).save(state)
        let database = try SQLiteDatabase(path: url.path)

        XCTAssertEqual(
            try database.rows("SELECT step, network, received_bytes FROM network_usage ORDER BY step, start, network") {
                "\($0.text(0)) \($0.text(1)) \($0.int(2))"
            },
            ["day cellular 20000000", "day wifi 10000000", "hour cellular 20000000", "hour wifi 10000000"])
        // Les volumes se somment en SQL : ce sont de vrais entiers.
        XCTAssertEqual(
            try database.integer("SELECT SUM(received_bytes + sent_bytes) FROM network_usage WHERE step = 'day'"),
            32_500_000)
        XCTAssertEqual(
            try database.rows("SELECT id, ended_at - started_at, volumes_json FROM absences ORDER BY id") {
                "\($0.int(0)) \($0.int(1)) \($0.text(2))"
            },
            [
                #"1 3600 [{"kind":"wifi","receivedBytes":400000000,"sentBytes":0},{"kind":"cellular","receivedBytes":800000000,"sentBytes":100000000}]"#,
                #"2 1200 [{"kind":"wifi","receivedBytes":2500000000,"sentBytes":0},{"kind":"cellular","receivedBytes":5000000000,"sentBytes":625000000}]"#,
            ])
        XCTAssertEqual(
            try database.rows(
                "SELECT id, to_devices_bytes, from_devices_bytes, is_lower_bound, ended_at - started_at FROM sharing_sessions"
            ) { "\($0.int(0)) \($0.int(1)) \($0.int(2)) \($0.int(3)) \($0.int(4))" },
            ["1 240000 26666 0 6"])
        XCTAssertEqual(
            try database.rows(
                "SELECT key FROM app_settings WHERE key IN ('data_plan', 'plan_calibration', 'counter_checkpoint', 'current_sharing_session', 'next_absence_id', 'next_sharing_session_id') ORDER BY key"
            ) { $0.text(0) },
            [
                "counter_checkpoint", "current_sharing_session", "data_plan", "next_absence_id",
                "next_sharing_session_id", "plan_calibration",
            ])
        XCTAssertEqual(
            try database.rows("SELECT value FROM app_settings WHERE key = 'data_plan'") { $0.text(0) },
            [#"{"allowanceBytes":100000000000,"resetDay":31}"#])
    }

    func testOnlyTheChangedPlanRowsAreWritten() throws {
        var state = try planState()
        let store = try SQLiteStore(url: url)
        try store.save(state)

        // Un forfait retiré : son réglage et son recalage partent, rien d'autre.
        state.dataPlan = nil
        state.planCalibration = nil
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 2)

        // Deux absences fondues en une : une ligne supprimée, une réécrite.
        state.absences = [
            AbsenceUsage(
                id: 1, start: state.absences[0].start, end: state.absences[1].end,
                volumes: [NetworkVolume(kind: .cellular, receivedBytes: 1, sentBytes: 2)])
        ]
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 2)

        // Une session qui se termine : sa ligne, et le réglage de la session en cours.
        state.sharingSessions.append(try XCTUnwrap(state.currentSharing))
        state.currentSharing = nil
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 2)

        // Un volume de plus sur une heure et un jour.
        state.networkHours.add(kind: .wired, receivedBytes: 5, sentBytes: 5, at: noon)
        state.networkDays.add(kind: .cellular, receivedBytes: 5, sentBytes: 5, at: noon.addingTimeInterval(-12 * hour))
        try store.save(state)
        XCTAssertEqual(store.lastSaveChanges, 2)
        XCTAssertEqual(try SQLiteStore(url: url).load(), state)
    }

    func testAVersionOneDatabaseIsMigratedWithItsData() throws {
        // Une base telle que la version précédente l'a créée et remplie.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let database = try SQLiteDatabase(path: url.path)
            try database.execute(SQLiteStore.schemaV1)
            try database.execute(
                """
                PRAGMA user_version = 1;
                INSERT INTO app_settings (key, value) VALUES
                    ('state_version', '1'), ('next_profile_number', '2'), ('next_rule_number', '1'),
                    ('next_automation_event_id', '1'), ('next_device_number', '2'),
                    ('active_profile_id', 'custom-1');
                INSERT INTO bandwidth_profiles (id, position, name, download_bps, upload_bps, is_builtin)
                    VALUES ('custom-1', 0, 'Visio', 8000000, NULL, 0);
                INSERT INTO usage_records (step, start, measured_seconds, received_bytes, sent_bytes,
                    peak_download_bps, peak_upload_bps, sample_count)
                    VALUES ('day', \(noon.timeIntervalSinceReferenceDate - 43_200), 60, 150000000, 30000000, 2e7, 4e6, 60);
                INSERT INTO devices (id, position, name, kind, profile_id, note, added_at)
                    VALUES ('device-1', 0, 'MacBook', 'computer', 'custom-1', '', 0);
                """)
        }

        let store = try SQLiteStore(url: url)
        let database = try SQLiteDatabase(path: url.path)
        XCTAssertEqual(try database.integer("PRAGMA user_version"), 2)
        let tables = try database.rows("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) }
        XCTAssertEqual(Set(tables), Set(SQLiteStore.tables))

        // Les données d'avant sont là ; ce que la version 2 ajoute est vide.
        var state = try XCTUnwrap(try store.load())
        XCTAssertEqual(state.profiles.map(\.name), ["Visio"])
        XCTAssertEqual(state.activeProfileID, "custom-1")
        XCTAssertEqual(state.days.buckets.map(\.receivedBytes), [150_000_000])
        XCTAssertEqual(state.devices.map(\.name), ["MacBook"])
        XCTAssertEqual(state.nextDeviceNumber, 2)
        XCTAssertEqual(state.version, EngineState.currentVersion)
        XCTAssertNil(state.dataPlan)
        XCTAssertNil(state.checkpoint)
        XCTAssertNil(state.currentSharing)
        XCTAssertEqual(state.networkDays, NetworkSeries())
        XCTAssertTrue(state.absences.isEmpty)
        XCTAssertTrue(state.sharingSessions.isEmpty)
        XCTAssertEqual(state.nextAbsenceID, 1)

        // Le moteur s'en sert, et la base migrée garde le nouvel état.
        let clock = TestClock()
        let engine = FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
        XCTAssertEqual(engine.diagnostics().events.map(\.level), [.info])
        XCTAssertEqual(engine.snapshot.receivedBytesToday, 0, "pas de minutes : le jour ne se relit pas en direct")
        try engine.setDataPlan(DataPlan(allowanceBytes: 5_000_000_000, resetDay: 12))
        state = try XCTUnwrap(try SQLiteStore(url: url).load())
        XCTAssertEqual(state.dataPlan, DataPlan(allowanceBytes: 5_000_000_000, resetDay: 12))
        XCTAssertEqual(state.profiles.count, 8, "les préréglages et le profil créé")

        // Rouvrir ne migre pas deux fois.
        XCTAssertEqual(try SQLiteStore(url: url).load(), state)
    }

    func testALegacyFileWithoutThePlanFieldsIsImported() throws {
        // L'ancien fichier JSON, d'avant le forfait et le volume par réseau.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("fluxa.json")
        try Data(
            #"""
            {"version":1,"activeProfileID":"standard","nextProfileNumber":2,"policyLog":[],
             "profiles":[{"id":"custom-1","name":"Visio","downloadBps":8000000,"isBuiltin":false}],
             "minutes":[],"hours":[],"days":[[794059200,60,150000000,30000000,2e7,4e6,60]],
             "rules":[],"devices":[],"speedTests":[]}
            """#.utf8
        ).write(to: legacy)

        let store = try SQLiteStore(url: url)
        XCTAssertTrue(try store.importLegacyFile(at: legacy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let state = try XCTUnwrap(try SQLiteStore(url: url).load())
        XCTAssertEqual(state.profiles.map(\.id), ["custom-1"])
        XCTAssertEqual(state.activeProfileID, "standard")
        XCTAssertEqual(state.days.buckets.map(\.sentBytes), [30_000_000])
        XCTAssertEqual(state.version, EngineState.currentVersion)
        XCTAssertNil(state.dataPlan)
        XCTAssertNil(state.checkpoint)
        XCTAssertTrue(state.absences.isEmpty)
        XCTAssertEqual(state.networkHours, NetworkSeries())

        // Et un état d'aujourd'hui passe aussi par le fichier JSON de secours.
        let rich = try planState()
        let file = FileStore(url: directory.appendingPathComponent("fluxa-secours.json"))
        try file.save(rich)
        XCTAssertEqual(try file.load(), rich)
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
        // La minute terminée, l'heure et le jour : trois agrégats, plus le volume du réseau
        // pour l'heure et pour le jour, quel que soit l'historique.
        XCTAssertEqual(store.lastSaveChanges, 5)
        XCTAssertGreaterThan(first, 3, "le premier enregistrement écrit aussi les préréglages et les réglages")
    }

    func testTheCheckpointCostsOneRowPerMinute() throws {
        let store = try SQLiteStore(url: url)
        let clock = TestClock()
        let engine = FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
        let boot = noon.addingTimeInterval(-day)
        engine.updatePath(kind: .cellular, isOnline: true)
        engine.start()
        for second in 0...120 {
            engine.ingest([cellular(UInt64(second) * 1_000, 0)], bootTime: boot)
            clock.advance(1)
        }
        // Les cinq lignes de la minute, et le réglage du point de reprise.
        XCTAssertEqual(store.lastSaveChanges, 6)
    }
}

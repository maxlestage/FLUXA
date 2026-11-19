import XCTest

@testable import FluxaCore

final class DeviceTests: XCTestCase {
    // MARK: Registre

    func testADeviceIsAddedEditedAndRemoved() throws {
        let bench = Bench()
        XCTAssertTrue(bench.engine.devices.isEmpty)

        let mac = try bench.engine.saveDevice(
            Device(name: "  MacBook \n", kind: .computer, profileID: "standard", note: " bureau "))
        XCTAssertEqual(mac.id, "device-1")
        XCTAssertEqual(mac.name, "MacBook", "le nom est nettoyé")
        XCTAssertEqual(mac.note, "bureau")
        XCTAssertEqual(mac.kind, .computer)
        XCTAssertEqual(mac.profileID, "standard")
        XCTAssertEqual(mac.addedAt, noon)

        bench.clock.advance(hour)
        let tablet = try bench.engine.saveDevice(Device(name: "Tablette", kind: .tablet))
        XCTAssertEqual(tablet.id, "device-2")
        XCTAssertNil(tablet.profileID)
        XCTAssertEqual(tablet.note, "")
        XCTAssertEqual(tablet.addedAt, noon.addingTimeInterval(hour))
        XCTAssertEqual(bench.engine.devices, [mac, tablet], "dans l'ordre de leur ajout")

        // Une modification garde la place et la date d'ajout.
        bench.clock.advance(hour)
        var edited = mac
        edited.name = "MacBook Pro"
        edited.kind = .other
        edited.profileID = nil
        edited.addedAt = .distantFuture
        let saved = try bench.engine.saveDevice(edited)
        XCTAssertEqual(saved.name, "MacBook Pro")
        XCTAssertEqual(saved.addedAt, noon, "quoi que contienne l'appareil reçu")
        XCTAssertEqual(bench.engine.devices.map(\.id), ["device-1", "device-2"])
        XCTAssertEqual(bench.engine.devices.first, saved)

        try bench.engine.deleteDevice(id: "device-1")
        XCTAssertEqual(bench.engine.devices, [tablet])
        // Un identifiant supprimé n'est pas réutilisé.
        XCTAssertEqual(try bench.engine.saveDevice(Device(name: "Console", kind: .console)).id, "device-3")
    }

    func testTheDateOfAdditionComesFromTheEngineClock() throws {
        let bench = Bench()
        let device = try bench.engine.saveDevice(Device(name: "Télé", kind: .television, addedAt: .distantPast))
        XCTAssertEqual(device.addedAt, noon)
        XCTAssertEqual(Device(name: "Télé").addedAt, Date(timeIntervalSince1970: 0), "valeur par défaut du type")
    }

    func testRefusesInvalidDevices() throws {
        let engine = Bench().engine
        XCTAssertThrows(
            try engine.saveDevice(Device(name: " \n ")), .invalidDevice("Donnez un nom à l’appareil."))
        XCTAssertThrows(
            try engine.saveDevice(Device(name: "Téléphone", kind: .phone, profileID: "absent")),
            .unknownProfile(id: "absent"))
        XCTAssertThrows(
            try engine.saveDevice(Device(id: "device-7", name: "Fantôme")),
            .invalidDevice("Cet appareil n’existe plus."))
        XCTAssertThrows(try engine.deleteDevice(id: "device-7"), .invalidDevice("Cet appareil n’existe plus."))
        XCTAssertTrue(engine.devices.isEmpty, "rien n'a été créé")
        XCTAssertEqual(
            FluxaError.invalidDevice("Donnez un nom à l’appareil.").localizedDescription,
            "Donnez un nom à l’appareil.")

        // Un refus ne consomme pas d'identifiant, et une modification est vérifiée aussi.
        var phone = try engine.saveDevice(Device(name: "Téléphone", kind: .phone))
        XCTAssertEqual(phone.id, "device-1")
        phone.name = ""
        XCTAssertThrowsError(try engine.saveDevice(phone))
        phone.name = "Téléphone"
        phone.profileID = "absent"
        XCTAssertThrowsError(try engine.saveDevice(phone))
        XCTAssertEqual(engine.devices.first?.name, "Téléphone")
        XCTAssertNil(engine.devices.first?.profileID)
    }

    func testDeletingAProfileDetachesItFromDevices() throws {
        let engine = Bench().engine
        let visio = try engine.saveProfile(id: nil, name: "Visio", downloadMbps: 8, uploadMbps: 4)
        try engine.saveDevice(Device(name: "MacBook", kind: .computer, profileID: visio.id))
        try engine.saveDevice(Device(name: "Tablette", kind: .tablet, profileID: "standard"))
        try engine.saveDevice(Device(name: "Console", kind: .console, profileID: visio.id))
        try engine.saveRule(
            AutomationRule(
                name: "Soir", trigger: .schedule(startMinute: 780, endMinute: 840, weekdays: []),
                action: .activateProfile(id: visio.id)))

        try engine.deleteProfile(id: visio.id)
        XCTAssertEqual(engine.devices.map(\.profileID), [nil, "standard", nil])
        XCTAssertEqual(engine.devices.map(\.name), ["MacBook", "Tablette", "Console"], "les appareils restent")
        // La règle garde sa référence : elle le signalera à son déclenchement.
        XCTAssertEqual(engine.automationRules.first?.action, .activateProfile(id: visio.id))
        XCTAssertEqual(engine.profileUsage(id: visio.id).ruleNames, ["Soir"])
        XCTAssertTrue(engine.profileUsage(id: visio.id).deviceNames.isEmpty)
    }

    func testTheLimitStatusOfADeviceHasNoSideEffect() throws {
        let bench = Bench()
        let device = try bench.engine.saveDevice(Device(name: "MacBook", kind: .computer, profileID: "streaming"))
        bench.clock.advance(60)
        let status = try XCTUnwrap(bench.engine.limitStatus(for: device))
        XCTAssertEqual(status.status, .unsupported)
        XCTAssertNil(status.effective, "rien n'est appliqué")
        XCTAssertEqual(status.requested, BandwidthPolicy(downloadBps: 25_000_000, uploadBps: 10_000_000))
        XCTAssertEqual(status.capability, .perDeviceShaping)
        XCTAssertEqual(status.date, bench.clock.date)
        XCTAssertTrue(status.reason?.contains("iOS") ?? false)

        XCTAssertNil(bench.engine.lastApplyResult)
        XCTAssertTrue(bench.engine.policyLog(limit: 10).isEmpty)
        XCTAssertNil(bench.engine.activeProfileID)

        // La même réponse qu'une vraie demande pour un appareil, journal en moins.
        let asked = try bench.engine.applyToDevice(status.requested)
        XCTAssertEqual(asked.status, status.status)
        XCTAssertEqual(asked.reason, status.reason)
        XCTAssertEqual(asked.capability, status.capability)

        // Sans profil, ou avec un profil qui n'existe plus : pas de réponse.
        XCTAssertNil(bench.engine.limitStatus(for: Device(name: "Sans profil")))
        XCTAssertNil(bench.engine.limitStatus(for: Device(name: "Fantôme", profileID: "absent")))
        // Un préréglage sans plafond a quand même un statut.
        XCTAssertEqual(
            bench.engine.limitStatus(for: Device(name: "Libre", profileID: "maximum"))?.requested,
            BandwidthPolicy())
    }

    func testProfileUsageListsRulesAndDevices() throws {
        let engine = Bench().engine
        XCTAssertTrue(engine.profileUsage(id: "economy").isEmpty)
        let schedule = AutomationRule.Trigger.schedule(startMinute: 0, endMinute: 60, weekdays: [])
        try engine.saveRule(AutomationRule(name: "Nuit", trigger: schedule, action: .activateProfile(id: "economy")))
        try engine.saveRule(AutomationRule(name: "Alerte", trigger: schedule, action: .alert))
        try engine.saveRule(
            AutomationRule(name: "Travail", trigger: schedule, action: .activateProfile(id: "standard")))
        try engine.saveRule(
            AutomationRule(
                name: "Forfait", isEnabled: false, trigger: .dailyUsage(bytes: 5),
                action: .activateProfile(id: "economy")))
        try engine.saveDevice(Device(name: "Tablette", profileID: "economy"))
        try engine.saveDevice(Device(name: "MacBook", profileID: "standard"))
        try engine.saveDevice(Device(name: "Console", profileID: "economy"))
        try engine.saveDevice(Device(name: "Télé"))

        let economy = engine.profileUsage(id: "economy")
        XCTAssertEqual(economy.ruleNames, ["Nuit", "Forfait"], "activées ou non, dans l'ordre de création")
        XCTAssertEqual(economy.deviceNames, ["Tablette", "Console"])
        XCTAssertFalse(economy.isEmpty)
        XCTAssertEqual(
            engine.profileUsage(id: "standard"), ProfileUsage(ruleNames: ["Travail"], deviceNames: ["MacBook"]))
        XCTAssertTrue(engine.profileUsage(id: "streaming").isEmpty)
        XCTAssertTrue(engine.profileUsage(id: "absent").isEmpty)
    }

    // MARK: Comparaison

    /// Mesure `first` secondes entre 11 h et 12 h, puis `second` secondes après 12 h.
    private func twoHours(first: Int, second: Int, firstRate: Double = 20, secondRate: Double = 20) -> Bench {
        let bench = Bench(clock: TestClock(noon.addingTimeInterval(-hour))).started()
        if first > 0 {
            bench.measure(seconds: first, down: firstRate, up: firstRate / 5)
        }
        bench.clock.date = noon.addingTimeInterval(10)
        bench.rebase()
        if second > 0 {
            bench.measure(seconds: second, down: secondRate, up: secondRate / 5)
        }
        return bench
    }

    func testComparesAPeriodWithTheOneBefore() {
        let end = noon.addingTimeInterval(hour)

        let rise = twoHours(first: 60, second: 90).engine.compareUsage(from: noon, to: end)
        XCTAssertEqual(rise.current.receivedBytes, 90 * 2_500_000)
        XCTAssertEqual(rise.previous.receivedBytes, 60 * 2_500_000)
        XCTAssertEqual(rise.previous.sentBytes, 60 * 500_000)
        XCTAssertEqual(rise.changePercent ?? 0, 50, accuracy: 1e-9)

        let fall = twoHours(first: 100, second: 25).engine.compareUsage(from: noon, to: end)
        XCTAssertEqual(fall.changePercent ?? 0, -75, accuracy: 1e-9)

        // Le total compte le reçu et l'envoyé : ici le débit double, le volume aussi.
        let doubled = twoHours(first: 60, second: 60, secondRate: 40).engine.compareUsage(from: noon, to: end)
        XCTAssertEqual(doubled.changePercent ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(doubled.current.peakDownloadBps, 40_000_000)
        XCTAssertEqual(doubled.previous.averageDownloadBps, 20_000_000)

        let stopped = twoHours(first: 60, second: 0).engine.compareUsage(from: noon, to: end)
        XCTAssertEqual(stopped.changePercent, -100)
        XCTAssertEqual(stopped.current, UsageSummary())
    }

    func testNothingToCompareWithoutPreviousMeasures() {
        let end = noon.addingTimeInterval(hour)
        let bench = twoHours(first: 0, second: 30)
        let comparison = bench.engine.compareUsage(from: noon, to: end)
        XCTAssertEqual(comparison.current.receivedBytes, 30 * 2_500_000)
        XCTAssertEqual(comparison.previous, UsageSummary())
        XCTAssertNil(comparison.changePercent, "rien à comparer")

        let empty = Bench().engine.compareUsage(from: noon, to: end)
        XCTAssertEqual(empty, UsageComparison(current: UsageSummary(), previous: UsageSummary(), changePercent: nil))
    }

    func testZeroBytesMeasuredIsNotTheSameAsNothingMeasured() {
        let end = noon.addingTimeInterval(hour)
        // Mesuré avant, mais sans trafic ; du trafic ensuite : pas de pourcentage.
        let fromZero = twoHours(first: 30, second: 30, firstRate: 0).engine.compareUsage(from: noon, to: end)
        XCTAssertEqual(fromZero.previous.receivedBytes, 0)
        XCTAssertEqual(fromZero.previous.averageDownloadBps, 0, "mesuré : la moyenne existe et vaut zéro")
        XCTAssertNil(fromZero.changePercent)
        // Sans trafic avant comme après : aucune variation.
        let still = twoHours(first: 30, second: 30, firstRate: 0, secondRate: 0)
            .engine.compareUsage(from: noon, to: end)
        XCTAssertEqual(still.changePercent, 0)
    }

    func testInvertedOrEmptyBoundsCompareNothing() {
        let bench = twoHours(first: 60, second: 60)
        let empty = UsageComparison(current: UsageSummary(), previous: UsageSummary(), changePercent: nil)
        XCTAssertEqual(bench.engine.compareUsage(from: noon.addingTimeInterval(hour), to: noon), empty)
        XCTAssertEqual(bench.engine.compareUsage(from: noon, to: noon), empty)
    }

    // MARK: Export

    private let header =
        "debut;debit_descendant_moyen_bps;debit_montant_moyen_bps;pic_descendant_bps;pic_montant_bps;octets_recus;octets_envoyes;mesures"

    func testAnEmptyExportHasOnlyTheHeaderLine() {
        let engine = Bench().engine
        for step in HistoryStep.allCases {
            XCTAssertEqual(engine.exportCSV(from: .distantPast, to: .distantFuture, step: step), header + "\n")
        }
        XCTAssertEqual(header.split(separator: ";").count, 8)
    }

    func testExportsOneLinePerAggregateOldestFirst() {
        let bench = Bench().started()
        bench.measure(seconds: 90, down: 20, up: 4)
        bench.clock.advance(hour)
        bench.rebase()
        bench.measure(seconds: 30, down: 40, up: 8)

        let minutes = bench.engine.exportCSV(from: noon, to: noon.addingTimeInterval(day), step: .minute)
        XCTAssertEqual(
            minutes,
            """
            \(header)
            2026-03-01T12:00:00Z;20000000;4000000;20000000;4000000;147500000;29500000;59
            2026-03-01T12:01:00Z;20000000;4000000;20000000;4000000;77500000;15500000;31
            2026-03-01T13:01:00Z;40000000;8000000;40000000;8000000;145000000;29000000;29
            2026-03-01T13:02:00Z;40000000;8000000;40000000;8000000;5000000;1000000;1

            """)
        XCTAssertTrue(minutes.hasSuffix("\n"), "chaque ligne se termine par un saut de ligne")
        XCTAssertFalse(minutes.contains("\r"))

        let hours = bench.engine.exportCSV(from: noon, to: noon.addingTimeInterval(day), step: .hour)
        XCTAssertEqual(
            hours.split(separator: "\n").dropFirst().map(String.init),
            [
                "2026-03-01T12:00:00Z;20000000;4000000;20000000;4000000;225000000;45000000;90",
                "2026-03-01T13:00:00Z;40000000;8000000;40000000;8000000;150000000;30000000;30",
            ])
        let days = bench.engine.exportCSV(from: .distantPast, to: .distantFuture, step: .day)
        XCTAssertEqual(
            days, header + "\n2026-03-01T00:00:00Z;25000000;5000000;40000000;8000000;375000000;75000000;120\n")

        // Les mêmes bornes que l'historique : début inclus, fin exclue.
        let second = bench.engine.exportCSV(
            from: noon.addingTimeInterval(60), to: noon.addingTimeInterval(120), step: .minute)
        XCTAssertEqual(second.split(separator: "\n").count, 2)
        XCTAssertEqual(
            bench.engine.exportCSV(from: noon.addingTimeInterval(hour), to: noon, step: .minute), header + "\n")
    }

    func testExportedRatesAreRoundedIntegers() {
        // 1 octet en 3 s : 2,67 bit/s. 1 000 001 octets en 3 s : 2 666 669,33 bit/s.
        let bench = Bench(counterWidth: .bits64)
        bench.engine.updatePath(kind: .wifi, isOnline: true)
        bench.engine.start()
        bench.engine.ingest([wifi(0, 0)])
        bench.clock.advance(3)
        bench.engine.ingest([wifi(1, 1_000_001)])
        let csv = bench.engine.exportCSV(from: noon, to: noon.addingTimeInterval(hour), step: .minute)
        XCTAssertEqual(csv, header + "\n2026-03-01T12:00:00Z;3;2666669;3;2666669;1;1000001;1\n")
        let data = csv.split(separator: "\n").dropFirst().joined()
        XCTAssertFalse(data.contains("."), "pas de point décimal")
        XCTAssertFalse(data.contains(","))
        XCTAssertFalse(data.lowercased().contains("e"), "pas d'exposant")
    }

    func testExportedDatesAreInUTCWhateverTheCalendar() {
        // À UTC+5:30, l'heure locale de 12 h UTC commence à 11 h 30 UTC, et la journée
        // locale à 18 h 30 UTC la veille.
        let bench = Bench(calendar: calendar(utcOffsetSeconds: 19_800)).started()
        bench.measure(seconds: 5, down: 8, up: 0)
        let line = { (step: HistoryStep) in
            bench.engine.exportCSV(from: .distantPast, to: .distantFuture, step: step)
                .split(separator: "\n").last.map(String.init) ?? ""
        }
        XCTAssertTrue(line(.minute).hasPrefix("2026-03-01T12:00:00Z;"))
        XCTAssertTrue(line(.hour).hasPrefix("2026-03-01T11:30:00Z;"))
        XCTAssertTrue(line(.day).hasPrefix("2026-02-28T18:30:00Z;"))
    }

    func testISO8601HasNoFractionalSeconds() {
        XCTAssertEqual(FluxaEngine.iso8601(noon), "2026-03-01T12:00:00Z")
        XCTAssertEqual(FluxaEngine.iso8601(noon.addingTimeInterval(0.75)), "2026-03-01T12:00:00Z")
        XCTAssertEqual(FluxaEngine.iso8601(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
        XCTAssertEqual(FluxaEngine.iso8601(noon.addingTimeInterval(305 * day - 1)), "2026-12-31T11:59:59Z")
    }

    // MARK: Persistance

    func testDevicesSurviveARestart() throws {
        let store = MemoryStore()
        let clock = TestClock()
        let bench = Bench(store: store, clock: clock)
        try bench.engine.saveDevice(Device(name: "MacBook", kind: .computer, profileID: "standard", note: "bureau"))
        try bench.engine.saveDevice(Device(name: "Console", kind: .console))
        try bench.engine.deleteDevice(id: "device-2")  // enregistré sans attendre

        clock.advance(day)
        let reopened = FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
        XCTAssertEqual(reopened.devices, bench.engine.devices)
        XCTAssertEqual(reopened.devices.first?.addedAt, noon)
        XCTAssertEqual(reopened.devices.first?.kind, .computer)
        XCTAssertEqual(try reopened.saveDevice(Device(name: "Télé", kind: .television)).id, "device-3")
    }

    func testTheFileStoreKeepsDevices() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bench = Bench(store: FileStore(url: url))
        for kind in DeviceKind.allCases {
            try bench.engine.saveDevice(Device(name: kind.rawValue, kind: kind, profileID: "economy"))
        }
        let reopened = FluxaEngine(store: FileStore(url: url), calendar: calendar(), now: { noon })
        XCTAssertEqual(reopened.devices, bench.engine.devices)
        XCTAssertEqual(reopened.devices.map(\.kind), DeviceKind.allCases)
    }

    func testAStateSavedBeforeDevicesStillLoads() throws {
        // Un fichier écrit avant le registre : des règles, mais aucun appareil.
        let old = Data(
            #"""
            {"version":1,"profiles":[],"policyLog":[],"minutes":[],"hours":[],"days":[],
             "rules":[{"id":"rule-1","name":"Nuit","isEnabled":true,
                       "trigger":{"dailyUsage":{"bytes":1000}},"action":{"alert":{}}}],
             "nextRuleNumber":2,"activations":[],"automationLog":[],"nextAutomationEventID":1,"speedTests":[]}
            """#.utf8)
        let state = try JSONDecoder().decode(EngineState.self, from: old)
        XCTAssertEqual(state.devices, [])
        XCTAssertEqual(state.nextDeviceNumber, 1)
        XCTAssertEqual(state.rules.map(\.name), ["Nuit"])

        let store = MemoryStore()
        try store.save(state)
        let engine = FluxaEngine(store: store, calendar: calendar(), now: { noon })
        XCTAssertEqual(engine.diagnostics().events.map(\.level), [.info], "aucune erreur de lecture")
        XCTAssertTrue(engine.devices.isEmpty)
        XCTAssertEqual(try engine.saveDevice(Device(name: "MacBook")).id, "device-1")

        // Et l'état d'aujourd'hui se relit tel quel.
        let saved = try XCTUnwrap(try store.load())
        let reloaded = try JSONDecoder().decode(EngineState.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded, saved)
        XCTAssertEqual(reloaded.devices.count, 1)
    }

    func testErasingTheHistoryKeepsDevicesAndErasingEverythingRemovesThem() throws {
        let bench = Bench().started()
        try bench.engine.saveDevice(Device(name: "MacBook", profileID: "standard"))
        bench.measure(seconds: 5, down: 10, up: 1)

        try bench.engine.eraseHistory()
        XCTAssertEqual(bench.engine.devices.map(\.name), ["MacBook"])
        XCTAssertEqual(
            bench.engine.exportCSV(from: .distantPast, to: .distantFuture, step: .minute), header + "\n")

        try bench.engine.eraseAll()
        XCTAssertTrue(bench.engine.devices.isEmpty)
        XCTAssertEqual(try bench.engine.saveDevice(Device(name: "Neuf")).id, "device-1", "tout repart de un")
    }
}

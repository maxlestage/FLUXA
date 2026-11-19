import XCTest

@testable import FluxaCore

final class LimitTests: XCTestCase {
    private let streaming = BandwidthPolicy(downloadBps: 25_000_000, uploadBps: 10_000_000)

    // MARK: Profils

    func testShipsTheSevenPresetsOfTheSpecification() {
        let profiles = Bench().engine.profiles
        XCTAssertEqual(
            profiles.map(\.id),
            ["economy", "very-slow", "browsing", "standard", "streaming", "performance", "maximum"])
        XCTAssertEqual(
            profiles.map(\.name),
            ["Économie", "Très lent", "Navigation", "Standard", "Streaming", "Performance", "Maximum"])
        XCTAssertEqual(
            profiles.map(\.downloadBps),
            [1_000_000, 2_000_000, 5_000_000, 15_000_000, 25_000_000, 50_000_000, nil])
        XCTAssertEqual(
            profiles.map(\.uploadBps),
            [500_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000, nil])
        XCTAssertTrue(profiles.allSatisfy(\.isBuiltin))
    }

    func testEveryPresetIsAValidPolicy() throws {
        let engine = Bench().engine
        for profile in engine.profiles {
            XCTAssertNoThrow(try engine.validate(profile.policy), profile.name)
        }
    }

    func testCreatesEditsAndDeletesACustomProfile() throws {
        let engine = Bench().engine
        let visio = try engine.saveProfile(id: nil, name: "  Visio  ", downloadMbps: 8, uploadMbps: nil)
        XCTAssertEqual(visio.id, "custom-1")
        XCTAssertEqual(visio.name, "Visio")
        XCTAssertEqual(visio.downloadBps, 8_000_000)
        XCTAssertNil(visio.uploadBps)
        XCTAssertFalse(visio.isBuiltin)
        let game = try engine.saveProfile(id: nil, name: "Jeu", downloadMbps: nil, uploadMbps: 0.5)
        XCTAssertEqual(game.id, "custom-2")
        XCTAssertEqual(engine.profiles.map(\.id).suffix(2), ["custom-1", "custom-2"])
        XCTAssertEqual(engine.profiles.count, 9)

        let edited = try engine.saveProfile(
            id: visio.id, name: "Visio HD", downloadMbps: 12.5, uploadMbps: 4)
        XCTAssertEqual(edited.id, visio.id)
        XCTAssertEqual(edited.downloadBps, 12_500_000)
        XCTAssertEqual(engine.profiles.first { $0.id == visio.id }, edited)

        try engine.deleteProfile(id: visio.id)
        XCTAssertEqual(engine.profiles.map(\.id).last, "custom-2")
        XCTAssertThrows(try engine.deleteProfile(id: visio.id), .unknownProfile(id: visio.id))
        // Un identifiant supprimé n'est pas réutilisé.
        XCTAssertEqual(
            try engine.saveProfile(id: nil, name: "Autre", downloadMbps: 1, uploadMbps: 1).id,
            "custom-3")
    }

    func testAPresetCanBeEditedButNotDeleted() throws {
        let engine = Bench().engine
        let edited = try engine.saveProfile(
            id: "streaming", name: "Streaming 4K", downloadMbps: 30, uploadMbps: 10)
        XCTAssertTrue(edited.isBuiltin)
        XCTAssertEqual(engine.profiles[4], edited, "l'ordre ne change pas")
        XCTAssertThrows(try engine.deleteProfile(id: "streaming"), .builtinProfile(id: "streaming"))
        XCTAssertEqual(engine.profiles.count, 7)
    }

    func testRefusesInvalidProfiles() {
        let engine = Bench().engine
        XCTAssertThrows(
            try engine.saveProfile(id: nil, name: "  \n ", downloadMbps: 1, uploadMbps: 1), .emptyName)
        XCTAssertThrows(
            try engine.saveProfile(id: nil, name: "Bas", downloadMbps: 0.09, uploadMbps: nil),
            .rateOutOfRange(bps: 90_000))
        XCTAssertThrows(
            try engine.saveProfile(id: nil, name: "Haut", downloadMbps: nil, uploadMbps: 1_000.5),
            .rateOutOfRange(bps: 1_000_500_000))
        XCTAssertThrows(
            try engine.saveProfile(id: nil, name: "Zéro", downloadMbps: 0, uploadMbps: nil),
            .rateOutOfRange(bps: 0))
        // Des valeurs qui feraient planter une conversion directe en entier.
        for value in [Double.nan, .infinity, -3, 1e30] {
            XCTAssertThrowsError(
                try engine.saveProfile(id: nil, name: "N", downloadMbps: value, uploadMbps: nil),
                "\(value)")
        }
        XCTAssertThrows(
            try engine.saveProfile(id: "absent", name: "Nom", downloadMbps: 1, uploadMbps: 1),
            .unknownProfile(id: "absent"))
        XCTAssertEqual(engine.profiles.count, 7, "rien n'a été créé")
        // Les bornes elles-mêmes sont acceptées.
        XCTAssertNoThrow(try engine.saveProfile(id: nil, name: "Min", downloadMbps: 0.1, uploadMbps: 1_000))
    }

    // MARK: Validation

    func testAcceptsTheDocumentedRange() throws {
        let engine = Bench().engine
        try engine.validate(BandwidthPolicy(downloadBps: Limits.minimumBps, uploadBps: Limits.maximumBps))
        try engine.validate(BandwidthPolicy())
        try engine.validate(BandwidthPolicy(downloadBps: 25_000_000, mode: .scheduled, durationSeconds: 60))
        try engine.validate(BandwidthPolicy(uploadBps: 1_000_000, mode: .emergency, durationSeconds: .max))
    }

    func testRejectsLimitsOutsideTheRange() {
        let engine = Bench().engine
        XCTAssertThrows(
            try engine.validate(BandwidthPolicy(downloadBps: 99_999)), .rateOutOfRange(bps: 99_999))
        XCTAssertThrows(
            try engine.validate(BandwidthPolicy(uploadBps: 1_000_000_001)),
            .rateOutOfRange(bps: 1_000_000_001))
        // Zéro serait une suspension : iOS ne permet pas de couper le partage.
        XCTAssertThrows(try engine.validate(BandwidthPolicy(downloadBps: 0)), .rateOutOfRange(bps: 0))
        XCTAssertThrows(
            try engine.validate(BandwidthPolicy(downloadBps: 5_000_000, durationSeconds: 59)),
            .durationTooShort(seconds: 59))
    }

    // MARK: Demandes

    func testActivatingAProfileIsSimulatedNeverApplied() throws {
        let bench = Bench()
        XCTAssertNil(bench.engine.activeProfileID)
        XCTAssertNil(bench.engine.lastApplyResult)

        let result = try bench.engine.activateProfile(id: "streaming")
        XCTAssertEqual(result.status, .simulated)
        XCTAssertNil(result.effective, "rien n'est confirmé par le système")
        XCTAssertEqual(result.requested, streaming)
        XCTAssertEqual(result.capability, .hotspotLimit)
        XCTAssertEqual(result.date, noon)
        XCTAssertTrue(result.reason?.contains("iOS") ?? false)
        XCTAssertEqual(bench.engine.activeProfileID, "streaming")
        XCTAssertEqual(bench.engine.lastApplyResult, result)

        XCTAssertThrows(try bench.engine.activateProfile(id: "absent"), .unknownProfile(id: "absent"))
        XCTAssertEqual(bench.engine.activeProfileID, "streaming")
    }

    func testAManualLimitReplacesTheActiveProfile() throws {
        let engine = Bench().engine
        try engine.activateProfile(id: "browsing")
        let manual = BandwidthPolicy(
            downloadBps: 12_000_000, uploadBps: 3_000_000, mode: .softLimit, durationSeconds: 300)
        let result = try engine.apply(manual)
        XCTAssertEqual(result.status, .simulated)
        XCTAssertNil(result.effective)
        XCTAssertEqual(result.requested, manual)
        XCTAssertNil(engine.activeProfileID)
        XCTAssertEqual(engine.lastApplyResult, result)
    }

    func testADeviceLimitIsUnsupported() throws {
        let engine = Bench().engine
        try engine.activateProfile(id: "standard")
        let result = try engine.applyToDevice(BandwidthPolicy(downloadBps: 20_000_000, uploadBps: 5_000_000))
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertNil(result.effective)
        XCTAssertEqual(result.capability, .perDeviceShaping)
        XCTAssertNotNil(result.reason)
        XCTAssertNotEqual(result.reason, engine.policyLog(limit: 2).last?.reason)
        XCTAssertEqual(engine.activeProfileID, "standard", "le profil actif ne change pas")
        XCTAssertEqual(engine.lastApplyResult, result)
    }

    func testAnInvalidRequestLeavesNoTrace() throws {
        let engine = Bench().engine
        try engine.activateProfile(id: "economy")
        let before = engine.lastApplyResult
        XCTAssertThrowsError(try engine.apply(BandwidthPolicy(downloadBps: 1)))
        XCTAssertThrowsError(try engine.apply(BandwidthPolicy(downloadBps: 0, uploadBps: 0)))
        XCTAssertThrowsError(try engine.applyToDevice(BandwidthPolicy(durationSeconds: 5)))
        XCTAssertEqual(engine.policyLog(limit: 10).count, 1)
        XCTAssertEqual(engine.lastApplyResult, before)
        XCTAssertEqual(engine.activeProfileID, "economy")
    }

    func testThePolicyLogIsNewestFirstAndBounded() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "browsing")
        bench.clock.advance(1)
        try bench.engine.apply(streaming)
        bench.clock.advance(1)
        try bench.engine.applyToDevice(streaming)

        let log = bench.engine.policyLog(limit: 10)
        XCTAssertEqual(log.map(\.status), [.unsupported, .simulated, .simulated])
        XCTAssertEqual(log.map(\.date), [2, 1, 0].map { noon.addingTimeInterval($0) })
        XCTAssertTrue(log.allSatisfy { $0.effective == nil })
        XCTAssertEqual(bench.engine.policyLog(limit: 2).count, 2)
        XCTAssertEqual(bench.engine.policyLog(limit: 1).first?.status, .unsupported)
        XCTAssertTrue(bench.engine.policyLog(limit: 0).isEmpty)
        XCTAssertTrue(bench.engine.policyLog(limit: -3).isEmpty)

        for _ in 0..<(FluxaEngine.policyLogCapacity + 20) {
            try bench.engine.apply(streaming)
        }
        XCTAssertEqual(bench.engine.diagnostics().policyRecords, FluxaEngine.policyLogCapacity)
        XCTAssertEqual(bench.engine.policyLog(limit: 10_000).count, FluxaEngine.policyLogCapacity)
    }

    func testATimedLimitExpires() throws {
        let bench = Bench().started()
        try bench.engine.apply(BandwidthPolicy(downloadBps: 5_000_000, durationSeconds: 60))
        bench.measure(seconds: 59, down: 1, up: 1)
        XCTAssertNotNil(bench.engine.lastApplyResult)
        bench.measure(seconds: 1, down: 1, up: 1)
        XCTAssertNil(bench.engine.lastApplyResult)
        XCTAssertEqual(bench.engine.policyLog(limit: 5).count, 1, "le journal garde la demande")
        XCTAssertEqual(bench.engine.diagnostics().events.first?.message, "Limite arrivée à échéance.")
    }

    func testAnExpiredLimitIsNotRestoredAtStartup() throws {
        let store = MemoryStore()
        let clock = TestClock()
        let first = FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
        try first.saveProfile(id: "economy", name: "Économie", downloadMbps: 1, uploadMbps: 0.5)
        try first.apply(BandwidthPolicy(downloadBps: 5_000_000, durationSeconds: 600))
        clock.advance(599)
        XCTAssertNotNil(FluxaEngine(store: store, calendar: calendar(), now: { clock.date }).lastApplyResult)
        clock.advance(1)
        XCTAssertNil(FluxaEngine(store: store, calendar: calendar(), now: { clock.date }).lastApplyResult)
    }

    func testEditingTheActiveProfileUpdatesItsLimit() throws {
        let engine = Bench().engine
        let visio = try engine.saveProfile(id: nil, name: "Visio", downloadMbps: 8, uploadMbps: 4)
        try engine.activateProfile(id: visio.id)
        try engine.saveProfile(id: visio.id, name: "Visio", downloadMbps: 12, uploadMbps: 4)
        XCTAssertEqual(engine.lastApplyResult?.requested.downloadBps, 12_000_000)
        XCTAssertEqual(engine.lastApplyResult?.status, .simulated)
        XCTAssertEqual(engine.policyLog(limit: 10).count, 2)
        // Modifier un autre profil ne demande rien.
        try engine.saveProfile(id: "economy", name: "Économie", downloadMbps: 1.5, uploadMbps: 0.5)
        XCTAssertEqual(engine.policyLog(limit: 10).count, 2)

        try engine.deleteProfile(id: visio.id)
        XCTAssertNil(engine.activeProfileID)
        XCTAssertNil(engine.lastApplyResult, "la limite du profil disparaît avec lui")
    }

    // MARK: Simulation

    func testSimulationNeedsAMeasurement() {
        let bench = Bench()
        XCTAssertEqual(bench.engine.simulate(streaming), Simulation(download: nil, upload: nil))
        bench.started()
        XCTAssertNil(bench.engine.simulate(streaming).download, "le relevé de base ne suffit pas")
    }

    func testACapBelowTheMeasuredRateReducesIt() {
        let bench = Bench().started()
        bench.measure(seconds: 1, down: 42.8, up: 8.4)
        let simulation = bench.engine.simulate(streaming)
        XCTAssertEqual(simulation.download?.measuredBps, 42_800_000)
        XCTAssertEqual(simulation.download?.capBps, 25_000_000)
        XCTAssertEqual(simulation.download?.resultBps, 25_000_000)
        XCTAssertEqual(simulation.download?.isReduced, true)
        XCTAssertEqual(simulation.upload?.resultBps, 8_400_000)
        XCTAssertEqual(simulation.upload?.isReduced, false, "le montant est déjà sous le plafond")

        let unlimited = bench.engine.simulate(BandwidthPolicy())
        XCTAssertEqual(unlimited.download?.resultBps, 42_800_000)
        XCTAssertNil(unlimited.download?.capBps)
        XCTAssertEqual(unlimited.download?.isReduced, false)

        let equal = bench.engine.simulate(BandwidthPolicy(downloadBps: 42_800_000, uploadBps: 8_400_000))
        XCTAssertEqual(equal.download?.isReduced, false)
    }

    func testASoftLimitDoesNotReduceALoneFlow() {
        let bench = Bench().started()
        bench.measure(seconds: 1, down: 42.8, up: 8.4)
        let soft = BandwidthPolicy(downloadBps: 5_000_000, uploadBps: 2_000_000, mode: .softLimit)
        XCTAssertEqual(bench.engine.simulate(soft).download?.resultBps, 42_800_000)
        XCTAssertEqual(bench.engine.simulate(soft).download?.capBps, 5_000_000)
        for mode in LimitMode.allCases where mode != .softLimit {
            let policy = BandwidthPolicy(downloadBps: 5_000_000, mode: mode)
            XCTAssertEqual(bench.engine.simulate(policy).download?.resultBps, 5_000_000, "\(mode)")
        }
    }

    func testSimulationAppliesNothing() {
        let bench = Bench().started()
        bench.measure(seconds: 1, down: 42.8, up: 8.4)
        _ = bench.engine.simulate(streaming)
        XCTAssertNil(bench.engine.lastApplyResult)
        XCTAssertTrue(bench.engine.policyLog(limit: 5).isEmpty)
        XCTAssertEqual(bench.engine.snapshot.downloadBps, 42_800_000)
    }

    // MARK: Capacités

    func testCapabilitiesSayWhatIOSAllows() {
        let capabilities = Bench().engine.capabilities
        XCTAssertEqual(capabilities.map(\.capability), Capability.allCases)
        let support = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.capability, $0.support) })
        for capability in [Capability.internetMonitoring, .speedTest, .charts, .profiles] {
            XCTAssertEqual(support[capability], .supported, "\(capability)")
        }
        XCTAssertEqual(support[.localVPN], .conditional)
        for capability in [
            Capability.hotspotActivation, .hotspotClientDiscovery, .hotspotLimit, .perDeviceShaping,
            .clientDisconnect,
        ] {
            XCTAssertEqual(support[capability], .unsupported, "\(capability)")
        }
        XCTAssertTrue(capabilities.allSatisfy { !$0.note.isEmpty })
    }

    func testCapabilitiesJSONMatchesTheSpecification() throws {
        let json = Bench().engine.capabilitiesJSON()
        XCTAssertEqual(
            json,
            """
            {
              "platform": "ios",
              "capabilities": {
                "internet_monitoring": true,
                "hotspot_activation": false,
                "hotspot_client_discovery": false,
                "per_device_shaping": false,
                "local_vpn": true
              }
            }
            """)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(object?["platform"] as? String, "ios")
        XCTAssertEqual((object?["capabilities"] as? [String: Bool])?.count, 5)
    }

    func testErrorsHaveFrenchMessages() {
        let errors: [FluxaError] = [
            .rateOutOfRange(bps: 5), .durationTooShort(seconds: 3), .emptyName,
            .unknownProfile(id: "x"), .builtinProfile(id: "economy"), .store("disque plein."),
        ]
        for error in errors {
            let message = error.localizedDescription
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("FluxaError"), message)
        }
        XCTAssertTrue(FluxaError.rateOutOfRange(bps: 5).localizedDescription.contains("0,1 et 1 000 Mb/s"))
        XCTAssertTrue(FluxaError.store("disque plein.").localizedDescription.hasSuffix("disque plein."))
    }
}

final class LimitsConversionTests: XCTestCase {
    func testConvertsBetweenMbpsAndBps() {
        XCTAssertEqual(Limits.bps(fromMbps: 25), 25_000_000)
        XCTAssertEqual(Limits.bps(fromMbps: 0.1), 100_000)
        XCTAssertEqual(Limits.mbps(fromBps: 500_000), 0.5)
    }

    func testAnInvalidEntryNeverCrashes() {
        XCTAssertEqual(Limits.bps(fromMbps: -3), 0)
        XCTAssertEqual(Limits.bps(fromMbps: .nan), 0)
        XCTAssertEqual(Limits.bps(fromMbps: -.infinity), 0)
        XCTAssertEqual(Limits.bps(fromMbps: .infinity), 0)
        XCTAssertEqual(Limits.bps(fromMbps: 1e30), 1_000_000_000_000_000_000)
    }
}

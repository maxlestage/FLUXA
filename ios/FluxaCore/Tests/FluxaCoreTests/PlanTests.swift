import XCTest

@testable import FluxaCore

private let boot = noon.addingTimeInterval(-3 * day)
private let megabyte: UInt64 = 1_000_000
private let gigabyte: UInt64 = 1_000_000_000

/// Minuit UTC du jour donné, en 2026.
private func date(_ month: Int, _ dayOfMonth: Int, hour hourOfDay: Int = 0, minute minuteOfHour: Int = 0) -> Date {
    calendar().date(
        from: DateComponents(year: 2026, month: month, day: dayOfMonth, hour: hourOfDay, minute: minuteOfHour))!
}

// MARK: - Volume par réseau

final class NetworkUsageTests: XCTestCase {
    func testVolumeIsKeptByNetworkAtTheHourAndTheDay() {
        let bench = Bench(counterWidth: .bits64)
        let engine = bench.engine
        var mobile: UInt64 = 0
        var wireless: UInt64 = 0
        let read = { engine.ingest([cellular(mobile, mobile / 10), wifi(wireless, wireless / 4)]) }

        // Dix secondes en Wi-Fi : seul le Wi-Fi compte, même si le mobile bouge.
        engine.updatePath(kind: .wifi, isOnline: true)
        engine.start()
        _ = read()
        for _ in 0..<10 {
            bench.clock.advance(1)
            wireless += 4_000
            mobile += 10
            _ = read()
        }
        // Puis vingt secondes sur le réseau mobile, l'heure suivante.
        engine.updatePath(kind: .cellular, isOnline: true)
        bench.clock.advance(hour)
        _ = read()
        for _ in 0..<20 {
            bench.clock.advance(1)
            mobile += 1_000
            _ = read()
        }

        let all = engine.usageByNetwork(from: noon, to: noon.addingTimeInterval(2 * hour))
        XCTAssertEqual(
            all,
            [
                NetworkUsage(kind: .wifi, receivedBytes: 40_000, sentBytes: 10_000, outsideAppBytes: 0),
                NetworkUsage(kind: .cellular, receivedBytes: 20_000, sentBytes: 2_000, outsideAppBytes: 0),
            ], "du plus gros au plus petit")
        XCTAssertEqual(all.map(\.id), ["wifi", "cellular"])
        XCTAssertEqual(all.first?.totalBytes, 50_000)

        // Les bornes sont celles de l'historique : le début des heures, dans [from, to[.
        XCTAssertEqual(engine.usageByNetwork(from: noon, to: noon.addingTimeInterval(hour)).map(\.kind), [.wifi])
        XCTAssertEqual(
            engine.usageByNetwork(from: noon.addingTimeInterval(hour), to: .distantFuture).map(\.kind), [.cellular])
        XCTAssertTrue(engine.usageByNetwork(from: noon.addingTimeInterval(1), to: noon.addingTimeInterval(hour)).isEmpty)
        XCTAssertTrue(engine.usageByNetwork(from: noon.addingTimeInterval(hour), to: noon).isEmpty)

        // Une période qui commence avant la conservation des heures se lit sur les jours.
        XCTAssertEqual(
            engine.usageByNetwork(from: noon.addingTimeInterval(-40 * day), to: .distantFuture).map(\.totalBytes),
            [50_000, 22_000])

        // Le volume par réseau est le volume de l'historique, réparti.
        let usage = engine.usage(from: noon, to: .distantFuture)
        XCTAssertEqual(all.reduce(0) { $0 + $1.receivedBytes }, usage.receivedBytes)
        XCTAssertEqual(all.reduce(0) { $0 + $1.sentBytes }, usage.sentBytes)
    }

    func testHoursAreKeptThirtyDaysAndDaysTwelveMonths() throws {
        let bench = Bench().started()
        bench.measure(seconds: 10, down: 8, up: 0)
        bench.clock.advance(31 * day)
        bench.rebase()
        bench.measure(seconds: 70, down: 8, up: 0)  // une fin de minute : la purge passe
        try bench.engine.flush()

        let state = try XCTUnwrap(try bench.store.load())
        XCTAssertEqual(state.networkHours.count, 1, "l'heure d'il y a 31 jours est purgée")
        XCTAssertEqual(state.networkDays.count, 2)
        let recent = bench.engine.usageByNetwork(from: bench.clock.date.addingTimeInterval(-day), to: .distantFuture)
        XCTAssertEqual(recent.map(\.receivedBytes), [70 * megabyte])
        let everything = bench.engine.usageByNetwork(from: noon.addingTimeInterval(-day), to: .distantFuture)
        XCTAssertEqual(everything.map(\.receivedBytes), [80 * megabyte])

        // Treize mois plus tard, les jours sont partis à leur tour.
        bench.clock.advance(400 * day)
        bench.rebase()
        bench.measure(seconds: 61, down: 8, up: 0)
        XCTAssertEqual(
            bench.engine.usageByNetwork(from: .distantPast, to: .distantFuture).map(\.receivedBytes),
            [61 * megabyte])
    }

    func testAnAbsenceCountsForTheTimeItSharesWithThePeriod() {
        let bench = Bench()
        let engine = bench.engine
        bench.clock.date = noon.addingTimeInterval(-hour)  // 11 h
        engine.updatePath(kind: .cellular, isOnline: true)
        engine.start()
        engine.ingest([cellular(0, 0), wifi(0, 0)], bootTime: boot)
        engine.stop()
        bench.clock.advance(2 * hour)  // 13 h
        engine.start()
        engine.ingest([cellular(1_000_000, 200_000), wifi(300, 0)], bootTime: boot)

        // Toute l'absence : ses octets exacts.
        XCTAssertEqual(
            engine.usageByNetwork(from: noon.addingTimeInterval(-2 * hour), to: noon.addingTimeInterval(2 * hour)),
            [
                NetworkUsage(kind: .cellular, receivedBytes: 1_000_000, sentBytes: 200_000, outsideAppBytes: 1_200_000),
                NetworkUsage(kind: .wifi, receivedBytes: 300, sentBytes: 0, outsideAppBytes: 300),
            ])
        // La moitié de son temps : la moitié de son volume.
        XCTAssertEqual(
            engine.usageByNetwork(from: noon, to: noon.addingTimeInterval(4 * hour)),
            [
                NetworkUsage(kind: .cellular, receivedBytes: 500_000, sentBytes: 100_000, outsideAppBytes: 600_000),
                NetworkUsage(kind: .wifi, receivedBytes: 150, sentBytes: 0, outsideAppBytes: 150),
            ])
        // Un quart, pris à l'intérieur.
        XCTAssertEqual(
            engine.usageByNetwork(from: noon, to: noon.addingTimeInterval(30 * minute)).first,
            NetworkUsage(kind: .cellular, receivedBytes: 250_000, sentBytes: 50_000, outsideAppBytes: 300_000))
        // Rien en commun.
        XCTAssertTrue(engine.usageByNetwork(from: noon.addingTimeInterval(hour), to: .distantFuture).isEmpty)
        XCTAssertTrue(engine.usageByNetwork(from: .distantPast, to: noon.addingTimeInterval(-hour)).isEmpty)

        // Le mesuré et le rattrapé s'ajoutent.
        for second in 1...10 {
            bench.clock.advance(1)
            engine.ingest([cellular(1_000_000 + UInt64(second) * 1_000, 200_000), wifi(300, 0)], bootTime: boot)
        }
        XCTAssertEqual(
            engine.usageByNetwork(from: noon.addingTimeInterval(-2 * hour), to: .distantFuture).first,
            NetworkUsage(kind: .cellular, receivedBytes: 1_010_000, sentBytes: 200_000, outsideAppBytes: 1_200_000))
    }

    func testTheSharingBridgeIsNeverANetwork() {
        let bench = Bench()
        let engine = bench.engine
        engine.updatePath(kind: .cellular, isOnline: true)
        engine.start()
        engine.ingest([cellular(0, 0), bridge(0, 0)], bootTime: boot)
        bench.clock.advance(1)
        engine.ingest([cellular(1_000, 0), bridge(50_000, 900_000)], bootTime: boot)
        XCTAssertEqual(
            engine.usageByNetwork(from: .distantPast, to: .distantFuture),
            [NetworkUsage(kind: .cellular, receivedBytes: 1_000, sentBytes: 0, outsideAppBytes: 0)])
    }
}

// MARK: - Forfait

final class DataPlanTests: XCTestCase {
    /// Un moteur à la date donnée, qui a mesuré `megabytes` Mo reçus sur le réseau mobile.
    private func bench(at start: Date = noon, measured megabytes: Int = 0) -> Bench {
        let bench = Bench(clock: TestClock(start)).started()
        if megabytes > 0 {
            bench.measure(seconds: megabytes, down: 8, up: 0)
        }
        return bench
    }

    func testRefusesAnInvalidPlan() throws {
        let engine = bench().engine
        XCTAssertNil(engine.dataPlan)
        XCTAssertNil(engine.planStatus())
        let refused: [(DataPlan, String)] = [
            (DataPlan(allowanceBytes: 0, resetDay: 1), "Le volume du forfait doit être supérieur à zéro."),
            (DataPlan(allowanceBytes: gigabyte, resetDay: 0), "Le jour de remise à zéro va de 1 à 31."),
            (DataPlan(allowanceBytes: gigabyte, resetDay: 32), "Le jour de remise à zéro va de 1 à 31."),
        ]
        for (plan, reason) in refused {
            XCTAssertThrows(try engine.setDataPlan(plan), .invalidPlan(reason))
            XCTAssertEqual(FluxaError.invalidPlan(reason).localizedDescription, reason)
        }
        XCTAssertNil(engine.dataPlan)
        XCTAssertThrows(try engine.calibratePlan(usedBytes: 1), .invalidPlan("Réglez d’abord votre forfait."))

        let plan = DataPlan(allowanceBytes: 1, resetDay: 31)
        try engine.setDataPlan(plan)
        XCTAssertEqual(engine.dataPlan, plan)
        try engine.setDataPlan(nil)
        XCTAssertNil(engine.dataPlan)
        XCTAssertNil(engine.planStatus())
    }

    func testTheCycleRunsFromOneResetToTheNext() throws {
        let cycle = { (resetDay: Int, now: Date) throws -> [Date] in
            let bench = self.bench(at: now)
            try bench.engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: resetDay))
            let status = try XCTUnwrap(bench.engine.planStatus())
            return [status.cycleStart, status.cycleEnd]
        }
        XCTAssertEqual(try cycle(1, noon), [date(3, 1), date(4, 1)], "le jour même de la remise à zéro")
        XCTAssertEqual(try cycle(15, noon), [date(2, 15), date(3, 15)])
        XCTAssertEqual(try cycle(15, date(3, 15)), [date(3, 15), date(4, 15)], "à minuit pile")
        XCTAssertEqual(try cycle(15, date(3, 14, hour: 23, minute: 59)), [date(2, 15), date(3, 15)])
        // Février 2026 a 28 jours : un forfait du 31 y repart le 28.
        XCTAssertEqual(try cycle(31, date(2, 15)), [date(1, 31), date(2, 28)])
        XCTAssertEqual(try cycle(31, date(2, 28, hour: 12)), [date(2, 28), date(3, 31)])
        XCTAssertEqual(try cycle(31, noon), [date(2, 28), date(3, 31)])
        XCTAssertEqual(try cycle(31, date(3, 31)), [date(3, 31), date(4, 30)])
        XCTAssertEqual(try cycle(30, date(2, 27)), [date(1, 30), date(2, 28)])
        // D'une année à l'autre.
        XCTAssertEqual(try cycle(20, date(1, 5)), [calendar().date(byAdding: .month, value: -1, to: date(1, 20))!, date(1, 20)])

        // Le cycle suit le calendrier du moteur : minuit local.
        let paris = Bench(clock: TestClock(noon), calendar: calendar(utcOffsetSeconds: 3_600))
        try paris.engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 1))
        XCTAssertEqual(paris.engine.planStatus()?.cycleStart, date(3, 1).addingTimeInterval(-hour))
    }

    func testCountsTheMobileVolumeOfTheCycle() throws {
        let bench = bench(measured: 110)
        let engine = bench.engine
        try engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 1))
        let status = try XCTUnwrap(engine.planStatus())
        XCTAssertEqual(status.plan, DataPlan(allowanceBytes: gigabyte, resetDay: 1))
        XCTAssertEqual(status.usedBytes, 110 * megabyte)
        XCTAssertEqual(status.measuredBytes, 110 * megabyte)
        XCTAssertEqual(status.outsideAppBytes, 0)
        XCTAssertNil(status.calibratedBytes)
        XCTAssertEqual(status.remainingBytes, 890 * megabyte)
        XCTAssertEqual(status.fractionUsed, 0.11, accuracy: 1e-12)
        XCTAssertEqual(status.daysRemaining, 31, "30 jours et demi, arrondis vers le haut")
        XCTAssertEqual(status.dailyBudgetBytes, 890 * megabyte / 31)
        XCTAssertNil(status.projectedBytes, "moins d'un jour écoulé dans le cycle")
        XCTAssertNil(status.exhaustionDate)

        // Le Wi-Fi n'entame pas le forfait.
        engine.updatePath(kind: .wifi, isOnline: true)
        engine.ingest([cellular(bench.received, bench.sent), wifi(0, 0)])
        bench.clock.advance(1)
        engine.ingest([cellular(bench.received, bench.sent), wifi(50_000_000, 0)])
        XCTAssertEqual(engine.usageByNetwork(from: noon, to: .distantFuture).map(\.kind), [.cellular, .wifi])
        XCTAssertEqual(engine.planStatus()?.usedBytes, 110 * megabyte)

        // Ce qui a été mesuré avant le cycle n'y entre pas.
        let later = self.bench(at: date(2, 20), measured: 40)
        try later.engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 1))
        XCTAssertEqual(later.engine.planStatus()?.usedBytes, 40 * megabyte)
        later.clock.date = date(3, 2)
        XCTAssertEqual(later.engine.planStatus()?.usedBytes, 0)
        XCTAssertEqual(later.engine.planStatus()?.remainingBytes, gigabyte)
    }

    func testProjectsTheEndOfTheCycleAtTheCurrentPace() throws {
        let bench = bench(measured: 110)
        let engine = bench.engine
        try engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 1))
        bench.clock.date = date(3, 11)  // dix jours écoulés sur trente et un
        var status = try XCTUnwrap(engine.planStatus())
        XCTAssertEqual(status.projectedBytes, 341 * megabyte)
        XCTAssertNil(status.exhaustionDate, "la projection reste sous le forfait")
        XCTAssertEqual(status.daysRemaining, 21)
        XCTAssertEqual(status.dailyBudgetBytes, 890 * megabyte / 21)

        // Un forfait plus petit : épuisé avant la fin, à ce rythme.
        try engine.setDataPlan(DataPlan(allowanceBytes: 200 * megabyte, resetDay: 1))
        status = try XCTUnwrap(engine.planStatus())
        XCTAssertEqual(status.projectedBytes, 341 * megabyte)
        let exhaustion = try XCTUnwrap(status.exhaustionDate)
        XCTAssertEqual(exhaustion.timeIntervalSince(date(3, 1)), 10 * day * 200 / 110, accuracy: 1)
        XCTAssertGreaterThan(exhaustion, bench.clock.date)
        XCTAssertLessThan(exhaustion, status.cycleEnd)

        // Rien d'utilisé : une projection nulle, pas d'épuisement.
        let idle = self.bench()
        try idle.engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 1))
        idle.clock.date = date(3, 11)
        XCTAssertEqual(idle.engine.planStatus()?.projectedBytes, 0)
        XCTAssertNil(idle.engine.planStatus()?.exhaustionDate)
    }

    func testAnExceededPlanSaysSo() throws {
        let bench = bench(measured: 110)
        try bench.engine.setDataPlan(DataPlan(allowanceBytes: 100 * megabyte, resetDay: 1))
        let status = try XCTUnwrap(bench.engine.planStatus())
        XCTAssertEqual(status.usedBytes, 110 * megabyte)
        XCTAssertEqual(status.remainingBytes, 0)
        XCTAssertEqual(status.fractionUsed, 1.1, accuracy: 1e-12)
        XCTAssertEqual(status.dailyBudgetBytes, 0)
        XCTAssertEqual(status.exhaustionDate, bench.clock.date, "déjà dépassé : maintenant")
        XCTAssertNil(status.projectedBytes)

        // Pile au forfait : épuisé aussi.
        try bench.engine.setDataPlan(DataPlan(allowanceBytes: 110 * megabyte, resetDay: 1))
        XCTAssertEqual(bench.engine.planStatus()?.exhaustionDate, bench.clock.date)
        XCTAssertEqual(bench.engine.planStatus()?.fractionUsed, 1)
    }

    func testAlwaysAtLeastOneDayRemaining() throws {
        let bench = bench(at: date(3, 31, hour: 23, minute: 59))
        try bench.engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 1))
        var status = try XCTUnwrap(bench.engine.planStatus())
        XCTAssertEqual(status.daysRemaining, 1)
        XCTAssertEqual(status.dailyBudgetBytes, gigabyte)
        bench.clock.date = date(3, 30, hour: 23, minute: 59)
        status = try XCTUnwrap(bench.engine.planStatus())
        XCTAssertEqual(status.daysRemaining, 2)
        bench.clock.date = date(3, 31)
        XCTAssertEqual(bench.engine.planStatus()?.daysRemaining, 1, "un jour entier")
    }

    func testCountsWhatWasCaughtUpOutsideTheApp() throws {
        // Une absence à cheval sur la remise à zéro : du 28 février midi au 1er mars midi.
        let bench = Bench(clock: TestClock(noon.addingTimeInterval(-day)))
        let engine = bench.engine
        engine.updatePath(kind: .cellular, isOnline: true)
        engine.start()
        engine.ingest([cellular(0, 0), wifi(0, 0)], bootTime: boot)
        engine.stop()
        bench.clock.advance(day)
        engine.start()
        engine.ingest([cellular(600 * megabyte, 200 * megabyte), wifi(900 * megabyte, 0)], bootTime: boot)
        try engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 1))

        var status = try XCTUnwrap(engine.planStatus())
        XCTAssertEqual(status.outsideAppBytes, 400 * megabyte, "la moitié de l'absence est dans le cycle")
        XCTAssertEqual(status.measuredBytes, 0)
        XCTAssertEqual(status.usedBytes, 400 * megabyte)

        // Mesuré dans l'app et rattrapé s'ajoutent.
        bench.clock.advance(1)
        engine.ingest([cellular(601 * megabyte, 200 * megabyte), wifi(900 * megabyte, 0)], bootTime: boot)
        status = try XCTUnwrap(engine.planStatus())
        XCTAssertEqual(status.measuredBytes, megabyte)
        XCTAssertEqual(status.usedBytes, 401 * megabyte)
        XCTAssertEqual(status.remainingBytes, 599 * megabyte)
    }

    func testCalibrationReplacesWhatWasCountedBefore() throws {
        let bench = bench(measured: 110)
        let engine = bench.engine
        try engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 1))
        // « Mon opérateur indique 500 Mo. »
        try engine.calibratePlan(usedBytes: 500 * megabyte)
        var status = try XCTUnwrap(engine.planStatus())
        XCTAssertEqual(status.calibratedBytes, 500 * megabyte)
        XCTAssertEqual(status.usedBytes, 500 * megabyte)
        XCTAssertEqual(status.measuredBytes, 0)
        XCTAssertEqual(status.outsideAppBytes, 0)

        // Ce qui est mesuré ensuite s'ajoute, dès la seconde suivante.
        bench.measure(seconds: 11, down: 8, up: 0)
        status = try XCTUnwrap(engine.planStatus())
        XCTAssertEqual(status.measuredBytes, 11 * megabyte)
        XCTAssertEqual(status.usedBytes, 511 * megabyte)

        // Ce qui est rattrapé ensuite aussi.
        engine.stop()
        engine.start()
        engine.ingest([cellular(bench.received, bench.sent)], bootTime: boot)
        engine.stop()
        bench.clock.advance(hour)
        engine.start()
        engine.ingest([cellular(bench.received + 20 * megabyte, bench.sent)], bootTime: boot)
        status = try XCTUnwrap(engine.planStatus())
        XCTAssertEqual(status.outsideAppBytes, 20 * megabyte)
        XCTAssertEqual(status.usedBytes, 531 * megabyte)
        XCTAssertEqual(status.calibratedBytes, 500 * megabyte)

        // Un recalage à la baisse vaut aussi, et remplace le précédent.
        try engine.calibratePlan(usedBytes: 0)
        XCTAssertEqual(engine.planStatus()?.usedBytes, 0)
        XCTAssertEqual(engine.planStatus()?.calibratedBytes, 0)

        // Changer le volume du forfait garde le recalage ; changer le jour l'efface.
        try engine.calibratePlan(usedBytes: 300 * megabyte)
        try engine.setDataPlan(DataPlan(allowanceBytes: 2 * gigabyte, resetDay: 1))
        XCTAssertEqual(engine.planStatus()?.usedBytes, 300 * megabyte)
        XCTAssertEqual(engine.planStatus()?.remainingBytes, 1_700 * megabyte)
        try engine.setDataPlan(DataPlan(allowanceBytes: 2 * gigabyte, resetDay: 2))
        XCTAssertNil(engine.planStatus()?.calibratedBytes)
        XCTAssertEqual(engine.planStatus()?.usedBytes, 141 * megabyte, "le cycle du 2 février au 2 mars : tout le mesuré et le rattrapé")
    }

    func testCalibrationExpiresWithItsCycle() throws {
        let bench = bench(measured: 10)
        let engine = bench.engine
        try engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 1))
        try engine.calibratePlan(usedBytes: 700 * megabyte)
        bench.clock.date = date(3, 31, hour: 23)
        XCTAssertEqual(engine.planStatus()?.usedBytes, 700 * megabyte)
        XCTAssertEqual(engine.planStatus()?.projectedBytes, UInt64((700e6 / (30 * day + 23 * hour) * 31 * day).rounded()))

        bench.clock.date = date(4, 1)
        var status = try XCTUnwrap(engine.planStatus())
        XCTAssertNil(status.calibratedBytes)
        XCTAssertEqual(status.usedBytes, 0)
        XCTAssertEqual(status.cycleStart, date(4, 1))
        XCTAssertEqual(status.cycleEnd, date(5, 1))

        bench.rebase()
        bench.measure(seconds: 5, down: 8, up: 0)
        status = try XCTUnwrap(engine.planStatus())
        XCTAssertEqual(status.usedBytes, 5 * megabyte)
        XCTAssertEqual(status.measuredBytes, 5 * megabyte)
    }

    func testErasingTheHistoryKeepsThePlanOnly() throws {
        let bench = bench(measured: 10)
        let engine = bench.engine
        let plan = DataPlan(allowanceBytes: gigabyte, resetDay: 1)
        try engine.setDataPlan(plan)
        try engine.calibratePlan(usedBytes: 700 * megabyte)
        try engine.eraseHistory()
        XCTAssertEqual(engine.dataPlan, plan)
        XCTAssertNil(engine.planStatus()?.calibratedBytes)
        XCTAssertEqual(engine.planStatus()?.usedBytes, 0)
        XCTAssertTrue(engine.usageByNetwork(from: .distantPast, to: .distantFuture).isEmpty)

        try engine.eraseAll()
        XCTAssertNil(engine.dataPlan)
        XCTAssertNil(engine.planStatus())
    }

    func testThePlanIsSaved() throws {
        let store = MemoryStore()
        let bench = Bench(store: store).started()
        bench.measure(seconds: 10, down: 8, up: 0)
        try bench.engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 5))
        try bench.engine.calibratePlan(usedBytes: 42 * megabyte)
        bench.measure(seconds: 3, down: 8, up: 0)
        bench.engine.stop()

        let reopened = FluxaEngine(store: store, calendar: calendar(), now: { bench.clock.date })
        XCTAssertEqual(reopened.dataPlan, DataPlan(allowanceBytes: gigabyte, resetDay: 5))
        XCTAssertEqual(reopened.planStatus(), bench.engine.planStatus())
        XCTAssertEqual(reopened.planStatus()?.usedBytes, 45 * megabyte)
    }
}

// MARK: - Seuil du forfait

final class PlanUsageRuleTests: XCTestCase {
    private func rule(_ name: String, percent: Int, profile: String? = nil) -> AutomationRule {
        AutomationRule(
            name: name, trigger: .planUsage(percent: percent),
            action: profile.map { .activateProfile(id: $0) } ?? .alert)
    }

    func testRefusesAThresholdOutOfRangeOrWithoutAPlan() throws {
        let engine = Bench().engine
        XCTAssertThrows(
            try engine.saveRule(rule("Seuil", percent: 80)), .invalidRule("Réglez d’abord votre forfait."))
        try engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 1))
        for percent in [0, -5, 101] {
            XCTAssertThrows(
                try engine.saveRule(rule("Seuil", percent: percent)),
                .invalidRule("Le pourcentage du forfait va de 1 à 100."))
        }
        XCTAssertTrue(engine.automationRules.isEmpty)
        XCTAssertEqual(try engine.saveRule(rule("Début", percent: 1)).id, "rule-1")
        var saved = try engine.saveRule(rule("Fin", percent: 100))

        // Le forfait retiré, la règle reste modifiable, mais pas son seuil ; elle attend.
        try engine.setDataPlan(nil)
        saved.name = "Tout le forfait"
        saved.isEnabled = false
        XCTAssertEqual(try engine.saveRule(saved).name, "Tout le forfait")
        saved.trigger = .planUsage(percent: 90)
        XCTAssertThrows(try engine.saveRule(saved), .invalidRule("Réglez d’abord votre forfait."))
        XCTAssertTrue(engine.evaluateAutomations().isEmpty)
    }

    func testThePlanIsComputedOncePerEvaluation() throws {
        let bench = Bench().started()
        let engine = bench.engine
        try engine.setDataPlan(DataPlan(allowanceBytes: 100 * megabyte, resetDay: 1))
        for (name, percent) in [("Moitié", 50), ("Alerte", 80), ("Tout", 100)] {
            try engine.saveRule(rule(name, percent: percent))
        }
        bench.measure(seconds: 10, down: 8, up: 0)
        // Trois règles de forfait : un seul calcul du forfait par évaluation, et non trois.
        for _ in 0..<5 {
            let before = engine.planStatusComputations
            XCTAssertTrue(engine.evaluateAutomations().isEmpty)
            XCTAssertEqual(engine.planStatusComputations - before, 1)
        }
        // Sans règle de forfait, aucun calcul.
        for rule in engine.automationRules {
            try engine.deleteRule(id: rule.id)
        }
        let before = engine.planStatusComputations
        engine.evaluateAutomations()
        XCTAssertEqual(engine.planStatusComputations, before)
    }

    func testFiresOncePerCycleAtTheThreshold() throws {
        let bench = Bench().started()
        let engine = bench.engine
        try engine.setDataPlan(DataPlan(allowanceBytes: 100 * megabyte, resetDay: 1))
        try engine.saveRule(rule("Alerte", percent: 80))
        try engine.saveRule(rule("Économie", percent: 100, profile: "economy"))
        try engine.activateProfile(id: "standard")

        bench.measure(seconds: 79, down: 8, up: 0)
        XCTAssertTrue(engine.evaluateAutomations().isEmpty, "79 %")
        bench.measure(seconds: 1, down: 8, up: 0)
        XCTAssertEqual(engine.evaluateAutomations().map(\.message), ["Forfait : 80 % atteint."], "le seuil exact")
        bench.measure(seconds: 5, down: 8, up: 0)
        XCTAssertTrue(engine.evaluateAutomations().isEmpty, "une seule fois")

        bench.measure(seconds: 15, down: 8, up: 0)
        let events = engine.evaluateAutomations()
        XCTAssertEqual(events.map(\.message), ["Forfait : 100 % atteint : profil Économie choisi."])
        XCTAssertEqual(events.first?.kind, .started)
        XCTAssertEqual(engine.activeProfileID, "economy")

        // Le dépassement ne redéclenche rien, ni les jours suivants du cycle.
        bench.clock.date = date(3, 20)
        XCTAssertTrue(engine.evaluateAutomations().isEmpty)
        XCTAssertEqual(engine.activeProfileID, "economy")

        // À la remise à zéro du forfait, le profil d'avant revient.
        bench.clock.date = date(4, 1).addingTimeInterval(1)
        XCTAssertEqual(
            engine.evaluateAutomations().map(\.message),
            ["Nouveau cycle du forfait : retour au profil Standard."])
        XCTAssertEqual(engine.activeProfileID, "standard")
        XCTAssertTrue(engine.evaluateAutomations().isEmpty, "le nouveau cycle repart de zéro")

        // Et les seuils valent de nouveau.
        bench.rebase()
        bench.measure(seconds: 80, down: 8, up: 0)
        XCTAssertEqual(engine.evaluateAutomations().map(\.message), ["Forfait : 80 % atteint."])
    }

    func testTheThresholdCountsCalibrationAndCaughtUpVolume() throws {
        let bench = Bench().started()
        let engine = bench.engine
        try engine.setDataPlan(DataPlan(allowanceBytes: gigabyte, resetDay: 1))
        try engine.saveRule(rule("Moitié", percent: 50))
        XCTAssertTrue(engine.evaluateAutomations().isEmpty)
        try engine.calibratePlan(usedBytes: 499 * megabyte)
        XCTAssertTrue(engine.evaluateAutomations().isEmpty)
        bench.measure(seconds: 1, down: 8, up: 0)
        XCTAssertEqual(engine.evaluateAutomations().map(\.message), ["Forfait : 50 % atteint."])
    }
}

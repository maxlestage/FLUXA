import XCTest

@testable import FluxaCore

final class HistoryTests: XCTestCase {
    func testHistoryComesByMinuteHourAndDay() {
        let bench = Bench().started()
        bench.measure(seconds: 90, down: 20, up: 4)
        bench.clock.advance(hour)
        bench.rebase()
        bench.measure(seconds: 30, down: 40, up: 8)
        let end = bench.clock.date.addingTimeInterval(1)

        let minutes = bench.engine.history(from: noon, to: noon.addingTimeInterval(120), step: .minute)
        XCTAssertEqual(minutes.map(\.start), [noon, noon.addingTimeInterval(60)])
        XCTAssertEqual(minutes[0].sampleCount, 59, "de 12:00:01 à 12:00:59")
        XCTAssertEqual(minutes[1].sampleCount, 31)
        XCTAssertEqual(minutes[0].averageDownloadBps, 20_000_000)
        XCTAssertEqual(minutes[0].averageUploadBps, 4_000_000)
        XCTAssertEqual(minutes[0].receivedBytes, 59 * 2_500_000)

        let hours = bench.engine.history(from: noon, to: end, step: .hour)
        XCTAssertEqual(hours.map(\.start), [noon, noon.addingTimeInterval(hour)])
        XCTAssertEqual(hours.map(\.sampleCount), [90, 30])
        XCTAssertEqual(hours[1].averageDownloadBps, 40_000_000)
        XCTAssertEqual(hours[1].peakUploadBps, 8_000_000)

        let days = bench.engine.history(from: noon.addingTimeInterval(-day), to: end, step: .day)
        XCTAssertEqual(days.map(\.start), [noon.addingTimeInterval(-12 * hour)])
        XCTAssertEqual(days[0].sampleCount, 120)
        XCTAssertEqual(days[0].receivedBytes, UInt64(90 * 2_500_000 + 30 * 5_000_000))
        XCTAssertEqual(days[0].sentBytes, UInt64(90 * 500_000 + 30 * 1_000_000))
        XCTAssertEqual(days[0].peakDownloadBps, 40_000_000)
        // 3 000 Mb en 120 s mesurées.
        XCTAssertEqual(days[0].averageDownloadBps, 25_000_000)

        let diagnostics = bench.engine.diagnostics()
        XCTAssertEqual(diagnostics.minuteAggregates, 4)
        XCTAssertEqual(diagnostics.hourAggregates, 2)
        XCTAssertEqual(diagnostics.dayAggregates, 1)
    }

    func testHistoryBoundsAreHalfOpen() {
        let bench = Bench().started()
        bench.measure(seconds: 180, down: 10, up: 1)
        let second = noon.addingTimeInterval(60)
        XCTAssertEqual(
            bench.engine.history(from: second, to: second.addingTimeInterval(60), step: .minute)
                .map(\.start), [second])
        XCTAssertTrue(bench.engine.history(from: second, to: second, step: .minute).isEmpty)
        XCTAssertTrue(bench.engine.history(from: second, to: noon, step: .minute).isEmpty)
        XCTAssertTrue(
            bench.engine.history(from: noon.addingTimeInterval(day), to: .distantFuture, step: .hour)
                .isEmpty)
    }

    func testAveragesAreWeightedByMeasuredTime() {
        // 10 Mb/s pendant 9 s puis 100 Mb/s pendant 1 s : 19 Mb/s, pas 55.
        let bench = Bench(counterWidth: .bits64)
        bench.engine.updatePath(kind: .wifi, isOnline: true)
        bench.engine.start()
        bench.engine.ingest([wifi(0, 0)])
        bench.clock.advance(9)
        bench.engine.ingest([wifi(11_250_000, 0)])
        bench.clock.advance(1)
        bench.engine.ingest([wifi(23_750_000, 0)])
        let minuteAggregate = bench.engine.history(from: noon, to: .distantFuture, step: .minute)[0]
        XCTAssertEqual(minuteAggregate.averageDownloadBps, 19_000_000)
        XCTAssertEqual(minuteAggregate.peakDownloadBps, 100_000_000)
        XCTAssertEqual(minuteAggregate.sampleCount, 2)
    }

    func testDaysAndHoursFollowTheCalendar() {
        // À UTC+5:30, 12 h UTC est 17 h 30 : l'heure locale commence à 11 h 30 UTC.
        let bench = Bench(calendar: calendar(utcOffsetSeconds: 19_800)).started()
        bench.measure(seconds: 5, down: 10, up: 1)
        let hours = bench.engine.history(from: .distantPast, to: .distantFuture, step: .hour)
        XCTAssertEqual(hours.map(\.start), [noon.addingTimeInterval(-30 * minute)])
        let days = bench.engine.history(from: .distantPast, to: .distantFuture, step: .day)
        XCTAssertEqual(
            days.map(\.start), [noon.addingTimeInterval(-17 * hour - 30 * minute)],
            "minuit local = 18 h 30 UTC la veille")
    }

    func testRetentionKeeps7Days30DaysAnd12Months() {
        let bench = Bench().started()
        let start = bench.clock.date
        // Une courte mesure à différents âges, vus depuis le dernier jour.
        var ages: [Int] = []
        var elapsedDays = 0
        for age in [400, 370, 360, 31, 29, 8, 6, 0] {
            bench.clock.advance(Double((400 - age) - elapsedDays) * day)
            elapsedDays = 400 - age
            bench.rebase()
            bench.measure(seconds: 2, down: 10, up: 1)
            ages.append(age)
        }
        // La purge passe à la fin d'une minute.
        bench.measure(seconds: 60, down: 10, up: 1)
        let end = bench.clock.date
        XCTAssertEqual(end.timeIntervalSince(start), 400 * day + 76, accuracy: 0.001)

        let all = { (step: HistoryStep) in
            bench.engine.history(from: .distantPast, to: .distantFuture, step: step)
        }
        let ageInDays = { (aggregate: Aggregate) in Int(end.timeIntervalSince(aggregate.start) / day) }
        XCTAssertEqual(Set(all(.minute).map(ageInDays)), [6, 0], "minutes : 7 jours")
        XCTAssertEqual(Set(all(.hour).map(ageInDays)), [29, 6, 0], "heures : 30 jours")
        XCTAssertEqual(Set(all(.day).map(ageInDays)), [360, 31, 29, 8, 6, 0], "jours : 12 mois")
        XCTAssertTrue(
            bench.engine.diagnostics().events.contains { $0.message.hasPrefix("Purge :") })
    }

    func testRetentionAlsoAppliesAtStartup() throws {
        let store = MemoryStore()
        let clock = TestClock()
        let bench = Bench(store: store, clock: clock).started()
        bench.measure(seconds: 5, down: 10, up: 1)
        try bench.engine.flush()

        clock.advance(8 * day)
        let later = FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
        XCTAssertEqual(later.diagnostics().minuteAggregates, 0)
        XCTAssertEqual(later.diagnostics().hourAggregates, 1)
        XCTAssertEqual(later.diagnostics().dayAggregates, 1)
    }

    func testUsageSumsAPeriod() {
        let bench = Bench().started()
        bench.measure(seconds: 60, down: 20, up: 4)
        bench.measure(seconds: 60, down: 40, up: 8)
        let usage = bench.engine.usage(from: noon, to: noon.addingTimeInterval(hour))
        XCTAssertEqual(usage.receivedBytes, UInt64(60 * 2_500_000 + 60 * 5_000_000))
        XCTAssertEqual(usage.sentBytes, UInt64(60 * 500_000 + 60 * 1_000_000))
        XCTAssertEqual(usage.averageDownloadBps, 30_000_000)
        XCTAssertEqual(usage.averageUploadBps, 6_000_000)
        XCTAssertEqual(usage.peakDownloadBps, 40_000_000)
        XCTAssertEqual(usage.peakUploadBps, 8_000_000)

        // La première minute seulement (59 mesures, la 60e tombe à 12:01:00).
        let firstMinute = bench.engine.usage(from: noon, to: noon.addingTimeInterval(60))
        XCTAssertEqual(firstMinute.receivedBytes, 59 * 2_500_000)
        XCTAssertEqual(firstMinute.peakDownloadBps, 20_000_000)
    }

    func testUsageOfAnEmptyPeriodHasNoAverages() {
        let bench = Bench().started()
        bench.measure(seconds: 5, down: 20, up: 4)
        let usage = bench.engine.usage(from: noon.addingTimeInterval(day), to: noon.addingTimeInterval(2 * day))
        XCTAssertEqual(usage, UsageSummary())
        XCTAssertNil(usage.averageDownloadBps, "pas de mesure : pas de moyenne, et surtout pas zéro")
        XCTAssertNil(usage.peakDownloadBps)
    }

    func testUsageOfOldPeriodsUsesCoarserAggregates() {
        let bench = Bench().started()
        bench.measure(seconds: 10, down: 20, up: 4)
        bench.clock.advance(10 * day)
        bench.rebase()
        bench.measure(seconds: 61, down: 20, up: 4)  // passe une fin de minute : purge
        XCTAssertTrue(
            bench.engine.history(from: noon, to: noon.addingTimeInterval(hour), step: .minute).isEmpty)
        // Les minutes d'il y a dix jours sont purgées ; les heures répondent encore.
        let old = bench.engine.usage(from: noon, to: noon.addingTimeInterval(day))
        XCTAssertEqual(old.receivedBytes, 10 * 2_500_000)
        XCTAssertEqual(old.averageDownloadBps, 20_000_000)

        bench.clock.advance(40 * day)
        bench.rebase()
        bench.measure(seconds: 61, down: 20, up: 4)
        let older = bench.engine.usage(from: noon.addingTimeInterval(-12 * hour), to: noon.addingTimeInterval(12 * hour))
        XCTAssertEqual(older.receivedBytes, 10 * 2_500_000, "au-delà de 30 jours : les jours")
    }

    func testAClockSetBackStillFilesMeasuresInTheRightPeriod() {
        let bench = Bench(counterWidth: .bits64).started()
        bench.clock.advance(10 * minute)
        bench.rebase()
        bench.measure(seconds: 5, down: 10, up: 1)
        // L'utilisateur recule l'heure de cinq minutes.
        bench.clock.advance(-5 * minute)
        bench.rebase()
        bench.measure(seconds: 5, down: 10, up: 1)
        let minutes = bench.engine.history(from: noon, to: noon.addingTimeInterval(hour), step: .minute)
        XCTAssertEqual(minutes.map(\.start), minutes.map(\.start).sorted(), "toujours triées")
        XCTAssertEqual(minutes.map(\.sampleCount).reduce(0, +), 10)
        XCTAssertEqual(
            bench.engine.history(from: noon, to: noon.addingTimeInterval(hour), step: .hour)[0].sampleCount,
            10)
    }
}

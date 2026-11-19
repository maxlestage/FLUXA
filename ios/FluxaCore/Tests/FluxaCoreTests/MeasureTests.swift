import XCTest

@testable import FluxaCore

final class MeasureTests: XCTestCase {
    func testComputesTheRateFromTheFormula() {
        // (octets2 − octets1) × 8 / (t2 − t1), sur deux interfaces cellulaires.
        let bench = Bench()
        bench.engine.updatePath(kind: .cellular, isOnline: true)
        bench.engine.start()
        let first = bench.engine.ingest([
            wifi(1_000, 1_000), cellular(10_000, 2_000), cellular(500, 500, name: "pdp_ip1"),
        ])
        XCTAssertNil(first.downloadBps, "le premier relevé sert de base")
        XCTAssertNil(first.measuredAt)

        bench.clock.advance(1)
        let second = bench.engine.ingest([
            wifi(9_001_000, 1_000), cellular(5_010_000, 1_002_000),
            cellular(350_500, 50_500, name: "pdp_ip1"),
        ])
        XCTAssertEqual(second.downloadBps, 42_800_000)
        XCTAssertEqual(second.uploadBps, 8_400_000)
        XCTAssertEqual(second.measuredAt, bench.clock.date)
        XCTAssertEqual(second.receivedBytesToday, 5_350_000, "le Wi-Fi ne compte pas")
        XCTAssertEqual(second.sentBytesToday, 1_050_000)
        XCTAssertEqual(second.kind, .cellular)
        XCTAssertTrue(second.isOnline && second.isMonitoring)
    }

    func testHalfSecondIntervalsGiveTheSameRate() {
        let bench = Bench(counterWidth: .bits64)
        bench.engine.updatePath(kind: .wifi, isOnline: true)
        bench.engine.start()
        bench.engine.ingest([wifi(0, 0)])
        bench.clock.advance(0.5)
        XCTAssertEqual(bench.engine.ingest([wifi(125_000, 0)]).downloadBps, 2_000_000)
    }

    func testNothingIsMeasuredWhileStopped() {
        let bench = Bench()
        bench.engine.updatePath(kind: .cellular, isOnline: true)
        bench.engine.ingest([cellular(0, 0)])
        bench.clock.advance(1)
        let snapshot = bench.engine.ingest([cellular(1_000_000, 1_000_000)])
        XCTAssertFalse(snapshot.isMonitoring)
        XCTAssertNil(snapshot.downloadBps)
        XCTAssertEqual(snapshot.receivedBytesToday, 0)
        bench.engine.recordLatency(20)
        XCTAssertNil(bench.engine.snapshot.latencyMs, "une valeur absente reste absente")
        XCTAssertTrue(bench.engine.recentSamples.isEmpty)
        XCTAssertEqual(bench.engine.diagnostics().minuteAggregates, 0)
    }

    func testNothingIsMeasuredWithoutANetwork() {
        let bench = Bench()
        bench.engine.start()
        bench.engine.ingest([cellular(0, 0)])
        bench.clock.advance(1)
        XCTAssertNil(bench.engine.ingest([cellular(1_000, 1_000)]).downloadBps, "hors ligne")

        // Wi-Fi actif, mais aucune interface de cette famille dans le relevé.
        bench.engine.updatePath(kind: .wifi, isOnline: true)
        bench.clock.advance(1)
        XCTAssertNil(bench.engine.ingest([cellular(2_000, 2_000)]).downloadBps)
        XCTAssertEqual(bench.engine.snapshot.receivedBytesToday, 0)
    }

    func testStopForgetsTheBaseline() {
        let bench = Bench().started()
        bench.measure(seconds: 3, down: 10, up: 1)
        bench.engine.recordLatency(20)
        bench.engine.stop()
        bench.engine.stop()  // sans effet
        XCTAssertFalse(bench.engine.isMonitoring)
        XCTAssertNil(bench.engine.snapshot.downloadBps)
        XCTAssertNil(bench.engine.snapshot.latencyMs)

        // Dix secondes plus tard : ce relevé ne doit pas être comparé à l'ancien.
        bench.clock.advance(10)
        bench.engine.start()
        bench.engine.start()  // sans effet
        bench.received += 900_000_000
        XCTAssertNil(bench.engine.ingest([cellular(bench.received, bench.sent)]).downloadBps)
        XCTAssertEqual(bench.engine.snapshot.receivedBytesToday, 3 * 1_250_000)
    }

    func testAWrappingCounterProducesNoSpike() {
        let bench = Bench()
        bench.engine.updatePath(kind: .cellular, isOnline: true)
        bench.engine.start()
        bench.engine.ingest([cellular(UInt64(UInt32.max) - 999, 0)])
        bench.clock.advance(1)
        let snapshot = bench.engine.ingest([cellular(4_000, 0)])
        XCTAssertEqual(snapshot.downloadBps, 40_000, "5 000 octets en une seconde")
    }

    func testAResetCounterProducesNoSpike() {
        let bench = Bench().started()
        bench.measure(seconds: 2, down: 10, up: 1)
        bench.clock.advance(1)
        // L'interface a redémarré : ses compteurs repartent de zéro.
        let snapshot = bench.engine.ingest([cellular(300, 200)])
        XCTAssertNil(snapshot.downloadBps)
        XCTAssertEqual(snapshot.receivedBytesToday, 2 * 1_250_000)
        bench.clock.advance(1)
        XCTAssertEqual(bench.engine.ingest([cellular(125_300, 200)]).downloadBps, 1_000_000)
        let peak = bench.engine.history(from: noon, to: noon.addingTimeInterval(hour), step: .hour)
            .first?.peakDownloadBps
        XCTAssertEqual(peak, 10_000_000)
    }

    func testALongSuspensionProducesNoSample() {
        let bench = Bench().started()
        bench.measure(seconds: 2, down: 10, up: 1)
        bench.clock.advance(2 * hour)
        bench.received += 3_000_000_000
        let snapshot = bench.engine.ingest([cellular(bench.received, bench.sent)])
        XCTAssertNil(snapshot.downloadBps, "pas de débit moyen sur deux heures, ni l'ancien débit")
        XCTAssertNil(snapshot.measuredAt)
        XCTAssertEqual(bench.engine.snapshot.receivedBytesToday, 2 * 1_250_000)
    }

    func testLatencyJitterAndLossAppearInTheSnapshot() {
        let bench = Bench().started()
        for probe in [20, 30, nil, 26] as [Double?] {
            bench.engine.recordLatency(probe)
        }
        var snapshot = bench.engine.snapshot
        XCTAssertEqual(snapshot.latencyMs, 26)
        XCTAssertEqual(snapshot.jitterMs ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(snapshot.packetLossPercent, 25, "de 0 à 100")

        // Un changement de réseau efface les mesures de l'ancien.
        bench.measure(seconds: 1, down: 10, up: 1)
        bench.engine.updatePath(kind: .wifi, isOnline: true)
        snapshot = bench.engine.snapshot
        XCTAssertEqual(snapshot.kind, .wifi)
        XCTAssertNil(snapshot.latencyMs)
        XCTAssertNil(snapshot.packetLossPercent)
        XCTAssertNil(snapshot.downloadBps)
        // Le même réseau signalé de nouveau ne change rien.
        bench.engine.recordLatency(12)
        bench.engine.updatePath(kind: .wifi, isOnline: false)
        XCTAssertEqual(bench.engine.snapshot.latencyMs, 12)
        XCTAssertFalse(bench.engine.snapshot.isOnline)
    }

    func testTheLatencyWindowSlides() {
        let bench = Bench().started()
        bench.engine.recordLatency(nil)
        for _ in 0..<FluxaEngine.latencyProbes {
            bench.engine.recordLatency(15)
        }
        XCTAssertEqual(bench.engine.snapshot.packetLossPercent, 0)
        XCTAssertEqual(bench.engine.snapshot.jitterMs, 0)
    }

    func testRecentSamplesCoverTheLastMinute() {
        let bench = Bench().started()
        bench.measure(seconds: 90, down: 20, up: 4)
        let samples = bench.engine.recentSamples
        XCTAssertEqual(samples.count, 60)
        XCTAssertEqual(samples.first?.date, bench.clock.date.addingTimeInterval(-59))
        XCTAssertEqual(samples.last?.date, bench.clock.date)
        XCTAssertEqual(samples.last?.downloadBps, 20_000_000)
        XCTAssertEqual(samples.last?.uploadBps, 4_000_000)
        XCTAssertEqual(samples.map(\.date), samples.map(\.date).sorted())

        // Sans nouveau relevé, la courbe se vide avec le temps.
        bench.clock.advance(30)
        XCTAssertEqual(bench.engine.recentSamples.count, 30)
        bench.clock.advance(31)
        XCTAssertTrue(bench.engine.recentSamples.isEmpty)
    }

    func testTodayTotalsRestartAtMidnight() {
        // 23 h 59 min 50 s UTC.
        let clock = TestClock(noon.addingTimeInterval(12 * hour - 10))
        let bench = Bench(clock: clock).started()
        bench.measure(seconds: 5, down: 8, up: 4)
        XCTAssertEqual(bench.engine.snapshot.receivedBytesToday, 5_000_000)
        XCTAssertEqual(bench.engine.snapshot.sentBytesToday, 2_500_000)

        bench.measure(seconds: 10, down: 8, up: 4)  // jusqu'à 00 h 00 min 05 s
        XCTAssertEqual(bench.engine.snapshot.receivedBytesToday, 5_000_000, "depuis minuit seulement")
        XCTAssertEqual(bench.engine.snapshot.sentBytesToday, 2_500_000)

        // Sans mesure, le cumul retombe à zéro au changement de jour.
        clock.advance(day)
        XCTAssertEqual(bench.engine.snapshot.receivedBytesToday, 0)
    }

    func testMidnightFollowsTheCalendar() {
        // 23 h 30 UTC : déjà le lendemain à UTC+1.
        let clock = TestClock(noon.addingTimeInterval(11 * hour + 29 * minute))
        let bench = Bench(clock: clock, calendar: calendar(utcOffsetSeconds: 3_600)).started()
        bench.measure(seconds: 120, down: 8, up: 0)  // de 23 h 29 à 23 h 31 UTC
        XCTAssertEqual(bench.engine.snapshot.receivedBytesToday, 60 * 1_000_000)
    }

    func testTodayTotalsSurviveARestart() throws {
        let store = MemoryStore()
        let clock = TestClock()
        let bench = Bench(store: store, clock: clock).started()
        bench.measure(seconds: 10, down: 8, up: 4)
        try bench.engine.flush()

        clock.advance(hour)
        let reopened = FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
        XCTAssertEqual(reopened.snapshot.receivedBytesToday, 10_000_000)
        XCTAssertEqual(reopened.snapshot.sentBytesToday, 5_000_000)
        XCTAssertNil(reopened.snapshot.downloadBps, "le débit, lui, ne se garde pas")
        XCTAssertFalse(reopened.isMonitoring)
    }
}

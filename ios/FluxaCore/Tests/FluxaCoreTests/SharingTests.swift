import XCTest

@testable import FluxaCore

private let boot = noon.addingTimeInterval(-3 * day)

/// Les sessions de partage de connexion, vues par l'interface de pont du système.
final class SharingTests: XCTestCase {
    /// Un moteur sur le réseau mobile, dont le relevé de base porte déjà le pont.
    private func sharing(store: any EngineStore = MemoryStore()) -> Bench {
        let bench = Bench(store: store)
        bench.engine.updatePath(kind: .cellular, isOnline: true)
        bench.engine.start()
        bench.engine.ingest([cellular(0, 0), bridge(0, 0)], bootTime: boot)
        return bench
    }

    func testASessionStartsWithTheBridgeAndEndsWithIt() {
        let bench = Bench()
        let engine = bench.engine
        engine.updatePath(kind: .cellular, isOnline: true)
        engine.start()
        engine.ingest([cellular(0, 0)], bootTime: boot)
        XCTAssertNil(engine.sharingStatus)

        // Le pont apparaît : la session commence, sans débit encore.
        bench.clock.advance(1)
        engine.ingest([cellular(0, 0), bridge(400, 900)], bootTime: boot)
        XCTAssertEqual(
            engine.sharingStatus,
            SharingStatus(
                session: SharingSession(
                    id: 1, start: noon.addingTimeInterval(1), end: noon.addingTimeInterval(1), toDevicesBytes: 0,
                    fromDevicesBytes: 0, isLowerBound: false),
                toDevicesBps: nil, fromDevicesBps: nil))

        // Le pont envoie vers les appareils reliés et reçoit d'eux.
        bench.clock.advance(1)
        engine.ingest([cellular(0, 0), bridge(1_400, 8_900)], bootTime: boot)
        bench.clock.advance(2)
        engine.ingest([cellular(0, 0), bridge(3_400, 28_900)], bootTime: boot)
        let status = engine.sharingStatus
        XCTAssertEqual(status?.toDevicesBps, 80_000)
        XCTAssertEqual(status?.fromDevicesBps, 8_000)
        XCTAssertEqual(status?.session.toDevicesBytes, 28_000)
        XCTAssertEqual(status?.session.fromDevicesBytes, 3_000)
        XCTAssertEqual(status?.session.totalBytes, 31_000)
        XCTAssertEqual(status?.session.duration, 3)
        XCTAssertEqual(status?.session.isLowerBound, false)
        XCTAssertTrue(engine.sharingSessions(limit: 5).isEmpty, "la session en cours n'est pas terminée")

        // Le pont disparaît : la session se termine à son dernier relevé.
        bench.clock.advance(1)
        engine.ingest([cellular(0, 0)], bootTime: boot)
        XCTAssertNil(engine.sharingStatus)
        XCTAssertEqual(
            engine.sharingSessions(limit: 5),
            [
                SharingSession(
                    id: 1, start: noon.addingTimeInterval(1), end: noon.addingTimeInterval(4),
                    toDevicesBytes: 28_000, fromDevicesBytes: 3_000, isLowerBound: false)
            ])

        // Un nouveau partage : une nouvelle session.
        bench.clock.advance(60)
        engine.ingest([cellular(0, 0), bridge(0, 0)], bootTime: boot)
        XCTAssertEqual(engine.sharingStatus?.session.id, 2)
        XCTAssertEqual(engine.sharingStatus?.session.start, noon.addingTimeInterval(65))
        XCTAssertTrue(engine.sharingSessions(limit: 0).isEmpty)
        let messages = engine.diagnostics().events.map(\.message)
        XCTAssertEqual(messages.filter { $0 == "Partage de connexion détecté." }.count, 2)
        XCTAssertEqual(messages.filter { $0 == "Partage de connexion : session terminée." }.count, 1)
    }

    func testTheBridgeNeverEntersTheThroughputOrTheHistory() {
        let bench = sharing()
        let engine = bench.engine
        for second in 1...5 {
            bench.clock.advance(1)
            engine.ingest(
                [cellular(UInt64(second) * 1_000, 0), bridge(UInt64(second) * 50_000, UInt64(second) * 700_000)],
                bootTime: boot)
        }
        XCTAssertEqual(engine.snapshot.downloadBps, 8_000, "le débit est celui du réseau mobile seul")
        XCTAssertEqual(engine.snapshot.uploadBps, 0)
        XCTAssertEqual(engine.snapshot.receivedBytesToday, 5_000)
        XCTAssertEqual(engine.snapshot.sentBytesToday, 0)
        XCTAssertEqual(engine.usage(from: .distantPast, to: .distantFuture).receivedBytes, 5_000)
        XCTAssertEqual(engine.usageByNetwork(from: .distantPast, to: .distantFuture).map(\.kind), [.cellular])
        XCTAssertEqual(engine.sharingStatus?.session.toDevicesBytes, 3_500_000)

        // Même sans réseau actif, la session suit le pont.
        engine.updatePath(kind: .offline, isOnline: false)
        bench.clock.advance(1)
        engine.ingest([cellular(6_000, 0), bridge(300_000, 4_200_000)], bootTime: boot)
        XCTAssertNil(engine.snapshot.downloadBps)
        XCTAssertEqual(engine.sharingStatus?.session.toDevicesBytes, 4_200_000)
        XCTAssertEqual(engine.sharingStatus?.toDevicesBps, 5_600_000)
    }

    func testASessionContinuesAcrossAStopOnTheSameBoot() {
        let bench = sharing()
        let engine = bench.engine
        bench.clock.advance(1)
        engine.ingest([cellular(0, 0), bridge(1_000, 8_000)], bootTime: boot)

        engine.stop()
        XCTAssertNil(engine.sharingStatus, "mesure arrêtée")
        XCTAssertTrue(engine.sharingSessions(limit: 5).isEmpty, "l'arrêt ne termine pas la session")
        bench.clock.advance(10 * minute)
        engine.start()
        XCTAssertNil(engine.sharingStatus, "pas encore de relevé")
        engine.ingest([cellular(0, 0), bridge(6_000, 78_000)], bootTime: boot)

        XCTAssertEqual(
            engine.sharingStatus,
            SharingStatus(
                session: SharingSession(
                    id: 1, start: noon, end: noon.addingTimeInterval(601), toDevicesBytes: 78_000,
                    fromDevicesBytes: 6_000, isLowerBound: true),
                toDevicesBps: nil, fromDevicesBps: nil))
        XCTAssertTrue(engine.sharingSessions(limit: 5).isEmpty)
        XCTAssertNil(engine.lastAbsence, "le pont n'est pas une absence")

        // Le direct reprend ; le volume reste un minimum.
        bench.clock.advance(1)
        engine.ingest([cellular(0, 0), bridge(6_500, 79_000)], bootTime: boot)
        XCTAssertEqual(engine.sharingStatus?.toDevicesBps, 8_000)
        XCTAssertEqual(engine.sharingStatus?.session.toDevicesBytes, 79_000)
        XCTAssertEqual(engine.sharingStatus?.session.isLowerBound, true)

        // Un pont recréé pendant l'interruption : ses compteurs repartent, la borne basse vaut.
        engine.stop()
        bench.clock.advance(hour)
        engine.start()
        engine.ingest([cellular(0, 0), bridge(200, 3_000)], bootTime: boot)
        XCTAssertEqual(engine.sharingStatus?.session.toDevicesBytes, 82_000)
        XCTAssertEqual(engine.sharingStatus?.session.fromDevicesBytes, 6_700)
    }

    func testASessionEndsAtItsLastReadingWhenItCannotBeResumed() {
        // L'appareil a redémarré : le pont du moment ouvre une autre session.
        let rebooted = sharing()
        rebooted.clock.advance(1)
        rebooted.engine.ingest([cellular(0, 0), bridge(1_000, 8_000)], bootTime: boot)
        rebooted.engine.stop()
        rebooted.clock.advance(hour)
        rebooted.engine.start()
        rebooted.engine.ingest([cellular(0, 0), bridge(50, 60)], bootTime: boot.addingTimeInterval(1_800))
        XCTAssertEqual(
            rebooted.engine.sharingSessions(limit: 5),
            [
                SharingSession(
                    id: 1, start: noon, end: noon.addingTimeInterval(1), toDevicesBytes: 8_000,
                    fromDevicesBytes: 1_000, isLowerBound: false)
            ])
        XCTAssertEqual(
            rebooted.engine.sharingStatus?.session,
            SharingSession(
                id: 2, start: noon.addingTimeInterval(3_601), end: noon.addingTimeInterval(3_601),
                toDevicesBytes: 0, fromDevicesBytes: 0, isLowerBound: false))

        // Le partage a été coupé pendant l'interruption.
        let cut = sharing()
        cut.clock.advance(1)
        cut.engine.ingest([cellular(0, 0), bridge(1_000, 8_000)], bootTime: boot)
        cut.engine.stop()
        cut.clock.advance(hour)
        cut.engine.start()
        cut.engine.ingest([cellular(0, 0)], bootTime: boot)
        XCTAssertNil(cut.engine.sharingStatus)
        XCTAssertEqual(cut.engine.sharingSessions(limit: 5).map(\.end), [noon.addingTimeInterval(1)])

        // Sans heure de démarrage, rien ne dit que c'est le même partage.
        let unknown = sharing()
        unknown.engine.stop()
        unknown.clock.advance(hour)
        unknown.engine.start()
        unknown.engine.ingest([cellular(0, 0), bridge(9_000, 9_000)])
        XCTAssertEqual(unknown.engine.sharingSessions(limit: 5).map(\.id), [1])
        XCTAssertEqual(unknown.engine.sharingStatus?.session.id, 2)
        XCTAssertEqual(unknown.engine.sharingStatus?.session.totalBytes, 0)
    }

    func testASessionSurvivesAClosedApp() throws {
        let store = MemoryStore()
        let first = sharing(store: store)
        first.clock.advance(1)
        first.engine.ingest([cellular(0, 0), bridge(1_000, 8_000)], bootTime: boot)
        first.engine.stop()

        let clock = TestClock(noon.addingTimeInterval(30 * minute))
        let engine = FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
        XCTAssertNil(engine.sharingStatus)
        engine.updatePath(kind: .cellular, isOnline: true)
        engine.start()
        engine.ingest([cellular(0, 0), bridge(4_000, 20_000)], bootTime: boot)
        XCTAssertEqual(
            engine.sharingStatus?.session,
            SharingSession(
                id: 1, start: noon, end: clock.date, toDevicesBytes: 20_000, fromDevicesBytes: 4_000,
                isLowerBound: true))
    }

    func testOnlyTheMostRecentSessionsAreKept() {
        let bench = Bench()
        let engine = bench.engine
        engine.updatePath(kind: .cellular, isOnline: true)
        engine.start()
        engine.ingest([cellular(0, 0)], bootTime: boot)
        for _ in 0..<(FluxaEngine.sharingSessionCapacity + 3) {
            bench.clock.advance(1)
            engine.ingest([cellular(0, 0), bridge(0, 0)], bootTime: boot)
            bench.clock.advance(1)
            engine.ingest([cellular(0, 0)], bootTime: boot)
        }
        let sessions = engine.sharingSessions(limit: 1_000)
        XCTAssertEqual(sessions.count, FluxaEngine.sharingSessionCapacity)
        XCTAssertEqual(sessions.first?.id, FluxaEngine.sharingSessionCapacity + 3, "de la plus récente…")
        XCTAssertEqual(sessions.last?.id, 4, "… à la plus ancienne gardée")
        XCTAssertEqual(engine.sharingSessions(limit: 2).map(\.id), [103, 102])
    }

    func testErasingTheHistoryErasesTheSessions() throws {
        let bench = sharing()
        let engine = bench.engine
        bench.clock.advance(1)
        engine.ingest([cellular(0, 0)], bootTime: boot)
        bench.clock.advance(1)
        engine.ingest([cellular(0, 0), bridge(0, 0)], bootTime: boot)
        bench.clock.advance(1)
        engine.ingest([cellular(0, 0), bridge(700, 900)], bootTime: boot)
        XCTAssertEqual(engine.sharingSessions(limit: 5).count, 1)
        XCTAssertEqual(engine.sharingStatus?.session.totalBytes, 1_600)

        try engine.eraseHistory()
        XCTAssertTrue(engine.sharingSessions(limit: 5).isEmpty)
        XCTAssertNil(engine.sharingStatus)
        // Le partage continue : une session neuve, sans le volume d'avant.
        bench.clock.advance(1)
        engine.ingest([cellular(0, 0), bridge(800, 1_900)], bootTime: boot)
        XCTAssertEqual(
            engine.sharingStatus?.session,
            SharingSession(
                id: 3, start: noon.addingTimeInterval(4), end: noon.addingTimeInterval(4),
                toDevicesBytes: 1_000, fromDevicesBytes: 100, isLowerBound: false))
    }
}

/// La recherche dichotomique des suites triées.
final class SeriesSearchTests: XCTestCase {
    // `FluxaCore.Measurement` : Foundation a aussi un type de ce nom.
    private func measurement(_ bytes: UInt64) -> FluxaCore.Measurement {
        FluxaCore.Measurement(date: noon, seconds: 1, receivedBytes: bytes, sentBytes: 0)
    }

    func testPartitionIndexFindsTheFirstMatch() {
        XCTAssertEqual([Int]().partitionIndex { $0 >= 3 }, 0)
        XCTAssertEqual([1, 2, 3, 3, 5].partitionIndex { $0 >= 3 }, 2)
        XCTAssertEqual([1, 2, 3, 3, 5].partitionIndex { $0 >= 0 }, 0)
        XCTAssertEqual([1, 2, 3, 3, 5].partitionIndex { $0 >= 6 }, 5)
        XCTAssertEqual([4].partitionIndex { $0 >= 4 }, 0)
        XCTAssertEqual([4].partitionIndex { $0 > 4 }, 1)
    }

    func testSliceAndRemovalMatchAFullScan() {
        // Des débuts irréguliers, avec des trous ; toutes les bornes possibles autour.
        let starts = [0, 60, 120, 300, 360, 1_000, 1_060].map { noon.addingTimeInterval($0) }
        var series = BucketSeries()
        for (index, start) in starts.enumerated() {
            series.add(measurement(UInt64(index + 1)), at: start)
        }
        let bounds = stride(from: -60.0, through: 1_120, by: 30).map { noon.addingTimeInterval($0) }
            + [.distantPast, .distantFuture]
        for from in bounds {
            for to in bounds {
                let expected = series.buckets.filter { $0.start >= from && $0.start < to }
                XCTAssertEqual(series.slice(from: from, to: to), expected, "de \(from) à \(to)")
            }
            var pruned = series
            let kept = series.buckets.filter { $0.start >= from }
            XCTAssertEqual(pruned.removeAll(before: from), series.count - kept.count)
            XCTAssertEqual(pruned.buckets, kept)
        }
        XCTAssertTrue(BucketSeries().slice(from: .distantPast, to: .distantFuture).isEmpty)
    }

    func testAMeasureFromThePastFindsItsPeriod() {
        // L'horloge a reculé : la mesure rejoint sa période, ou en crée une à sa place.
        var series = BucketSeries()
        for offset in [0.0, 60, 180] {
            series.add(measurement(1), at: noon.addingTimeInterval(offset))
        }
        series.add(measurement(10), at: noon.addingTimeInterval(60))
        series.add(measurement(100), at: noon.addingTimeInterval(120))
        series.add(measurement(1_000), at: noon.addingTimeInterval(-60))
        XCTAssertEqual(series.buckets.map(\.start), [-60.0, 0, 60, 120, 180].map { noon.addingTimeInterval($0) })
        XCTAssertEqual(series.buckets.map(\.receivedBytes), [1_000, 1, 11, 100, 1])
        XCTAssertEqual(series.buckets.map(\.sampleCount), [1, 1, 2, 1, 1])
    }

    func testTheNetworkSeriesKeepsOneEntryPerPeriodAndNetwork() {
        var series = NetworkSeries()
        let later = noon.addingTimeInterval(hour)
        series.add(kind: .wifi, receivedBytes: 10, sentBytes: 1, at: noon)
        series.add(kind: .cellular, receivedBytes: 20, sentBytes: 2, at: noon)
        series.add(kind: .wifi, receivedBytes: 5, sentBytes: 5, at: noon)
        series.add(kind: .wired, receivedBytes: 7, sentBytes: 0, at: later)
        series.add(kind: .cellular, receivedBytes: 1, sentBytes: 1, at: later)
        // L'horloge a reculé : l'entrée rejoint sa période.
        series.add(kind: .cellular, receivedBytes: 100, sentBytes: 0, at: noon)
        series.add(kind: .other, receivedBytes: 3, sentBytes: 0, at: noon.addingTimeInterval(-hour))

        XCTAssertEqual(
            series.buckets,
            [
                NetworkBucket(start: noon.addingTimeInterval(-hour), kind: .other, receivedBytes: 3, sentBytes: 0),
                NetworkBucket(start: noon, kind: .cellular, receivedBytes: 120, sentBytes: 2),
                NetworkBucket(start: noon, kind: .wifi, receivedBytes: 15, sentBytes: 6),
                NetworkBucket(start: later, kind: .cellular, receivedBytes: 1, sentBytes: 1),
                NetworkBucket(start: later, kind: .wired, receivedBytes: 7, sentBytes: 0),
            ])
        XCTAssertEqual(NetworkSeries(buckets: series.buckets.reversed()), series, "l'ordre lu n'importe pas")
        XCTAssertEqual(series.slice(from: noon, to: later).map(\.kind), [.cellular, .wifi])
        XCTAssertTrue(series.slice(from: later, to: noon).isEmpty)
        XCTAssertEqual(series.removeAll(before: later), 3)
        XCTAssertEqual(series.count, 2)

        let data = try? JSONEncoder().encode(series)
        XCTAssertEqual(try data.map { try JSONDecoder().decode(NetworkSeries.self, from: $0) }, series)
    }
}

import XCTest

@testable import FluxaCore

/// L'iPhone a démarré trois jours avant le 1er mars.
private let boot = noon.addingTimeInterval(-3 * day)

func bridge(_ fromDevices: UInt64, _ toDevices: UInt64, name: String = "bridge100") -> InterfaceReading {
    InterfaceReading(name: name, kind: .sharing, receivedBytes: fromDevices, sentBytes: toDevices)
}

/// Le rattrapage : ce que les compteurs du système ont avancé pendant que l'app ne mesurait pas.
final class CatchUpTests: XCTestCase {
    /// Un moteur qui mesure sur le réseau mobile, relevé de base posé avec l'heure de démarrage.
    private func bench(_ base: [InterfaceReading], store: any EngineStore = MemoryStore()) -> Bench {
        let bench = Bench(store: store)
        bench.engine.updatePath(kind: .cellular, isOnline: true)
        bench.engine.start()
        bench.engine.ingest(base, bootTime: boot)
        return bench
    }

    /// Arrête la mesure, laisse passer du temps, puis la reprend sur ce relevé.
    private func resume(
        _ bench: Bench, after seconds: TimeInterval, _ readings: [InterfaceReading], bootTime: Date? = boot
    ) {
        bench.engine.stop()
        bench.clock.advance(seconds)
        bench.engine.start()
        bench.engine.ingest(readings, bootTime: bootTime)
    }

    func testCatchesUpWhatWasExchangedWhileTheAppWasNotMeasuring() {
        let bench = bench([cellular(1_000, 500), wifi(10_000, 2_000)])
        let engine = bench.engine
        XCTAssertNil(engine.lastAbsence, "le tout premier relevé n'a rien à rattraper")
        bench.clock.advance(1)
        engine.ingest([cellular(2_000, 700), wifi(10_000, 2_000)], bootTime: boot)
        XCTAssertEqual(engine.snapshot.receivedBytesToday, 1_000)

        // Deux heures plus tard. L'heure de démarrage se relit à quelques secondes près.
        resume(
            bench, after: 2 * hour, [cellular(5_002_000, 300_700), wifi(10_500, 2_000)],
            bootTime: boot.addingTimeInterval(3))
        let expected = AbsenceUsage(
            id: 1, start: noon.addingTimeInterval(1), end: noon.addingTimeInterval(1 + 2 * hour),
            volumes: [
                NetworkVolume(kind: .wifi, receivedBytes: 500, sentBytes: 0),
                NetworkVolume(kind: .cellular, receivedBytes: 5_000_000, sentBytes: 300_000),
            ])
        XCTAssertEqual(engine.lastAbsence, expected)
        XCTAssertEqual(engine.absences(limit: 10), [expected])
        XCTAssertEqual(expected.duration, 2 * hour)
        XCTAssertEqual(expected.totalBytes, 5_300_500)
        XCTAssertEqual(expected.volume(of: .cellular)?.totalBytes, 5_300_000)
        XCTAssertNil(expected.volume(of: .wired))

        // Ni débit ni agrégat : le rattrapage reste à part.
        XCTAssertNil(engine.snapshot.downloadBps)
        XCTAssertEqual(engine.snapshot.receivedBytesToday, 1_000)
        XCTAssertEqual(engine.history(from: .distantPast, to: .distantFuture, step: .minute).count, 1)
        XCTAssertTrue(
            engine.diagnostics().events.contains { $0.message == "Rattrapage : au moins 5,3 Mo hors de l’app." })

        // La mesure en direct reprend au relevé suivant, sans recompter l'absence.
        bench.clock.advance(1)
        engine.ingest([cellular(5_003_000, 300_700), wifi(10_500, 2_000)], bootTime: boot)
        XCTAssertEqual(engine.snapshot.downloadBps, 8_000)
        XCTAssertEqual(engine.snapshot.receivedBytesToday, 2_000)
        XCTAssertEqual(engine.absences(limit: 10), [expected])
        XCTAssertTrue(engine.absences(limit: 0).isEmpty)
    }

    func testNothingIsCaughtUpAcrossARestartOfTheDevice() {
        let bench = bench([cellular(1_000_000, 1_000_000)])
        // Les compteurs sont repartis de zéro avec l'appareil : ils ne se comparent plus.
        resume(bench, after: hour, [cellular(40_000, 9_000)], bootTime: boot.addingTimeInterval(11))
        XCTAssertNil(bench.engine.lastAbsence)
        XCTAssertTrue(bench.engine.absences(limit: 10).isEmpty)

        // Le relevé de reprise est le nouveau point de reprise.
        resume(bench, after: hour, [cellular(50_000, 9_500)], bootTime: boot.addingTimeInterval(11))
        XCTAssertEqual(
            bench.engine.lastAbsence?.volumes, [NetworkVolume(kind: .cellular, receivedBytes: 10_000, sentBytes: 500)])
    }

    func testNothingIsCaughtUpWithoutTheBootTime() {
        // Absente à la reprise.
        let first = bench([cellular(1_000, 1_000)])
        resume(first, after: hour, [cellular(9_000, 9_000)], bootTime: nil)
        XCTAssertNil(first.engine.lastAbsence)
        // Un relevé sans heure de démarrage ne laisse pas de point de reprise.
        resume(first, after: hour, [cellular(20_000, 20_000)])
        XCTAssertNil(first.engine.lastAbsence)

        // Absente avant l'interruption.
        let second = Bench().started()
        second.measure(seconds: 3, down: 8, up: 0)
        resume(second, after: hour, [cellular(second.received + 5_000, second.sent)])
        XCTAssertNil(second.engine.lastAbsence)
        XCTAssertTrue(second.engine.absences(limit: 10).isEmpty)
    }

    func testACounterThatWentBackCountsForItsNewValueOnly() {
        // Remis à zéro ou débordé de ses 32 bits : au moins sa valeur du moment a passé.
        let bench = bench([cellular(4_000_000_000, 100)])
        resume(bench, after: hour, [cellular(1_000, 50)])
        XCTAssertEqual(
            bench.engine.lastAbsence?.volumes, [NetworkVolume(kind: .cellular, receivedBytes: 1_000, sentBytes: 50)])

        // Même borne basse avec des compteurs de 64 bits.
        let wide = Bench(counterWidth: .bits64)
        wide.engine.updatePath(kind: .cellular, isOnline: true)
        wide.engine.start()
        wide.engine.ingest([cellular(9_000_000_000, 700)], bootTime: boot)
        resume(wide, after: hour, [cellular(2_000, 900)])
        XCTAssertEqual(
            wide.engine.lastAbsence?.volumes, [NetworkVolume(kind: .cellular, receivedBytes: 2_000, sentBytes: 200)])
    }

    func testAnInterfaceMissingFromTheCheckpointDoesNotCount() {
        let bench = bench([cellular(1_000, 1_000)])
        resume(bench, after: hour, [cellular(1_500, 1_000), wifi(700_000, 80_000)])
        XCTAssertEqual(
            bench.engine.lastAbsence?.volumes, [NetworkVolume(kind: .cellular, receivedBytes: 500, sentBytes: 0)])

        // Rien de commun avec le point de reprise : pas d'absence, et l'ancienne n'est
        // plus « la dernière reprise ».
        resume(bench, after: hour, [cellular(123_456, 7_890, name: "pdp_ip1")])
        XCTAssertNil(bench.engine.lastAbsence)
        XCTAssertEqual(bench.engine.absences(limit: 10).count, 1)
    }

    func testNothingIsCaughtUpWhenTheClockWentBack() {
        let bench = bench([cellular(1_000, 1_000)])
        resume(bench, after: -10, [cellular(9_000, 9_000)])
        XCTAssertNil(bench.engine.lastAbsence)
        resume(bench, after: 0, [cellular(9_500, 9_000)])
        XCTAssertNil(bench.engine.lastAbsence, "aucun temps écoulé")
        XCTAssertTrue(bench.engine.absences(limit: 10).isEmpty)
    }

    func testALongGapWithoutStopIsCaughtUpToo() {
        // L'app a été suspendue sans passer par `stop`.
        let bench = bench([cellular(0, 0)])
        let engine = bench.engine
        bench.clock.advance(1)
        engine.ingest([cellular(1_000, 0)], bootTime: boot)

        // Jusqu'à une minute, le compteur en direct mesure : pas d'absence.
        bench.clock.advance(60)
        engine.ingest([cellular(61_000, 0)], bootTime: boot)
        XCTAssertEqual(engine.snapshot.downloadBps, 8_000)
        XCTAssertNil(engine.lastAbsence)

        bench.clock.advance(61)
        engine.ingest([cellular(1_061_000, 4_000)], bootTime: boot)
        XCTAssertNil(engine.snapshot.downloadBps, "le relevé ne sert que de base")
        XCTAssertEqual(
            engine.lastAbsence,
            AbsenceUsage(
                id: 1, start: noon.addingTimeInterval(61), end: noon.addingTimeInterval(122),
                volumes: [NetworkVolume(kind: .cellular, receivedBytes: 1_000_000, sentBytes: 4_000)]))
        XCTAssertEqual(engine.snapshot.receivedBytesToday, 61_000, "le rattrapage n'entre pas dans les agrégats")

        bench.clock.advance(1)
        engine.ingest([cellular(1_062_000, 4_000)], bootTime: boot)
        XCTAssertEqual(engine.snapshot.downloadBps, 8_000)
        XCTAssertEqual(engine.snapshot.receivedBytesToday, 62_000)
    }

    func testAnAbsenceWithoutVolumeIsNotKept() {
        let bench = bench([cellular(1_000, 1_000), wifi(5, 5)])
        resume(bench, after: hour, [cellular(1_000, 1_000), wifi(5, 5)])
        XCTAssertNil(bench.engine.lastAbsence)
        XCTAssertTrue(bench.engine.absences(limit: 10).isEmpty)
        resume(bench, after: hour, [cellular(1_000, 1_001), wifi(5, 5)])
        XCTAssertEqual(bench.engine.lastAbsence?.id, 1, "un identifiant n'est pris que par une absence gardée")
    }

    func testTheSharingBridgeNeverEntersAnAbsence() {
        let bench = bench([cellular(1_000, 1_000), bridge(10, 10)])
        resume(bench, after: hour, [cellular(1_000, 1_000), bridge(900_000, 7_000_000)])
        XCTAssertNil(bench.engine.lastAbsence, "seul le pont a bougé")
        resume(bench, after: hour, [cellular(3_000, 1_000), bridge(1_900_000, 9_000_000)])
        XCTAssertEqual(
            bench.engine.lastAbsence?.volumes, [NetworkVolume(kind: .cellular, receivedBytes: 2_000, sentBytes: 0)])
    }

    func testBeyondCapacityTheOldestAbsencesMergeAndNoVolumeIsLost() {
        let bench = bench([cellular(0, 0)])
        var received: UInt64 = 0
        for _ in 0..<(FluxaEngine.absenceCapacity + 5) {
            received += 1_000
            resume(bench, after: 100, [cellular(received, 0)])
        }
        let absences = bench.engine.absences(limit: 1_000)
        XCTAssertEqual(absences.count, FluxaEngine.absenceCapacity)
        XCTAssertEqual(absences.reduce(0) { $0 + $1.totalBytes }, received)
        let oldest = absences[absences.count - 1]
        XCTAssertEqual(oldest.id, 1)
        XCTAssertEqual(oldest.start, noon)
        XCTAssertEqual(oldest.end, noon.addingTimeInterval(600), "six absences n'en font plus qu'une")
        XCTAssertEqual(oldest.volumes, [NetworkVolume(kind: .cellular, receivedBytes: 6_000, sentBytes: 0)])
        XCTAssertEqual(absences.first?.id, FluxaEngine.absenceCapacity + 5)
        XCTAssertEqual(bench.engine.lastAbsence, absences.first, "la dernière reprise reste entière")
    }

    func testTheCheckpointSurvivesAClosedApp() throws {
        let store = MemoryStore()
        let first = bench([cellular(1_000, 0)], store: store)
        first.clock.advance(1)
        first.engine.ingest([cellular(2_000, 0)], bootTime: boot)
        first.engine.stop()

        // L'app est fermée, puis relancée une heure après.
        let clock = TestClock(noon.addingTimeInterval(1 + hour))
        let engine = FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
        engine.updatePath(kind: .cellular, isOnline: true)
        engine.start()
        XCTAssertNil(engine.lastAbsence)
        engine.ingest([cellular(802_000, 4_000)], bootTime: boot)
        XCTAssertEqual(
            engine.lastAbsence,
            AbsenceUsage(
                id: 1, start: noon.addingTimeInterval(1), end: clock.date,
                volumes: [NetworkVolume(kind: .cellular, receivedBytes: 800_000, sentBytes: 4_000)]))
        try engine.flush()
        XCTAssertEqual(try store.load()?.absences.count, 1)
    }

    func testAfterACrashEveryByteIsCountedOnce() throws {
        // L'app disparaît sans `stop` : seul l'enregistrement de fin de minute existe.
        let store = MemoryStore()
        let first = bench([cellular(0, 0)], store: store)
        for second in 1...90 {
            first.clock.advance(1)
            first.engine.ingest([cellular(UInt64(second) * 1_000, 0)], bootTime: boot)
        }
        let saved = try XCTUnwrap(try store.load())
        XCTAssertEqual(saved.checkpoint?.date, noon.addingTimeInterval(59), "le point de reprise suit les agrégats")

        let clock = TestClock(noon.addingTimeInterval(700))
        let engine = FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
        engine.updatePath(kind: .cellular, isOnline: true)
        engine.start()
        engine.ingest([cellular(100_000, 0)], bootTime: boot)
        let measured = engine.snapshot.receivedBytesToday
        let caughtUp = try XCTUnwrap(engine.lastAbsence).totalBytes
        XCTAssertEqual(measured, 59_000)
        XCTAssertEqual(caughtUp, 41_000)
        XCTAssertEqual(measured + caughtUp, 100_000, "ni perdu, ni compté deux fois")
    }

    func testErasingTheHistoryNeverBringsBackEarlierVolume() throws {
        // Mesure arrêtée : le point de reprise date d'avant l'effacement.
        let stopped = bench([cellular(1_000, 0)])
        resume(stopped, after: hour, [cellular(5_000, 0)])
        XCTAssertEqual(stopped.engine.absences(limit: 10).count, 1)
        stopped.engine.stop()
        stopped.clock.advance(hour)
        try stopped.engine.eraseHistory()
        XCTAssertTrue(stopped.engine.absences(limit: 10).isEmpty)
        XCTAssertNil(stopped.engine.lastAbsence)
        stopped.clock.advance(hour)
        stopped.engine.start()
        stopped.engine.ingest([cellular(900_000, 0)], bootTime: boot)
        XCTAssertNil(stopped.engine.lastAbsence, "rien d'antérieur à l'effacement ne revient")
        XCTAssertTrue(stopped.engine.usageByNetwork(from: .distantPast, to: .distantFuture).isEmpty)

        // Mesure en cours : le point de reprise est celui du dernier relevé, il reste.
        let running = bench([cellular(1_000, 0)])
        try running.engine.eraseHistory()
        resume(running, after: hour, [cellular(3_000, 0)])
        XCTAssertEqual(running.engine.lastAbsence?.totalBytes, 2_000)

        // Tout effacer : les absences partent aussi, la mesure continue.
        try running.engine.eraseAll()
        XCTAssertTrue(running.engine.absences(limit: 10).isEmpty)
        XCTAssertNil(running.engine.lastAbsence)
    }
}

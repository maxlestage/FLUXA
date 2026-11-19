import XCTest

@testable import FluxaCore

final class MeterTests: XCTestCase {
    private func at(_ seconds: TimeInterval) -> Date { noon.addingTimeInterval(seconds) }

    func testFirstReadingIsOnlyABaseline() {
        var meter = InterfaceMeter(width: .bits64)
        XCTAssertNil(meter.push([wifi(500, 100)], at: at(1)))
        let deltas = meter.push([wifi(1_500, 400)], at: at(2))
        XCTAssertEqual(deltas?.seconds, 1)
        XCTAssertEqual(deltas?.interfaces.first?.receivedBytes, 1_000)
        XCTAssertEqual(deltas?.interfaces.first?.sentBytes, 300)
    }

    func test32BitCounterThatWrapsKeepsCounting() {
        var meter = InterfaceMeter(width: .bits32)
        let nearMaximum = UInt64(UInt32.max) - 999  // à 1 000 octets du débordement
        _ = meter.push([wifi(nearMaximum, 0)], at: at(0))
        let deltas = meter.push([wifi(4_000, 0)], at: at(1))
        XCTAssertEqual(deltas?.interfaces.first?.receivedBytes, 5_000)
    }

    func testCounterResetIsNotMistakenForAWrap() {
        // Le compteur repart de zéro loin du débordement : le débit que supposerait
        // un débordement est invraisemblable.
        var meter = InterfaceMeter(width: .bits32)
        _ = meter.push([wifi(1_000_000, 1_000_000)], at: at(0))
        XCTAssertEqual(meter.push([wifi(200, 100)], at: at(1))?.interfaces, [])
        // Le relevé suivant repart de la nouvelle base.
        let deltas = meter.push([wifi(1_200, 600)], at: at(2))
        XCTAssertEqual(deltas?.interfaces.first?.receivedBytes, 1_000)
        XCTAssertEqual(deltas?.interfaces.first?.sentBytes, 500)
    }

    func test64BitCounterNeverWraps() {
        var meter = InterfaceMeter(width: .bits64)
        _ = meter.push([wifi(UInt64(UInt32.max) - 10, 0)], at: at(0))
        XCTAssertEqual(meter.push([wifi(20, 0)], at: at(1))?.interfaces, [])
    }

    func testValueBeyond32BitsIsAResetForA32BitMeter() {
        var meter = InterfaceMeter(width: .bits32)
        _ = meter.push([wifi(1 << 33, 0)], at: at(0))
        XCTAssertEqual(meter.push([wifi(5, 0)], at: at(1))?.interfaces, [])
    }

    func testClockThatDoesNotAdvanceGivesNoRate() {
        var meter = InterfaceMeter(width: .bits64)
        _ = meter.push([wifi(0, 0)], at: at(5))
        XCTAssertNil(meter.push([wifi(100, 0)], at: at(5)))
        XCTAssertNil(meter.push([wifi(200, 0)], at: at(4)), "horloge qui recule")
        // La base suit quand même : 300 − 200 sur une seconde.
        XCTAssertEqual(meter.push([wifi(300, 0)], at: at(5))?.interfaces.first?.receivedBytes, 100)
    }

    func testLongInterruptionOnlyRebases() {
        var meter = InterfaceMeter(width: .bits32)
        _ = meter.push([wifi(0, 0)], at: at(0))
        XCTAssertNotNil(meter.push([wifi(100, 0)], at: at(60)), "une minute : encore mesurable")
        // Deux heures plus tard, le compteur a pu déborder plusieurs fois.
        XCTAssertNil(meter.push([wifi(900_000_000, 0)], at: at(60 + 7_200)))
        XCTAssertEqual(
            meter.push([wifi(900_001_000, 0)], at: at(60 + 7_201))?.interfaces.first?.receivedBytes,
            1_000)
    }

    func testNewInterfaceWaitsForItsSecondReading() {
        var meter = InterfaceMeter(width: .bits64)
        _ = meter.push([wifi(0, 0)], at: at(0))
        let cell = cellular(7_000_000, 0)
        XCTAssertEqual(
            meter.push([wifi(10, 0), cell], at: at(1))?.interfaces.map(\.name), ["en0"],
            "pdp_ip0 n'a pas encore de base")
        // en0 disparaît puis revient : pas de comparaison avec l'ancien relevé.
        _ = meter.push([cell], at: at(2))
        let deltas = meter.push([wifi(90_000, 0), cell], at: at(3))
        XCTAssertEqual(deltas?.interfaces.map(\.name), ["pdp_ip0"])
        XCTAssertEqual(deltas?.interfaces.first?.receivedBytes, 0)
    }

    func testAnInterfaceListedTwiceCountsOnce() {
        var meter = InterfaceMeter(width: .bits64)
        _ = meter.push([wifi(0, 0), wifi(999, 999)], at: at(0))
        let deltas = meter.push([wifi(100, 50), wifi(5, 5)], at: at(1))
        XCTAssertEqual(deltas?.interfaces.count, 1)
        XCTAssertEqual(deltas?.interfaces.first?.receivedBytes, 100)
    }

    func testResetClearsEverything() {
        var meter = InterfaceMeter(width: .bits64)
        _ = meter.push([wifi(0, 0)], at: at(0))
        meter.reset()
        XCTAssertNil(meter.push([wifi(100, 0)], at: at(1)))
    }
}

final class LatencyWindowTests: XCTestCase {
    func testEmptyWindowReportsNothing() {
        let window = LatencyWindow(capacity: 5)
        XCTAssertNil(window.latest)
        XCTAssertNil(window.average)
        XCTAssertNil(window.jitter)
        XCTAssertNil(window.lossRatio)
    }

    func testComputesLatencyJitterAndLoss() {
        var window = LatencyWindow(capacity: 10)
        for probe in [20, 30, nil, 24, 28] as [Double?] {
            window.push(probe)
        }
        XCTAssertEqual(window.latest, 28)
        XCTAssertEqual(window.average, 25.5)
        // |30−20| + |24−30| + |28−24| = 20, sur 3 écarts.
        XCTAssertEqual(window.jitter ?? 0, 20.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(window.lossRatio, 0.2)
    }

    func testOneAnswerIsNotEnoughForJitter() {
        var window = LatencyWindow(capacity: 4)
        window.push(nil)
        window.push(18)
        XCTAssertNil(window.jitter)
        XCTAssertEqual(window.latest, 18)
        XCTAssertEqual(window.lossRatio, 0.5)
    }

    func testAllProbesLost() {
        var window = LatencyWindow(capacity: 3)
        window.push(nil)
        window.push(nil)
        XCTAssertNil(window.latest)
        XCTAssertEqual(window.lossRatio, 1)
    }

    func testKeepsOnlyTheMostRecentProbes() {
        var window = LatencyWindow(capacity: 3)
        for probe in [nil, 100, 10, 12, 14] as [Double?] {
            window.push(probe)
        }
        XCTAssertEqual(window.lossRatio, 0)
        XCTAssertEqual(window.average, 12)
        XCTAssertEqual(window.jitter, 2)
    }

    func testInvalidValuesCountAsLost() {
        var window = LatencyWindow(capacity: 4)
        window.push(.nan)
        window.push(-5)
        window.push(.infinity)
        window.push(15)
        XCTAssertEqual(window.lossRatio, 0.75)
        XCTAssertEqual(window.latest, 15)
    }
}

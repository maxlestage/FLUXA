import CoreTelephony
import FluxaCore
import XCTest

@testable import Fluxa

/// L'écriture des mesures et les petites règles de l'interface.
@MainActor
final class FormatTests: XCTestCase {
    private let space = "\u{00A0}"

    func testAMissingMeasureIsADashNeverAZero() {
        XCTAssertEqual(Format.rate(nil), "—")
        XCTAssertEqual(Format.rateParts(nil).value, "—")
        XCTAssertEqual(Format.milliseconds(nil), "—")
        XCTAssertEqual(Format.percent(nil), "—")
    }

    func testRatesAreWrittenTheFrenchWay() {
        XCTAssertEqual(Format.rate(42_800_000), "42,8\(space)Mb/s")
        XCTAssertEqual(Format.rate(0), "0,0\(space)Mb/s")
        XCTAssertEqual(Format.rateParts(50_000).unit, "kb/s")
        XCTAssertEqual(Format.rateParts(50_000).value, "50")
        XCTAssertEqual(Format.rateParts(800).unit, "b/s")
    }

    func testCapsShowTheirRateOrTheirAbsence() {
        XCTAssertEqual(Format.cap(25_000_000), "25\(space)Mb/s")
        XCTAssertEqual(Format.cap(500_000), "0,5\(space)Mb/s")
        XCTAssertEqual(Format.cap(nil), "Sans plafond")
    }

    func testVolumesUseDecimalUnits() {
        XCTAssertEqual(Format.bytes(0), "0\(space)o")
        XCTAssertEqual(Format.bytes(999), "999\(space)o")
        XCTAssertEqual(Format.bytes(2_500_000), "2,5\(space)Mo")
        XCTAssertEqual(Format.bytes(1_200_000_000), "1,20\(space)Go")
    }

    func testDurations() {
        XCTAssertEqual(Format.milliseconds(17.4), "17\(space)ms")
        XCTAssertEqual(Format.duration(seconds: 900), "15\(space)min")
        XCTAssertEqual(Format.duration(seconds: 28_800), "8\(space)h")
        XCTAssertEqual(Format.duration(seconds: nil), "Sans limite de temps")
    }

    func testTheLimiterScaleRunsFromATenthToAThousand() {
        XCTAssertEqual(LimiterView.mbps(at: 0), 0.1, accuracy: 1e-9)
        XCTAssertEqual(LimiterView.mbps(at: 1), 1_000, accuracy: 1e-6)
        XCTAssertEqual(LimiterView.mbps(at: LimiterView.position(forMbps: 25)), 25, accuracy: 1e-6)
        XCTAssertEqual(LimiterView.mbps(at: LimiterView.position(forMbps: 0.5)), 0.5, accuracy: 1e-9)
        // Hors de l'échelle, le curseur reste sur ses bornes.
        XCTAssertEqual(LimiterView.mbps(at: -1), 0.1, accuracy: 1e-9)
        XCTAssertEqual(LimiterView.mbps(at: 2), 1_000, accuracy: 1e-6)
        var previous = 0.0
        for step in 0...100 {
            let value = LimiterView.mbps(at: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertNoThrow(try FluxaEngine(store: MemoryStore()).validate(
                BandwidthPolicy(downloadBps: Limits.bps(fromMbps: value))
            ))
            previous = value
        }
    }

    func testOnlyInterfacesThatCarryInternetTrafficAreCounted() {
        XCTAssertEqual(InterfaceCounters.classify("en0"), .wifi)
        XCTAssertEqual(InterfaceCounters.classify("pdp_ip0"), .cellular)
        XCTAssertEqual(InterfaceCounters.classify("en2"), .wired)
        XCTAssertNil(InterfaceCounters.classify("utun3"))
        XCTAssertNil(InterfaceCounters.classify("bridge100"))
        XCTAssertNil(InterfaceCounters.classify("awdl0"))
        XCTAssertNil(InterfaceCounters.classify("lo0"))
    }

    func testTheSystemCountersAreReadable() {
        // Dans le simulateur comme sur un iPhone, au moins une interface est active.
        let readings = InterfaceCounters.read()
        XCTAssertFalse(readings.isEmpty)
        XCTAssertEqual(Set(readings.map(\.name)).count, readings.count, "une entrée par interface")
    }

    func testRadioGenerations() {
        XCTAssertEqual(RadioTechnology.generation(of: CTRadioAccessTechnologyNR), "5G")
        XCTAssertEqual(RadioTechnology.generation(of: CTRadioAccessTechnologyNRNSA), "5G")
        XCTAssertEqual(RadioTechnology.generation(of: CTRadioAccessTechnologyLTE), "4G")
        XCTAssertEqual(RadioTechnology.generation(of: CTRadioAccessTechnologyEdge), "2G")
        XCTAssertNil(RadioTechnology.generation(of: "inconnue"))
    }

    func testEveryEngineValueHasAFrenchName() {
        for kind in NetworkKind.allCases { XCTAssertFalse(kind.title.isEmpty) }
        for status in ApplyStatus.allCases { XCTAssertFalse(status.title.isEmpty) }
        for mode in LimitMode.allCases { XCTAssertFalse(mode.title.isEmpty) }
        for capability in Capability.allCases { XCTAssertFalse(capability.title.isEmpty) }
        // Seul un statut confirmé par le système s'appelle « Appliqué ».
        XCTAssertEqual(ApplyStatus.simulated.title, "Simulé")
        XCTAssertEqual(ApplyStatus.unsupported.title, "Réservé à iOS")
    }

    func testTheLatencyProbeAnswersOrGivesUp() async {
        // Un hôte qui n'existe pas : la sonde renvoie « pas de réponse », sans rester bloquée.
        let started = Date()
        let result = await LatencyProbe.measure(host: "hote-inexistant.invalid", timeout: 2)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }
}

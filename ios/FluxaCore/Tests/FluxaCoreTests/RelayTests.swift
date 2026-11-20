import XCTest

@testable import FluxaCore

/// La limite appliquée par le relais : « partielle », et simulée de nouveau à son arrêt.
final class RelayTests: XCTestCase {
    private func engine() -> FluxaEngine {
        FluxaEngine(store: MemoryStore(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    private let policy = BandwidthPolicy(downloadBps: 5_000_000, uploadBps: 1_000_000)

    func testTheRelayLimitIsPartialAndEffective() throws {
        let engine = engine()
        let result = try engine.confirmRelayLimit(policy)
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.effective, policy)
        XCTAssertEqual(result.capability, .hotspotLimit)
        XCTAssertTrue(result.reason?.contains("relais") ?? false)
        XCTAssertEqual(engine.lastApplyResult, result)
        XCTAssertEqual(engine.policyLog(limit: 1).first, result)
        // Jamais « appliqué » sans réserve : le trafic hors relais n'est pas plafonné.
        XCTAssertNotEqual(result.status, .applied)
    }

    func testAnInvalidRelayLimitIsRefused() {
        XCTAssertThrowsError(try engine().confirmRelayLimit(BandwidthPolicy(downloadBps: 1)))
    }

    func testStoppingTheRelayMakesTheLimitSimulatedAgain() throws {
        let engine = engine()
        try engine.confirmRelayLimit(policy)
        engine.relayStopped()
        XCTAssertEqual(engine.lastApplyResult?.status, .simulated)
        XCTAssertEqual(engine.lastApplyResult?.requested, policy)
        XCTAssertNil(engine.lastApplyResult?.effective)
    }

    func testStoppingTheRelayLeavesASimulatedLimitAlone() throws {
        let engine = engine()
        let simulated = try engine.apply(policy)
        engine.relayStopped()
        XCTAssertEqual(engine.lastApplyResult, simulated)
    }
}

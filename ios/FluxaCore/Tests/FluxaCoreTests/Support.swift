import Foundation
import XCTest

@testable import FluxaCore

/// 1er mars 2026 à 12 h UTC.
let noon = Date(timeIntervalSince1970: 1_772_366_400)
let minute: TimeInterval = 60
let hour: TimeInterval = 3_600
let day: TimeInterval = 86_400

/// Une horloge que l'on avance à la main.
final class TestClock {
    var date: Date

    init(_ date: Date = noon) {
        self.date = date
    }

    func advance(_ seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
    }
}

func calendar(utcOffsetSeconds: Int = 0) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds)!
    return calendar
}

func cellular(_ received: UInt64, _ sent: UInt64, name: String = "pdp_ip0") -> InterfaceReading {
    InterfaceReading(name: name, kind: .cellular, receivedBytes: received, sentBytes: sent)
}

func wifi(_ received: UInt64, _ sent: UInt64) -> InterfaceReading {
    InterfaceReading(name: "en0", kind: .wifi, receivedBytes: received, sentBytes: sent)
}

/// Un moteur, son horloge et les compteurs d'une interface cellulaire simulée.
final class Bench {
    let clock: TestClock
    let store: any EngineStore
    let engine: FluxaEngine
    var received: UInt64 = 1_000_000
    var sent: UInt64 = 1_000_000

    init(
        store: any EngineStore = MemoryStore(),
        clock: TestClock = TestClock(),
        calendar: Calendar = calendar(),
        counterWidth: CounterWidth = .bits32
    ) {
        self.clock = clock
        self.store = store
        self.engine = FluxaEngine(
            store: store, counterWidth: counterWidth, calendar: calendar, now: { clock.date })
    }

    /// Démarre la mesure sur le réseau mobile et pose le relevé de base.
    @discardableResult
    func started() -> Bench {
        engine.updatePath(kind: .cellular, isOnline: true)
        engine.start()
        engine.ingest([cellular(received, sent)])
        return self
    }

    /// Fait mesurer `seconds` secondes à `down` / `up` Mb/s.
    func measure(seconds: Int, down: Double, up: Double) {
        for _ in 0..<seconds {
            clock.advance(1)
            received += UInt64(down * 125_000)
            sent += UInt64(up * 125_000)
            engine.ingest([cellular(received, sent)])
        }
    }

    /// Reprend la mesure après une interruption : le relevé ne sert que de base.
    func rebase() {
        engine.stop()
        engine.start()
        engine.ingest([cellular(received, sent)])
    }
}

/// Un stockage qui échoue à la demande.
final class FailingStore: EngineStore {
    var failsOnLoad = false
    var failsOnSave = false
    var failsOnErase = false
    private(set) var saved: EngineState?
    private(set) var saveCount = 0

    struct Failure: Error {}

    func load() throws -> EngineState? {
        if failsOnLoad { throw Failure() }
        return saved
    }

    func save(_ state: EngineState) throws {
        if failsOnSave { throw FluxaError.store("disque plein.") }
        saved = state
        saveCount += 1
    }

    func erase() throws {
        if failsOnErase { throw Failure() }
        saved = nil
    }

    var location: String? { "test" }
}

func temporaryFile(_ name: String = "fluxa.json") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fluxa-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name)
}

func XCTAssertThrows<T>(
    _ expression: @autoclosure () throws -> T,
    _ expected: FluxaError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        XCTAssertEqual(error as? FluxaError, expected, file: file, line: line)
    }
}

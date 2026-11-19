import Foundation

/// Suit les compteurs d'octets de chaque interface d'un relevé à l'autre.
///
/// Le premier relevé d'une interface ne sert que de base. Un compteur de 32 bits qui
/// repasse par zéro continue de compter ; un compteur remis à zéro (interface
/// relancée, redémarrage) ne compte pas pour l'intervalle.
struct InterfaceMeter {
    /// Octets échangés par une interface entre deux relevés.
    struct Delta: Equatable {
        let name: String
        let kind: InterfaceClass
        let receivedBytes: UInt64
        let sentBytes: UInt64
    }

    /// Les différences de toutes les interfaces suivies, sur un même intervalle.
    struct Deltas: Equatable {
        let seconds: Double
        let interfaces: [Delta]
    }

    /// Au-delà de ce débit, un compteur qui recule est considéré comme remis à zéro
    /// et non comme ayant débordé : 20 Gb/s.
    static let maximumPlausibleBps = 20_000_000_000.0

    /// Au-delà de cet écart entre deux relevés, l'app a été suspendue : les compteurs
    /// ont pu déborder plusieurs fois, le relevé ne sert que de nouvelle base.
    static let maximumInterval: TimeInterval = 60

    let width: CounterWidth
    private var previous: [String: (received: UInt64, sent: UInt64)] = [:]
    private var previousDate: Date?

    init(width: CounterWidth) {
        self.width = width
    }

    /// La date du dernier relevé intégré. `nil` : le prochain servira de base.
    var lastDate: Date? { previousDate }

    mutating func reset() {
        previous.removeAll()
        previousDate = nil
    }

    /// Intègre un relevé. Renvoie `nil` pour le premier relevé, quand l'horloge n'a
    /// pas avancé et après une longue interruption ; le relevé devient la nouvelle base.
    mutating func push(_ readings: [InterfaceReading], at date: Date) -> Deltas? {
        var seconds: Double?
        if let previousDate {
            let elapsed = date.timeIntervalSince(previousDate)
            if elapsed > 0, elapsed <= Self.maximumInterval {
                seconds = elapsed
            }
        }

        var interfaces: [Delta] = []
        var current: [String: (received: UInt64, sent: UInt64)] = [:]
        for reading in readings where current[reading.name] == nil {
            current[reading.name] = (reading.receivedBytes, reading.sentBytes)
            guard let seconds, let before = previous[reading.name],
                let received = delta(from: before.received, to: reading.receivedBytes, seconds: seconds),
                let sent = delta(from: before.sent, to: reading.sentBytes, seconds: seconds)
            else { continue }
            interfaces.append(
                Delta(name: reading.name, kind: reading.kind, receivedBytes: received, sentBytes: sent))
        }
        previous = current
        previousDate = date
        return seconds.map { Deltas(seconds: $0, interfaces: interfaces) }
    }

    /// Octets comptés entre deux valeurs d'un compteur. `nil` si le compteur a été
    /// remis à zéro.
    private func delta(from previous: UInt64, to current: UInt64, seconds: Double) -> UInt64? {
        if current >= previous {
            return current - previous
        }
        guard width == .bits32 else { return nil }
        let modulus: UInt64 = 1 << 32
        guard previous < modulus else { return nil }
        // Débordement : le compteur est reparti de zéro après 2^32.
        let wrapped = modulus - previous + current
        let bps = Double(wrapped) * 8 / seconds
        return bps <= Self.maximumPlausibleBps ? wrapped : nil
    }
}

extension NetworkKind {
    /// La famille d'interfaces qui porte le trafic de ce type de réseau.
    var interfaceClass: InterfaceClass? {
        switch self {
        case .offline: return nil
        case .wifi: return .wifi
        case .cellular: return .cellular
        case .wired: return .wired
        case .other: return .other
        }
    }

    /// Le nom du réseau dans le journal de diagnostic.
    var eventLabel: String {
        switch self {
        case .offline: return "aucun"
        case .wifi: return "Wi-Fi"
        case .cellular: return "cellulaire"
        case .wired: return "filaire"
        case .other: return "autre"
        }
    }
}

extension UInt64 {
    /// Addition qui s'arrête au maximum au lieu de déborder.
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

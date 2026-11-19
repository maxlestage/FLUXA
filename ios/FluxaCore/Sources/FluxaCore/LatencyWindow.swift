import Foundation

/// Les dernières sondes de latence. `nil` : sonde restée sans réponse.
struct LatencyWindow {
    private let capacity: Int
    private var probes: [Double?] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func clear() {
        probes.removeAll()
    }

    /// Ajoute une sonde. Une valeur négative ou non finie compte comme perdue.
    mutating func push(_ milliseconds: Double?) {
        var probe = milliseconds
        if let value = milliseconds, !value.isFinite || value < 0 {
            probe = nil
        }
        if probes.count == capacity {
            probes.removeFirst()
        }
        probes.append(probe)
    }

    private var answered: [Double] { probes.compactMap { $0 } }

    /// La latence de la sonde la plus récente ayant répondu.
    var latest: Double? { answered.last }

    var average: Double? {
        let values = answered
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Gigue : écart moyen entre deux réponses successives. Il en faut au moins deux.
    var jitter: Double? {
        let values = answered
        guard values.count >= 2 else { return nil }
        var total = 0.0
        for index in 1..<values.count {
            total += abs(values[index] - values[index - 1])
        }
        return total / Double(values.count - 1)
    }

    /// Part des sondes sans réponse, entre 0 et 1. `nil` sans aucune sonde.
    var lossRatio: Double? {
        guard !probes.isEmpty else { return nil }
        let lost = probes.filter { $0 == nil }.count
        return Double(lost) / Double(probes.count)
    }
}

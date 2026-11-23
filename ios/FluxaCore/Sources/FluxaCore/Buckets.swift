import Foundation

/// Un débit mesuré entre deux relevés.
struct Measurement: Equatable {
    let date: Date
    let seconds: Double
    let receivedBytes: UInt64
    let sentBytes: UInt64

    var downloadBps: Double { Double(receivedBytes) * 8 / seconds }
    var uploadBps: Double { Double(sentBytes) * 8 / seconds }
}

/// Les mesures d'une minute, d'une heure ou d'un jour, telles que le moteur les garde.
///
/// Le temps réellement mesuré est conservé : l'app ne mesure pas en continu, et une
/// moyenne se calcule sur ce temps (octets × 8 / temps mesuré), pas sur la période.
struct Bucket: Equatable, Sendable {
    var start: Date
    var measuredSeconds = 0.0
    var receivedBytes: UInt64 = 0
    var sentBytes: UInt64 = 0
    var peakDownloadBps = 0.0
    var peakUploadBps = 0.0
    var sampleCount = 0

    init(start: Date) {
        self.start = start
    }

    mutating func add(_ measurement: Measurement) {
        measuredSeconds += measurement.seconds
        receivedBytes = receivedBytes.saturatingAdd(measurement.receivedBytes)
        sentBytes = sentBytes.saturatingAdd(measurement.sentBytes)
        peakDownloadBps = max(peakDownloadBps, measurement.downloadBps)
        peakUploadBps = max(peakUploadBps, measurement.uploadBps)
        sampleCount += 1
    }

    mutating func merge(_ other: Bucket) {
        measuredSeconds += other.measuredSeconds
        receivedBytes = receivedBytes.saturatingAdd(other.receivedBytes)
        sentBytes = sentBytes.saturatingAdd(other.sentBytes)
        peakDownloadBps = max(peakDownloadBps, other.peakDownloadBps)
        peakUploadBps = max(peakUploadBps, other.peakUploadBps)
        sampleCount += other.sampleCount
    }

    var averageDownloadBps: Double {
        measuredSeconds > 0 ? Double(receivedBytes) * 8 / measuredSeconds : 0
    }

    var averageUploadBps: Double {
        measuredSeconds > 0 ? Double(sentBytes) * 8 / measuredSeconds : 0
    }

    var aggregate: Aggregate {
        Aggregate(
            start: start,
            averageDownloadBps: averageDownloadBps,
            averageUploadBps: averageUploadBps,
            peakDownloadBps: peakDownloadBps,
            peakUploadBps: peakUploadBps,
            receivedBytes: receivedBytes,
            sentBytes: sentBytes,
            sampleCount: sampleCount
        )
    }
}

// Forme compacte dans le fichier : une liste de sept nombres par période. Sept jours
// de minutes font des milliers de périodes, réécrites à chaque enregistrement.
extension Bucket: Codable {
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        start = Date(timeIntervalSinceReferenceDate: try values.decode(Double.self))
        measuredSeconds = try values.decode(Double.self)
        receivedBytes = try values.decode(UInt64.self)
        sentBytes = try values.decode(UInt64.self)
        peakDownloadBps = try values.decode(Double.self)
        peakUploadBps = try values.decode(Double.self)
        sampleCount = try values.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(start.timeIntervalSinceReferenceDate)
        try values.encode(measuredSeconds)
        try values.encode(receivedBytes)
        try values.encode(sentBytes)
        try values.encode(peakDownloadBps)
        try values.encode(peakUploadBps)
        try values.encode(sampleCount)
    }
}

/// Une suite de périodes, triée par date de début.
struct BucketSeries: Equatable, Sendable {
    private(set) var buckets: [Bucket] = []

    init() {}

    /// Une suite à partir de périodes lues dans un stockage, dans n'importe quel ordre.
    init(buckets: [Bucket]) {
        self.buckets = buckets.sorted { $0.start < $1.start }
    }

    var count: Int { buckets.count }

    /// Ajoute une mesure à la période qui commence à `start`.
    mutating func add(_ measurement: Measurement, at start: Date) {
        if let last = buckets.last, last.start == start {
            buckets[buckets.count - 1].add(measurement)
            return
        }
        var bucket = Bucket(start: start)
        bucket.add(measurement)
        if let last = buckets.last, last.start > start {
            // L'horloge a reculé : la période existe peut-être déjà, plus tôt dans la suite.
            let index = buckets.partitionIndex { $0.start >= start }
            if index < buckets.count, buckets[index].start == start {
                buckets[index].add(measurement)
            } else {
                buckets.insert(bucket, at: index)
            }
        } else {
            buckets.append(bucket)
        }
    }

    /// Supprime les périodes commencées avant `date`. Renvoie leur nombre.
    @discardableResult
    mutating func removeAll(before date: Date) -> Int {
        // La suite est triée : les périodes à supprimer sont en tête.
        let removed = buckets.partitionIndex { $0.start >= date }
        buckets.removeFirst(removed)
        return removed
    }

    mutating func removeAll() {
        buckets.removeAll()
    }

    /// Les périodes dont le début est dans `[from, to[`.
    func slice(from: Date, to: Date) -> [Bucket] {
        // Deux recherches dichotomiques au lieu d'un parcours : sept jours de minutes
        // font dix mille périodes, lues à chaque bilan.
        let lower = buckets.partitionIndex { $0.start >= from }
        let upper = buckets.partitionIndex { $0.start >= to }
        return lower < upper ? Array(buckets[lower..<upper]) : []
    }
}

extension Array {
    /// L'indice du premier élément qui vérifie `predicate`, dans un tableau où tous les
    /// éléments qui ne le vérifient pas précèdent ceux qui le vérifient. `count` si
    /// aucun ne le vérifie. Recherche dichotomique.
    func partitionIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(self[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}

/// Le volume d'une heure ou d'un jour sur une famille d'interfaces.
struct NetworkBucket: Equatable, Sendable {
    var start: Date
    var kind: InterfaceClass
    var receivedBytes: UInt64 = 0
    var sentBytes: UInt64 = 0
}

// Forme compacte dans le fichier, comme les agrégats : une liste de quatre valeurs.
extension NetworkBucket: Codable {
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        start = Date(timeIntervalSinceReferenceDate: try values.decode(Double.self))
        // Une famille inconnue (écrite par une version plus récente) se range dans « autre ».
        kind = InterfaceClass(rawValue: try values.decode(String.self)) ?? .other
        receivedBytes = try values.decode(UInt64.self)
        sentBytes = try values.decode(UInt64.self)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(start.timeIntervalSinceReferenceDate)
        try values.encode(kind.rawValue)
        try values.encode(receivedBytes)
        try values.encode(sentBytes)
    }
}

/// Le volume par famille d'interfaces, période par période, trié par date de début.
/// Une période compte une entrée par famille qui a échangé des octets.
struct NetworkSeries: Equatable, Sendable {
    private(set) var buckets: [NetworkBucket] = []

    init() {}

    /// Une suite à partir d'entrées lues dans un stockage, dans n'importe quel ordre.
    init(buckets: [NetworkBucket]) {
        self.buckets = buckets.sorted(by: Self.precedes)
    }

    var count: Int { buckets.count }

    static func precedes(_ left: NetworkBucket, _ right: NetworkBucket) -> Bool {
        left.start != right.start ? left.start < right.start : left.kind.rawValue < right.kind.rawValue
    }

    /// Ajoute un volume à l'entrée de cette famille pour la période qui commence à `start`.
    mutating func add(kind: InterfaceClass, receivedBytes: UInt64, sentBytes: UInt64, at start: Date) {
        // Les entrées de la période sont contiguës ; en temps normal, ce sont les dernières.
        let lower = buckets.last.map { $0.start < start } ?? true
            ? buckets.count : buckets.partitionIndex { $0.start >= start }
        var index = lower
        while index < buckets.count, buckets[index].start == start {
            if buckets[index].kind == kind {
                buckets[index].receivedBytes = buckets[index].receivedBytes.saturatingAdd(receivedBytes)
                buckets[index].sentBytes = buckets[index].sentBytes.saturatingAdd(sentBytes)
                return
            }
            // L'ordre des familles dans une période suit `precedes`.
            if buckets[index].kind.rawValue > kind.rawValue { break }
            index += 1
        }
        buckets.insert(
            NetworkBucket(start: start, kind: kind, receivedBytes: receivedBytes, sentBytes: sentBytes),
            at: index)
    }

    /// Supprime les entrées des périodes commencées avant `date`. Renvoie leur nombre.
    @discardableResult
    mutating func removeAll(before date: Date) -> Int {
        let removed = buckets.partitionIndex { $0.start >= date }
        buckets.removeFirst(removed)
        return removed
    }

    mutating func removeAll() {
        buckets.removeAll()
    }

    /// Les entrées des périodes dont le début est dans `[from, to[`.
    func slice(from: Date, to: Date) -> ArraySlice<NetworkBucket> {
        let lower = buckets.partitionIndex { $0.start >= from }
        let upper = buckets.partitionIndex { $0.start >= to }
        return lower < upper ? buckets[lower..<upper] : []
    }
}

extension NetworkSeries: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(buckets: try container.decode([NetworkBucket].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(buckets)
    }
}

extension BucketSeries: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        buckets = try container.decode([Bucket].self).sorted { $0.start < $1.start }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(buckets)
    }
}

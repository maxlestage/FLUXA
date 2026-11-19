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
            if let index = buckets.firstIndex(where: { $0.start == start }) {
                buckets[index].add(measurement)
            } else {
                let index = buckets.firstIndex(where: { $0.start > start }) ?? buckets.count
                buckets.insert(bucket, at: index)
            }
        } else {
            buckets.append(bucket)
        }
    }

    /// Supprime les périodes commencées avant `date`. Renvoie leur nombre.
    @discardableResult
    mutating func removeAll(before date: Date) -> Int {
        let kept = buckets.filter { $0.start >= date }
        let removed = buckets.count - kept.count
        buckets = kept
        return removed
    }

    mutating func removeAll() {
        buckets.removeAll()
    }

    /// Les périodes dont le début est dans `[from, to[`.
    func slice(from: Date, to: Date) -> [Bucket] {
        buckets.filter { $0.start >= from && $0.start < to }
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

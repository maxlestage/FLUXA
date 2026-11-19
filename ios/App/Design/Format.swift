import FluxaCore
import Foundation

/// L'écriture des mesures, à la française. Une valeur absente s'écrit « — » : l'app ne
/// remplace jamais une mesure manquante par un zéro.
enum Format {
    static let locale = Locale(identifier: "fr_FR")
    static let missing = "—"
    /// Une espace insécable, entre un nombre et son unité.
    private static let space = "\u{00A0}"

    static func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    /// Un débit, découpé en valeur et unité pour les grands affichages.
    static func rateParts(_ bps: Double?) -> (value: String, unit: String) {
        guard let bps else { return (missing, "Mb/s") }
        if bps >= 100_000 || bps == 0 {
            return (number(bps / 1_000_000, digits: 1), "Mb/s")
        }
        if bps >= 1_000 {
            return (number(bps / 1_000, digits: 0), "kb/s")
        }
        return (number(bps, digits: 0), "b/s")
    }

    static func rate(_ bps: Double?) -> String {
        let parts = rateParts(bps)
        return bps == nil ? parts.value : parts.value + space + parts.unit
    }

    /// Un plafond : son débit, ou « Sans plafond ».
    static func cap(_ bps: UInt64?) -> String {
        guard let bps else { return "Sans plafond" }
        let mbps = Limits.mbps(fromBps: bps)
        let digits = mbps == mbps.rounded() ? 0 : 1
        return number(mbps, digits: digits) + space + "Mb/s"
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return missing }
        return number(value, digits: 0) + space + "ms"
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return missing }
        return number(value, digits: 0) + space + "%"
    }

    /// Un volume de données, en unités décimales : ko, Mo, Go.
    static func bytes(_ value: UInt64) -> String {
        let bytes = Double(value)
        if bytes >= 1_000_000_000 {
            return number(bytes / 1_000_000_000, digits: 2) + space + "Go"
        }
        if bytes >= 1_000_000 {
            return number(bytes / 1_000_000, digits: 1) + space + "Mo"
        }
        if bytes >= 1_000 {
            return number(bytes / 1_000, digits: 0) + space + "ko"
        }
        return number(bytes, digits: 0) + space + "o"
    }

    static func duration(seconds: UInt64?) -> String {
        guard let seconds else { return "Sans limite de temps" }
        if seconds < 3_600 {
            return "\(seconds / 60)" + space + "min"
        }
        return "\(seconds / 3_600)" + space + "h"
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(locale))
    }
}

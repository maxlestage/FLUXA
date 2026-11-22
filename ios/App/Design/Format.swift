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
    /// Une mesure à flèches pour VoiceOver : « ↓ 25 Mb/s · ↑ 10 Mb/s » se lit
    /// « descendant 25 Mb/s, montant 10 Mb/s » au lieu d'épeler les signes.
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: "↓", with: "descendant")
            .replacingOccurrences(of: "↑", with: "montant")
            .replacingOccurrences(of: " · ", with: ", ")
    }

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

    /// Un volume en gigaoctets, pour un forfait : « 50 Go », « 12,5 Go ».
    static func gigabytes(_ value: UInt64) -> String {
        let gigabytes = Double(value) / 1_000_000_000
        let digits = gigabytes == gigabytes.rounded() ? 0 : (gigabytes >= 10 ? 1 : 2)
        return number(gigabytes, digits: digits) + space + "Go"
    }

    /// Une durée écoulée : « 45 s », « 12 min », « 2 h 05 », « 3 j 4 h ».
    static func span(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded())
        if seconds < 60 {
            return "\(seconds)" + space + "s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)" + space + "min"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)" + space + "h" + space + String(format: "%02d", minutes % 60)
        }
        return "\(hours / 24)" + space + "j" + space + "\(hours % 24)" + space + "h"
    }

    /// Un jour, sans l'heure : « 24 nov. ».
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(locale))
    }
}

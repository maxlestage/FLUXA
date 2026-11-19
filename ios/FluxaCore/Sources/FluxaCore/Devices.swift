import Foundation

// Le registre des appareils, la comparaison des périodes et l'export.
//
// CONTRAT : les types de ce fichier et les signatures publiques de l'extension de
// `FluxaEngine` sont utilisés par l'interface.

// MARK: - Appareils

public enum DeviceKind: String, Codable, CaseIterable, Sendable {
    case computer, phone, tablet, television, console, other
}

/// Un appareil que l'utilisateur relie à son partage de connexion et qu'il a noté lui-même.
///
/// iOS ne donne pas à une app la liste des appareils reliés, ni leur adresse, ni leur
/// trafic. Le registre ne contient donc que ce que l'utilisateur saisit : il n'invente
/// ni nom, ni adresse IP, ni adresse MAC.
public struct Device: Identifiable, Codable, Equatable, Sendable {
    /// Vide pour un appareil pas encore enregistré.
    public var id: String
    public var name: String
    public var kind: DeviceKind
    /// Le profil prévu pour cet appareil. Il est noté, pas appliqué.
    public var profileID: String?
    public var note: String
    /// La date d'ajout au registre, fixée par le moteur.
    public var addedAt: Date

    public init(
        id: String = "",
        name: String,
        kind: DeviceKind = .other,
        profileID: String? = nil,
        note: String = "",
        addedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.profileID = profileID
        self.note = note
        self.addedAt = addedAt
    }
}

/// Où un profil est utilisé, pour prévenir avant de le supprimer.
public struct ProfileUsage: Equatable, Sendable {
    /// Les noms des règles d'automatisation qui choisissent ce profil.
    public var ruleNames: [String]
    /// Les noms des appareils auxquels ce profil est associé.
    public var deviceNames: [String]
    public var isEmpty: Bool { ruleNames.isEmpty && deviceNames.isEmpty }

    public init(ruleNames: [String] = [], deviceNames: [String] = []) {
        self.ruleNames = ruleNames
        self.deviceNames = deviceNames
    }
}

// MARK: - Comparaison

/// Une période comparée à celle, de même durée, qui la précède.
public struct UsageComparison: Equatable, Sendable {
    public var current: UsageSummary
    public var previous: UsageSummary
    /// La variation du volume total (reçu et envoyé), en pour cent. `nil` quand la
    /// période précédente n'a aucune mesure : il n'y a alors rien à comparer.
    public var changePercent: Double?

    public init(current: UsageSummary, previous: UsageSummary, changePercent: Double?) {
        self.current = current
        self.previous = previous
        self.changePercent = changePercent
    }
}

extension FluxaEngine {
    // MARK: Appareils

    /// Les appareils du registre, dans l'ordre de leur ajout.
    public var devices: [Device] { state.devices }

    /// Ajoute un appareil (`id` vide) ou remplace celui qui porte cet identifiant. Refuse
    /// un nom vide et un profil inconnu. Les identifiants sont `device-1`, `device-2`…
    @discardableResult
    public func saveDevice(_ device: Device) throws -> Device {
        var device = device
        device.name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        device.note = device.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !device.name.isEmpty else {
            throw FluxaError.invalidDevice("Donnez un nom à l’appareil.")
        }
        if let profileID = device.profileID {
            guard state.profiles.contains(where: { $0.id == profileID }) else {
                throw FluxaError.unknownProfile(id: profileID)
            }
        }

        if device.id.isEmpty {
            device.id = state.makeDeviceID()
            // La date d'ajout vient de l'horloge du moteur, pas de l'appareil reçu.
            device.addedAt = now()
            state.devices.append(device)
        } else {
            guard let index = state.devices.firstIndex(where: { $0.id == device.id }) else {
                throw FluxaError.invalidDevice("Cet appareil n’existe plus.")
            }
            device.addedAt = state.devices[index].addedAt
            state.devices[index] = device
        }
        saveQuietly()
        return device
    }

    public func deleteDevice(id: String) throws {
        guard let index = state.devices.firstIndex(where: { $0.id == id }) else {
            throw FluxaError.invalidDevice("Cet appareil n’existe plus.")
        }
        state.devices.remove(at: index)
        saveQuietly()
    }

    /// Ce que le système ferait de la limite prévue pour cet appareil : `unsupported`
    /// sur iPhone, avec la raison. `nil` si l'appareil n'a pas de profil, ou si ce profil
    /// n'existe plus. Rien n'est demandé au système ni noté au journal.
    public func limitStatus(for device: Device) -> ApplyResult? {
        guard let profileID = device.profileID,
            let profile = state.profiles.first(where: { $0.id == profileID })
        else { return nil }
        return ApplyResult(
            requested: profile.policy,
            effective: nil,
            status: .unsupported,
            reason: Rules.deviceLimitReason,
            capability: .perDeviceShaping,
            date: now()
        )
    }

    // MARK: Profils

    /// Les règles et les appareils qui utilisent ce profil.
    public func profileUsage(id: String) -> ProfileUsage {
        ProfileUsage(
            ruleNames: state.rules.filter { $0.action == .activateProfile(id: id) }.map(\.name),
            deviceNames: state.devices.filter { $0.profileID == id }.map(\.name)
        )
    }

    // MARK: Historique

    /// Compare `[from, to[` à la période de même durée qui la précède.
    public func compareUsage(from: Date, to: Date) -> UsageComparison {
        guard to > from else {
            return UsageComparison(current: UsageSummary(), previous: UsageSummary(), changePercent: nil)
        }
        let current = measuredUsage(from: from, to: to)
        let previous = measuredUsage(from: from.addingTimeInterval(-to.timeIntervalSince(from)), to: from)

        let currentTotal = Double(current.summary.receivedBytes) + Double(current.summary.sentBytes)
        let previousTotal = Double(previous.summary.receivedBytes) + Double(previous.summary.sentBytes)
        var changePercent: Double?
        if previous.hasMeasures {
            if previousTotal > 0 {
                changePercent = (currentTotal - previousTotal) / previousTotal * 100
            } else if currentTotal == 0 {
                // Zéro octet mesuré avant comme après : aucune variation.
                changePercent = 0
            }
            // Parti de zéro octet mesuré : une hausse ne s'exprime pas en pour cent.
        }
        return UsageComparison(
            current: current.summary, previous: previous.summary, changePercent: changePercent)
    }

    /// Les agrégats de `[from, to[` au format CSV : séparateur point-virgule, première
    /// ligne d'en-têtes, une ligne par agrégat, du plus ancien au plus récent. Colonnes :
    /// `debut` (ISO 8601, UTC), `debit_descendant_moyen_bps`, `debit_montant_moyen_bps`,
    /// `pic_descendant_bps`, `pic_montant_bps`, `octets_recus`, `octets_envoyes`, `mesures`.
    /// Les débits sont des entiers arrondis ; le point décimal n'apparaît donc pas.
    public func exportCSV(from: Date, to: Date, step: HistoryStep) -> String {
        var lines = [Self.csvHeader]
        for aggregate in history(from: from, to: to, step: step) {
            let fields = [
                Self.iso8601(aggregate.start),
                Self.integer(aggregate.averageDownloadBps),
                Self.integer(aggregate.averageUploadBps),
                Self.integer(aggregate.peakDownloadBps),
                Self.integer(aggregate.peakUploadBps),
                String(aggregate.receivedBytes),
                String(aggregate.sentBytes),
                String(aggregate.sampleCount),
            ]
            lines.append(fields.joined(separator: ";"))
        }
        // Chaque ligne se termine par un saut de ligne, la dernière aussi.
        return lines.joined(separator: "\n") + "\n"
    }

    static let csvHeader =
        "debut;debit_descendant_moyen_bps;debit_montant_moyen_bps;pic_descendant_bps;"
        + "pic_montant_bps;octets_recus;octets_envoyes;mesures"

    /// Un débit arrondi à l'entier, sans séparateur ni exposant.
    private static func integer(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        return value >= Double(UInt64.max) ? String(UInt64.max) : String(UInt64(value.rounded()))
    }

    /// Une date en ISO 8601, en UTC, à la seconde : `2026-03-01T12:00:00Z`.
    static func iso8601(_ date: Date) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? utc.timeZone
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}

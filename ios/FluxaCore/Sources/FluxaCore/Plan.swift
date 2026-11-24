import Foundation

// Le volume par réseau, le rattrapage hors de l'app, le forfait mobile et le trafic du
// partage de connexion.
//
// CONTRAT : les types de ce fichier et les signatures publiques de l'extension de
// `FluxaEngine` sont utilisés par l'interface. Les corps sont à écrire.
//
// Rattrapage. Les compteurs d'une interface sont cumulés depuis le démarrage de
// l'iPhone : entre deux ouvertures de l'app, leur différence donne le volume échangé
// pendant que l'app ne mesurait pas. Le moteur garde donc le dernier relevé (un « point
// de reprise » : date, heure de démarrage de l'appareil, compteurs par interface),
// l'enregistre avec le reste, et le compare au premier relevé qui sert de base (au
// démarrage de la mesure, ou après un intervalle trop long pour le compteur en direct).
//   - Pas de rattrapage si l'heure de démarrage manque d'un côté ou diffère de plus de
//     10 secondes (l'appareil a redémarré), ni si l'horloge a reculé.
//   - Par compteur, la borne basse sûre : `actuel - précédent` si `actuel >= précédent`,
//     sinon `actuel` (remise à zéro ou débordement de 32 bits : dans les deux cas au
//     moins `actuel` octets ont passé). Le volume rattrapé est donc toujours « au moins ».
//   - Une interface absente du point de reprise ne compte pas.
//   - Le rattrapage ne produit ni débit ni agrégat de minute : il est gardé à part, comme
//     une `AbsenceUsage` (seulement si son volume n'est pas nul), 200 au plus. Au-delà,
//     les deux plus anciennes fusionnent : leur volume reste compté pour le forfait.
//   - Un relevé sans heure de démarrage ne laisse pas de point de reprise. `eraseHistory`
//     garde le point de reprise quand la mesure tourne (il date du dernier relevé) et le
//     retire quand elle est arrêtée (il ferait revenir un volume d'avant l'effacement).
//
// Volume par réseau. Chaque mesure en direct est aussi rangée par famille d'interface
// (celle du réseau actif), à l'heure et au jour, avec la même conservation que les
// agrégats (30 jours pour les heures, 12 mois pour les jours). `usageByNetwork` prend la
// suite la plus fine qui couvre le début de la période, puis ajoute de chaque absence la
// part proportionnelle au temps qu'elle a en commun avec la période.
//
// Forfait. Le volume du cycle est le cellulaire mesuré dans l'app, plus le cellulaire
// rattrapé, plus le recalage de l'utilisateur (« mon opérateur indique 12 Go »). Le
// recalage ne vaut que pour le cycle où il a été fait.
//
// Partage. L'interface de pont du partage de connexion (famille `.sharing`) ne porte pas
// le trafic Internet de l'iPhone : le moteur ne la compte jamais dans le débit ni dans
// l'historique. Il en tire une session de partage : elle commence au premier relevé où
// une interface `.sharing` est présente et se termine au premier relevé où il n'y en a
// plus. Un arrêt de la mesure ne la termine pas : à la reprise, si l'appareil n'a pas
// redémarré et que l'interface est encore là, elle continue, augmentée du volume
// rattrapé (`isLowerBound` passe à vrai) ; sinon elle se termine à la date du point de
// reprise. Le pont envoie vers les appareils reliés (`sentBytes` du relevé) et reçoit
// d'eux (`receivedBytes`).

/// Un volume échangé sur une famille d'interfaces.
public struct NetworkVolume: Codable, Equatable, Sendable {
    public var kind: InterfaceClass
    public var receivedBytes: UInt64
    public var sentBytes: UInt64

    public init(kind: InterfaceClass, receivedBytes: UInt64, sentBytes: UInt64) {
        self.kind = kind
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }

    public var totalBytes: UInt64 { receivedBytes.saturatingAdd(sentBytes) }
}

/// Le volume d'une période sur un réseau.
public struct NetworkUsage: Identifiable, Equatable, Sendable {
    public let kind: InterfaceClass
    /// Mesuré dans l'app et rattrapé hors de l'app, ensemble.
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    /// La part rattrapée hors de l'app (une borne basse), déjà comprise ci-dessus.
    public let outsideAppBytes: UInt64

    public init(kind: InterfaceClass, receivedBytes: UInt64, sentBytes: UInt64, outsideAppBytes: UInt64) {
        self.kind = kind
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.outsideAppBytes = outsideAppBytes
    }

    public var id: String { kind.rawValue }
    public var totalBytes: UInt64 { receivedBytes.saturatingAdd(sentBytes) }
}

/// Le volume échangé pendant que l'app ne mesurait pas, d'après les compteurs du système.
/// C'est une borne basse : un compteur de 32 bits repasse par zéro tous les 4 Go.
public struct AbsenceUsage: Identifiable, Codable, Equatable, Sendable {
    public var id: Int
    /// Le dernier relevé avant l'interruption.
    public var start: Date
    /// Le premier relevé à la reprise.
    public var end: Date
    /// Par famille d'interface, sans `.sharing` ; les familles sans volume sont omises.
    public var volumes: [NetworkVolume]

    public init(id: Int, start: Date, end: Date, volumes: [NetworkVolume]) {
        self.id = id
        self.start = start
        self.end = end
        self.volumes = volumes
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public var totalBytes: UInt64 {
        volumes.reduce(0) { $0.saturatingAdd($1.totalBytes) }
    }

    public func volume(of kind: InterfaceClass) -> NetworkVolume? {
        volumes.first { $0.kind == kind }
    }
}

/// Le forfait de données mobiles, tel que l'utilisateur le décrit.
public struct DataPlan: Codable, Equatable, Sendable {
    /// Le volume du forfait, en octets.
    public var allowanceBytes: UInt64
    /// Le jour du mois où le forfait repart de zéro, de 1 à 31. Dans un mois plus court,
    /// c'est son dernier jour.
    public var resetDay: Int

    public init(allowanceBytes: UInt64, resetDay: Int) {
        self.allowanceBytes = allowanceBytes
        self.resetDay = resetDay
    }
}

/// Où en est le forfait dans son cycle.
public struct PlanStatus: Equatable, Sendable {
    public let plan: DataPlan
    /// Minuit local du jour de remise à zéro, passé puis à venir.
    public let cycleStart: Date
    public let cycleEnd: Date
    /// Mesuré dans l'app, rattrapé et recalé, ensemble.
    public let usedBytes: UInt64
    /// La part mesurée dans l'app depuis le début du cycle (ou depuis le recalage).
    public let measuredBytes: UInt64
    /// La part rattrapée hors de l'app depuis le début du cycle (ou depuis le recalage).
    public let outsideAppBytes: UInt64
    /// Le volume indiqué par l'utilisateur au recalage, ou `nil` sans recalage dans ce cycle.
    public let calibratedBytes: UInt64?
    public let remainingBytes: UInt64
    /// `usedBytes / allowanceBytes` : dépasse 1 quand le forfait est dépassé.
    public let fractionUsed: Double
    /// Les jours restants jusqu'à la remise à zéro, arrondis vers le haut, au moins 1.
    public let daysRemaining: Int
    /// Ce qu'il reste, réparti sur les jours restants.
    public let dailyBudgetBytes: UInt64
    /// Le volume en fin de cycle au rythme actuel. `nil` avant un jour écoulé dans le cycle.
    public let projectedBytes: UInt64?
    /// Quand le forfait sera épuisé à ce rythme. `nil` si la projection reste sous le
    /// forfait, ou sans projection. Déjà dépassé : la date du moment.
    public let exhaustionDate: Date?

    public init(
        plan: DataPlan, cycleStart: Date, cycleEnd: Date, usedBytes: UInt64, measuredBytes: UInt64,
        outsideAppBytes: UInt64, calibratedBytes: UInt64?, remainingBytes: UInt64, fractionUsed: Double,
        daysRemaining: Int, dailyBudgetBytes: UInt64, projectedBytes: UInt64?, exhaustionDate: Date?
    ) {
        self.plan = plan
        self.cycleStart = cycleStart
        self.cycleEnd = cycleEnd
        self.usedBytes = usedBytes
        self.measuredBytes = measuredBytes
        self.outsideAppBytes = outsideAppBytes
        self.calibratedBytes = calibratedBytes
        self.remainingBytes = remainingBytes
        self.fractionUsed = fractionUsed
        self.daysRemaining = daysRemaining
        self.dailyBudgetBytes = dailyBudgetBytes
        self.projectedBytes = projectedBytes
        self.exhaustionDate = exhaustionDate
    }
}

/// Une session de partage de connexion, vue par l'interface de pont du système.
public struct SharingSession: Identifiable, Codable, Equatable, Sendable {
    public var id: Int
    public var start: Date
    /// Le dernier relevé de la session.
    public var end: Date
    /// Envoyé aux appareils reliés (leur téléchargement).
    public var toDevicesBytes: UInt64
    /// Reçu des appareils reliés (leur envoi).
    public var fromDevicesBytes: UInt64
    /// Vrai si une partie du volume a été rattrapée hors de l'app : c'est alors un minimum.
    public var isLowerBound: Bool

    public init(
        id: Int, start: Date, end: Date, toDevicesBytes: UInt64, fromDevicesBytes: UInt64, isLowerBound: Bool
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.toDevicesBytes = toDevicesBytes
        self.fromDevicesBytes = fromDevicesBytes
        self.isLowerBound = isLowerBound
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var totalBytes: UInt64 { toDevicesBytes.saturatingAdd(fromDevicesBytes) }
}

/// Le partage en cours : sa session et les débits du dernier relevé.
public struct SharingStatus: Equatable, Sendable {
    public let session: SharingSession
    /// `nil` tant qu'aucun débit n'a été mesuré sur le pont (premier relevé, reprise).
    public let toDevicesBps: Double?
    public let fromDevicesBps: Double?

    public init(session: SharingSession, toDevicesBps: Double?, fromDevicesBps: Double?) {
        self.session = session
        self.toDevicesBps = toDevicesBps
        self.fromDevicesBps = fromDevicesBps
    }
}

/// Le dernier relevé des compteurs : de quoi rattraper, à la reprise, le volume échangé
/// pendant que l'app ne mesurait pas.
struct CounterCheckpoint: Codable, Equatable, Sendable {
    struct Counter: Codable, Equatable, Sendable {
        var name: String
        var kind: InterfaceClass
        var receivedBytes: UInt64
        var sentBytes: UInt64
    }

    var date: Date
    /// L'heure de démarrage de l'appareil : les compteurs ne se comparent qu'entre deux
    /// relevés du même démarrage.
    var bootTime: Date
    var counters: [Counter]

    init(date: Date, bootTime: Date, readings: [InterfaceReading]) {
        self.date = date
        self.bootTime = bootTime
        var seen = Set<String>()
        // Comme le compteur en direct : le premier relevé d'un nom l'emporte.
        counters = readings.filter { seen.insert($0.name).inserted }.map {
            Counter(name: $0.name, kind: $0.kind, receivedBytes: $0.receivedBytes, sentBytes: $0.sentBytes)
        }
    }

    func counter(named name: String) -> Counter? {
        counters.first { $0.name == name }
    }

    /// Le plus petit nombre d'octets passés entre deux valeurs d'un compteur. Un compteur
    /// qui recule a été remis à zéro ou a débordé : dans les deux cas, au moins `current`
    /// octets ont passé depuis.
    static func lowerBound(from previous: UInt64, to current: UInt64) -> UInt64 {
        current >= previous ? current - previous : current
    }
}

/// Le recalage du forfait : ce que l'opérateur indiquait, et ce que le moteur comptait
/// alors dans le cycle. Ce qui s'ajoute ensuite est la différence avec ces deux cumuls.
struct PlanCalibration: Codable, Equatable, Sendable {
    var date: Date
    var usedBytes: UInt64
    var measuredBefore: UInt64
    var outsideBefore: UInt64
}

extension FluxaEngine {
    /// Nombre d'absences gardées.
    static let absenceCapacity = 200
    /// Nombre de sessions de partage terminées gardées.
    static let sharingSessionCapacity = 100
    /// Écart toléré entre deux lectures de l'heure de démarrage de l'appareil.
    static let bootTimeTolerance: TimeInterval = 10

    // MARK: Relevés

    /// Comme `ingest(_:)`, avec l'heure de démarrage de l'appareil : elle permet de
    /// rattraper le volume échangé pendant que l'app ne mesurait pas. `ingest(_:)` reste
    /// disponible et vaut `ingest(_:bootTime: nil)`.
    @discardableResult
    public func ingest(_ readings: [InterfaceReading], bootTime: Date?) -> NetworkSnapshot {
        process(readings, bootTime: bootTime)
    }

    // MARK: Hors de l'app

    /// Le rattrapage fait à la dernière reprise de la mesure, depuis le lancement du
    /// moteur. `nil` s'il n'y en a pas eu, ou si rien n'a été échangé.
    public var lastAbsence: AbsenceUsage? {
        lastCatchUp
    }

    /// Les absences, de la plus récente à la plus ancienne.
    public func absences(limit: Int) -> [AbsenceUsage] {
        guard limit > 0 else { return [] }
        return Array(state.absences.suffix(limit).reversed())
    }

    /// Le point de reprise, s'il se compare au relevé du moment : même démarrage de
    /// l'appareil, et une horloge qui a avancé.
    func resumableCheckpoint(bootTime: Date?, at date: Date) -> CounterCheckpoint? {
        guard let checkpoint = state.checkpoint, let bootTime,
            abs(bootTime.timeIntervalSince(checkpoint.bootTime)) <= Self.bootTimeTolerance,
            date > checkpoint.date
        else { return nil }
        return checkpoint
    }

    /// À une reprise, compte ce que les compteurs ont avancé depuis le point de reprise.
    /// Le pont du partage n'y entre pas : sa session le rattrape de son côté.
    func catchUp(_ readings: [InterfaceReading], from checkpoint: CounterCheckpoint?, at date: Date) {
        lastCatchUp = nil
        guard let checkpoint else { return }
        var totals: [InterfaceClass: (received: UInt64, sent: UInt64)] = [:]
        var seen = Set<String>()
        for reading in readings where reading.kind != .sharing && seen.insert(reading.name).inserted {
            // Une interface absente du point de reprise n'a pas de base : elle ne compte pas.
            guard let before = checkpoint.counter(named: reading.name) else { continue }
            let received = CounterCheckpoint.lowerBound(from: before.receivedBytes, to: reading.receivedBytes)
            let sent = CounterCheckpoint.lowerBound(from: before.sentBytes, to: reading.sentBytes)
            let total = totals[reading.kind] ?? (0, 0)
            totals[reading.kind] = (total.received.saturatingAdd(received), total.sent.saturatingAdd(sent))
        }
        let volumes = InterfaceClass.allCases.compactMap { kind -> NetworkVolume? in
            guard let total = totals[kind], total.received > 0 || total.sent > 0 else { return nil }
            return NetworkVolume(kind: kind, receivedBytes: total.received, sentBytes: total.sent)
        }
        guard !volumes.isEmpty else { return }

        let absence = AbsenceUsage(
            id: state.nextAbsenceID, start: checkpoint.date, end: date, volumes: volumes)
        state.nextAbsenceID += 1
        state.absences.append(absence)
        // Au-delà de la capacité, les deux plus anciennes n'en font plus qu'une : aucun
        // volume n'est perdu pour le forfait, seule la précision de leurs dates baisse.
        while state.absences.count > Self.absenceCapacity {
            let second = state.absences.remove(at: 1)
            state.absences[0] = Self.merged(state.absences[0], second)
        }
        lastCatchUp = absence
        log(.info, "Rattrapage : au moins \(Self.volume(absence.totalBytes)) hors de l’app.", at: date)
    }

    private static func merged(_ first: AbsenceUsage, _ second: AbsenceUsage) -> AbsenceUsage {
        let volumes = InterfaceClass.allCases.compactMap { kind -> NetworkVolume? in
            let parts = [first.volume(of: kind), second.volume(of: kind)].compactMap { $0 }
            guard !parts.isEmpty else { return nil }
            return NetworkVolume(
                kind: kind,
                receivedBytes: parts.reduce(0) { $0.saturatingAdd($1.receivedBytes) },
                sentBytes: parts.reduce(0) { $0.saturatingAdd($1.sentBytes) })
        }
        return AbsenceUsage(
            id: first.id, start: min(first.start, second.start), end: max(first.end, second.end),
            volumes: volumes)
    }

    /// La part d'une absence qui tombe dans `[from, to[`, au prorata du temps.
    private static func share(of absence: AbsenceUsage, from: Date, to: Date) -> Double {
        let duration = absence.duration
        guard duration > 0 else {
            return absence.start >= from && absence.start < to ? 1 : 0
        }
        let overlap = min(absence.end, to).timeIntervalSince(max(absence.start, from))
        return overlap <= 0 ? 0 : min(1, overlap / duration)
    }

    private static func scaled(_ bytes: UInt64, by share: Double) -> UInt64 {
        // Une absence entière garde ses octets exacts.
        guard share < 1 else { return bytes }
        return UInt64((Double(bytes) * share).rounded())
    }

    /// Le volume rattrapé hors de l'app sur une famille d'interfaces, dans `[from, to[`.
    private func outsideVolume(of kind: InterfaceClass, from: Date, to: Date) -> (received: UInt64, sent: UInt64) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for absence in state.absences {
            guard let volume = absence.volume(of: kind) else { continue }
            let share = Self.share(of: absence, from: from, to: to)
            guard share > 0 else { continue }
            received = received.saturatingAdd(Self.scaled(volume.receivedBytes, by: share))
            sent = sent.saturatingAdd(Self.scaled(volume.sentBytes, by: share))
        }
        return (received, sent)
    }

    // MARK: Volume par réseau

    /// La suite la plus fine qui couvre encore `from`.
    private func networkSeries(coveringFrom from: Date, at date: Date) -> NetworkSeries {
        from >= hourCutoff(at: date) ? state.networkHours : state.networkDays
    }

    /// Le volume de `[from, to[` par réseau, du plus gros au plus petit. Les réseaux sans
    /// volume sont omis ; `.sharing` n'y figure jamais.
    public func usageByNetwork(from: Date, to: Date) -> [NetworkUsage] {
        var measured: [InterfaceClass: (received: UInt64, sent: UInt64)] = [:]
        for bucket in networkSeries(coveringFrom: from, at: now()).slice(from: from, to: to) {
            let total = measured[bucket.kind] ?? (0, 0)
            measured[bucket.kind] = (
                total.received.saturatingAdd(bucket.receivedBytes), total.sent.saturatingAdd(bucket.sentBytes)
            )
        }
        let usages = InterfaceClass.allCases.compactMap { kind -> NetworkUsage? in
            guard kind != .sharing else { return nil }
            let inside = measured[kind] ?? (0, 0)
            let outside = outsideVolume(of: kind, from: from, to: to)
            let usage = NetworkUsage(
                kind: kind,
                receivedBytes: inside.received.saturatingAdd(outside.received),
                sentBytes: inside.sent.saturatingAdd(outside.sent),
                outsideAppBytes: outside.received.saturatingAdd(outside.sent))
            return usage.totalBytes > 0 ? usage : nil
        }
        // Le tri est stable sur l'ordre des familles : à volume égal, cet ordre reste.
        return usages.enumerated().sorted {
            $0.element.totalBytes != $1.element.totalBytes
                ? $0.element.totalBytes > $1.element.totalBytes : $0.offset < $1.offset
        }.map(\.element)
    }

    // MARK: Forfait

    public var dataPlan: DataPlan? {
        state.dataPlan
    }

    /// Enregistre le forfait, ou le retire (`nil`). Refuse un volume nul et un jour hors
    /// de 1 à 31 (`FluxaError.invalidPlan`). Changer le jour de remise à zéro efface le
    /// recalage ; changer le seul volume le garde.
    public func setDataPlan(_ plan: DataPlan?) throws {
        if let plan {
            guard plan.allowanceBytes > 0 else {
                throw FluxaError.invalidPlan("Le volume du forfait doit être supérieur à zéro.")
            }
            guard (1...31).contains(plan.resetDay) else {
                throw FluxaError.invalidPlan("Le jour de remise à zéro va de 1 à 31.")
            }
        }
        if plan?.resetDay != state.dataPlan?.resetDay {
            // Le recalage valait pour un cycle qui n'est plus le même.
            state.planCalibration = nil
        }
        state.dataPlan = plan
        saveQuietly()
    }

    /// Recale le volume du cycle en cours sur ce que l'opérateur indique : le volume
    /// utilisé vaut alors ce nombre, plus ce qui est mesuré et rattrapé ensuite.
    /// Sans forfait : `FluxaError.invalidPlan`.
    public func calibratePlan(usedBytes: UInt64) throws {
        let date = now()
        guard let plan = state.dataPlan, let cycle = planCycle(resetDay: plan.resetDay, at: date) else {
            throw FluxaError.invalidPlan("Réglez d’abord votre forfait.")
        }
        let counted = cycleVolume(from: cycle.start, at: date)
        state.planCalibration = PlanCalibration(
            date: date, usedBytes: usedBytes, measuredBefore: counted.measured, outsideBefore: counted.outside)
        saveQuietly()
    }

    /// L'état du forfait à l'instant. `nil` sans forfait.
    public func planStatus() -> PlanStatus? {
        planStatus(at: now())
    }

    func planStatus(at date: Date) -> PlanStatus? {
        planStatusComputations += 1
        guard let plan = state.dataPlan, let cycle = planCycle(resetDay: plan.resetDay, at: date) else {
            return nil
        }
        var counted = cycleVolume(from: cycle.start, at: date)
        // Un recalage fait dans un cycle passé ne vaut plus.
        var calibrated: UInt64?
        if let calibration = state.planCalibration, calibration.date >= cycle.start, calibration.date <= date {
            calibrated = calibration.usedBytes
            // Ce qui était déjà compté au moment du recalage est compris dans son nombre.
            counted.measured = counted.measured >= calibration.measuredBefore
                ? counted.measured - calibration.measuredBefore : 0
            counted.outside = counted.outside >= calibration.outsideBefore
                ? counted.outside - calibration.outsideBefore : 0
        }
        let used = (calibrated ?? 0).saturatingAdd(counted.measured).saturatingAdd(counted.outside)
        let remaining = plan.allowanceBytes > used ? plan.allowanceBytes - used : 0
        let daysRemaining = max(1, Int((cycle.end.timeIntervalSince(date) / 86_400).rounded(.up)))

        let elapsed = date.timeIntervalSince(cycle.start)
        var projected: UInt64?
        var exhaustion: Date?
        if elapsed >= 86_400 {
            let estimate = Double(used) / elapsed * cycle.duration
            projected = estimate >= Double(UInt64.max) ? .max : UInt64(estimate.rounded())
        }
        if used >= plan.allowanceBytes {
            exhaustion = date
        } else if let projected, projected > plan.allowanceBytes, used > 0 {
            // Au même rythme : le forfait est atteint quand le temps écoulé a grandi dans
            // le rapport du forfait au volume utilisé.
            exhaustion = cycle.start.addingTimeInterval(elapsed * Double(plan.allowanceBytes) / Double(used))
        }

        return PlanStatus(
            plan: plan, cycleStart: cycle.start, cycleEnd: cycle.end, usedBytes: used,
            measuredBytes: counted.measured, outsideAppBytes: counted.outside, calibratedBytes: calibrated,
            remainingBytes: remaining, fractionUsed: Double(used) / Double(plan.allowanceBytes),
            daysRemaining: daysRemaining, dailyBudgetBytes: remaining / UInt64(daysRemaining),
            projectedBytes: projected, exhaustionDate: exhaustion)
    }

    /// Le cellulaire du cycle commencé à `start`, jusqu'à `date` : mesuré dans l'app, et
    /// rattrapé hors de l'app.
    private func cycleVolume(from start: Date, at date: Date) -> (measured: UInt64, outside: UInt64) {
        var measured: UInt64 = 0
        // Jusqu'au futur lointain : la période en cours a commencé avant `date`.
        for bucket in networkSeries(coveringFrom: start, at: date).slice(from: start, to: .distantFuture)
        where bucket.kind == .cellular {
            measured = measured.saturatingAdd(bucket.receivedBytes).saturatingAdd(bucket.sentBytes)
        }
        // Une absence finit au relevé de sa reprise, qui peut porter la date du moment.
        let outside = outsideVolume(of: .cellular, from: start, to: .distantFuture)
        return (measured, outside.received.saturatingAdd(outside.sent))
    }

    /// Le cycle du forfait qui contient `date` : de minuit local du jour de remise à
    /// zéro à celui du mois suivant. Dans un mois plus court que `resetDay`, la remise à
    /// zéro tombe son dernier jour.
    func planCycle(resetDay: Int, at date: Date) -> DateInterval? {
        guard let month = calendar.dateInterval(of: .month, for: date)?.start,
            let thisReset = resetDate(inMonthStarting: month, resetDay: resetDay)
        else { return nil }
        let neighbour = calendar.date(byAdding: .month, value: date >= thisReset ? 1 : -1, to: month)
        guard let neighbour, let otherReset = resetDate(inMonthStarting: neighbour, resetDay: resetDay)
        else { return nil }
        let start = min(thisReset, otherReset)
        let end = max(thisReset, otherReset)
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    private func resetDate(inMonthStarting month: Date, resetDay: Int) -> Date? {
        guard let days = calendar.range(of: .day, in: .month, for: month)?.count else { return nil }
        return calendar.date(byAdding: .day, value: min(max(resetDay, 1), days) - 1, to: month)
            .map(calendar.startOfDay(for:))
    }

    // MARK: Partage de connexion

    /// Le partage en cours, d'après le dernier relevé. `nil` si aucune interface de
    /// partage n'y figurait, ou si la mesure est arrêtée.
    public var sharingStatus: SharingStatus? {
        guard isMonitoring, sharingPresent, let session = state.currentSharing else { return nil }
        return SharingStatus(
            session: session, toDevicesBps: sharingRate?.toDevicesBps,
            fromDevicesBps: sharingRate?.fromDevicesBps)
    }

    /// Les sessions terminées, de la plus récente à la plus ancienne.
    public func sharingSessions(limit: Int) -> [SharingSession] {
        guard limit > 0 else { return [] }
        return Array(state.sharingSessions.suffix(limit).reversed())
    }

    /// Suit la session de partage d'un relevé à l'autre.
    ///
    /// - Parameters:
    ///   - deltas: les différences du relevé ; `nil` pour un relevé de base.
    ///   - isResume: si ce relevé reprend la mesure après une interruption.
    ///   - checkpoint: le point de reprise, quand il se compare à ce relevé.
    func followSharing(
        _ readings: [InterfaceReading], deltas: InterfaceMeter.Deltas?, isResume: Bool,
        checkpoint: CounterCheckpoint?, at date: Date
    ) {
        // Le plus souvent, aucun pont : rien à construire pour ce relevé.
        var bridges: [InterfaceReading] = []
        if readings.contains(where: { $0.kind == .sharing }) {
            var seen = Set<String>()
            bridges = readings.filter { $0.kind == .sharing && seen.insert($0.name).inserted }
        }
        sharingPresent = !bridges.isEmpty
        sharingRate = nil

        if isResume, var session = state.currentSharing {
            if let checkpoint, sharingPresent {
                // Le partage a continué pendant l'interruption : son volume se rattrape.
                for bridge in bridges {
                    guard let before = checkpoint.counter(named: bridge.name) else { continue }
                    session.toDevicesBytes = session.toDevicesBytes.saturatingAdd(
                        CounterCheckpoint.lowerBound(from: before.sentBytes, to: bridge.sentBytes))
                    session.fromDevicesBytes = session.fromDevicesBytes.saturatingAdd(
                        CounterCheckpoint.lowerBound(from: before.receivedBytes, to: bridge.receivedBytes))
                }
                session.end = date
                session.isLowerBound = true
                state.currentSharing = session
            } else {
                // Appareil redémarré, ou partage coupé entre-temps : la session s'est
                // terminée à son dernier relevé.
                closeSharing(at: date)
            }
        }

        guard sharingPresent else {
            if state.currentSharing != nil {
                closeSharing(at: date)
            }
            return
        }
        var session: SharingSession
        if let current = state.currentSharing {
            session = current
        } else {
            session = SharingSession(
                id: state.nextSharingSessionID, start: date, end: date, toDevicesBytes: 0,
                fromDevicesBytes: 0, isLowerBound: false)
            state.nextSharingSessionID += 1
            state.currentSharing = session
            log(.info, "Partage de connexion détecté.", at: date)
        }
        // Un pont qui vient d'apparaître n'a pas encore de différence : la session ouvre
        // à zéro. Une session rouverte après un effacement compte dès ce relevé.
        guard !isResume, let deltas else { return }

        var toDevices: UInt64 = 0
        var fromDevices: UInt64 = 0
        var measured = false
        for delta in deltas.interfaces where delta.kind == .sharing {
            // Le pont envoie vers les appareils reliés et reçoit d'eux.
            toDevices = toDevices.saturatingAdd(delta.sentBytes)
            fromDevices = fromDevices.saturatingAdd(delta.receivedBytes)
            measured = true
        }
        if measured {
            session.toDevicesBytes = session.toDevicesBytes.saturatingAdd(toDevices)
            session.fromDevicesBytes = session.fromDevicesBytes.saturatingAdd(fromDevices)
            sharingRate = (Double(toDevices) * 8 / deltas.seconds, Double(fromDevices) * 8 / deltas.seconds)
        }
        session.end = date
        state.currentSharing = session
    }

    private func closeSharing(at date: Date) {
        guard let session = state.currentSharing else { return }
        state.currentSharing = nil
        state.sharingSessions.append(session)
        if state.sharingSessions.count > Self.sharingSessionCapacity {
            state.sharingSessions.removeFirst(state.sharingSessions.count - Self.sharingSessionCapacity)
        }
        log(.info, "Partage de connexion : session terminée.", at: date)
    }

    // MARK: Effacement

    /// Pour `eraseHistory` : le volume par réseau, les absences, les sessions de partage
    /// et le recalage du forfait. Le forfait reste.
    func eraseVolumes() {
        state.networkHours.removeAll()
        state.networkDays.removeAll()
        state.absences.removeAll()
        state.sharingSessions.removeAll()
        // Un partage en cours ouvrira une session neuve au prochain relevé.
        state.currentSharing = nil
        state.planCalibration = nil
        lastCatchUp = nil
        sharingRate = nil
        if !isMonitoring {
            // Mesure arrêtée, le point de reprise date d'avant l'effacement : le garder
            // ferait revenir, à la reprise, un volume antérieur à l'effacement.
            state.checkpoint = nil
        }
    }
}

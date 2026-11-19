import Foundation

// Les automatisations : des règles évaluées sur les données locales. Sur iPhone, elles
// changent le profil choisi et préviennent l'utilisateur ; elles n'agissent pas sur le
// partage de connexion.
//
// CONTRAT : les types de ce fichier et les signatures publiques de l'extension de
// `FluxaEngine` sont utilisés par l'interface.
//
// Comment plusieurs règles se combinent : chaque règle qui choisit un profil retient
// l'état d'avant elle (profil actif et limite en cours). La dernière déclenchée
// l'emporte. Quand une règle se termine :
//   - si une règle déclenchée après elle tient encore son profil, rien ne change : cette
//     règle-là reviendra, à sa fin, à l'état d'avant la règle terminée ;
//   - sinon, si le profil actif est encore celui qu'elle a posé, l'état d'avant revient
//     (le profil précédent, la limite manuelle précédente, ou plus aucun profil) ;
//   - sinon l'utilisateur a choisi autre chose entre-temps : son choix est conservé.

/// Une règle : un déclencheur et ce qu'il provoque.
public struct AutomationRule: Identifiable, Codable, Equatable, Sendable {
    /// Vide pour une règle pas encore enregistrée.
    public var id: String
    public var name: String
    public var isEnabled: Bool
    public var trigger: Trigger
    public var action: Action

    public enum Trigger: Codable, Equatable, Sendable {
        /// Le volume reçu et envoyé depuis minuit atteint ce nombre d'octets.
        case dailyUsage(bytes: UInt64)
        /// Une plage horaire, en minutes depuis minuit (0 à 1439). Si la fin précède le
        /// début, la plage passe minuit. `weekdays` suit `Calendar` (1 : dimanche … 7 :
        /// samedi) et désigne le jour où la plage commence ; vide : tous les jours.
        case schedule(startMinute: Int, endMinute: Int, weekdays: Set<Int>)
    }

    public enum Action: Codable, Equatable, Sendable {
        /// Prévenir, sans rien changer.
        case alert
        /// Choisir ce profil. Pour une plage horaire, le profil précédent revient à la
        /// fin de la plage. Pour un seuil de volume, il revient le lendemain.
        case activateProfile(id: String)
    }

    public init(id: String = "", name: String, isEnabled: Bool = true, trigger: Trigger, action: Action) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.action = action
    }
}

/// Ce qu'une règle a fait, pour le journal et pour prévenir l'utilisateur.
public struct AutomationEvent: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Le seuil est atteint, ou la plage commence.
        case started
        /// La plage se termine, ou la journée du seuil est passée : le profil précédent revient.
        case ended
    }

    public var id: Int
    public var date: Date
    public var ruleID: String
    public var ruleName: String
    public var kind: Kind
    /// Une phrase en français, prête à afficher.
    public var message: String

    public init(id: Int, date: Date, ruleID: String, ruleName: String, kind: Kind, message: String) {
        self.id = id
        self.date = date
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.kind = kind
        self.message = message
    }
}

/// Une règle en cours d'effet : ce qu'elle a posé, et l'état à rendre quand elle se termine.
struct RuleActivation: Codable, Equatable, Sendable {
    var ruleID: String
    var since: Date
    /// La fin de la plage, ou le début de la journée suivante pour un seuil de volume.
    var until: Date
    /// Le profil choisi par la règle. `nil` : elle ne fait que prévenir, ou son profil
    /// n'existe plus.
    var appliedProfileID: String?
    /// Le profil actif avant la règle.
    var previousProfileID: String?
    /// La réponse à la dernière demande de limite avant la règle.
    var previousResult: ApplyResult?
}

extension FluxaEngine {
    /// Nombre d'événements de règles gardés dans le journal.
    static let automationLogCapacity = 200
    /// Nombre de tests de débit gardés.
    static let speedTestCapacity = 50

    /// Les règles, dans l'ordre de leur création.
    public var automationRules: [AutomationRule] { state.rules }

    /// Crée une règle (`id` vide) ou remplace celle qui porte cet identifiant. Refuse un
    /// nom vide, un seuil nul, une plage vide ou hors de la journée, un jour de semaine
    /// hors de 1 à 7, et un profil inconnu.
    @discardableResult
    public func saveRule(_ rule: AutomationRule) throws -> AutomationRule {
        var rule = rule
        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(rule)

        if rule.id.isEmpty {
            rule.id = state.makeRuleID()
            state.rules.append(rule)
        } else {
            guard let index = state.rules.firstIndex(where: { $0.id == rule.id }) else {
                throw FluxaError.invalidRule("Cette règle n’existe plus.")
            }
            let old = state.rules[index]
            // Une règle en cours d'effet rend d'abord la main, sauf si seul son nom change.
            if !rule.isEnabled {
                release(old, cause: .disabled)
            } else if old.trigger != rule.trigger || old.action != rule.action {
                release(old, cause: .modified)
            }
            state.rules[index] = rule
        }
        saveQuietly()
        return rule
    }

    public func deleteRule(id: String) throws {
        guard let index = state.rules.firstIndex(where: { $0.id == id }) else {
            throw FluxaError.invalidRule("Cette règle n’existe plus.")
        }
        release(state.rules[index], cause: .deleted)
        state.rules.remove(at: index)
        saveQuietly()
    }

    /// Évalue les règles actives à l'instant de l'horloge du moteur. L'app l'appelle à
    /// chaque relevé. Renvoie les événements nouveaux, à signaler à l'utilisateur ; une
    /// règle ne se redéclenche pas tant que sa condition reste vraie.
    @discardableResult
    public func evaluateAutomations() -> [AutomationEvent] {
        let date = now()
        var new: [AutomationEvent] = []
        var changed = false

        // Les fins d'abord, de la règle la plus anciennement déclenchée à la plus récente.
        for activation in state.activations {
            guard let rule = state.rules.first(where: { $0.id == activation.ruleID }), rule.isEnabled
            else {
                // Règle disparue sans passer par `deleteRule` : son effet est retiré.
                _ = finish(ruleID: activation.ruleID, at: date)
                changed = true
                continue
            }
            guard date >= activation.until else { continue }
            if let event = end(rule, cause: .elapsed, at: date) {
                new.append(event)
            }
            changed = true
        }

        // Puis les débuts, dans l'ordre des règles.
        for rule in state.rules where rule.isEnabled {
            guard !state.activations.contains(where: { $0.ruleID == rule.id }),
                let until = conditionEnd(of: rule, at: date)
            else { continue }
            new.append(begin(rule, until: until, at: date))
            changed = true
        }

        if changed {
            saveQuietly()
        }
        return new
    }

    /// Les événements des règles, du plus récent au plus ancien.
    public func automationLog(limit: Int) -> [AutomationEvent] {
        guard limit > 0 else { return [] }
        return Array(state.automationLog.suffix(limit).reversed())
    }

    // MARK: Tests de débit

    /// Garde le résultat d'un test de débit (les cinquante plus récents sont conservés).
    public func recordSpeedTest(_ result: SpeedTestResult) {
        // La date sert d'identifiant : un résultat de même date remplace l'ancien.
        state.speedTests.removeAll { $0.date == result.date }
        state.speedTests.append(result)
        state.speedTests.sort { $0.date > $1.date }
        if state.speedTests.count > Self.speedTestCapacity {
            state.speedTests.removeLast(state.speedTests.count - Self.speedTestCapacity)
        }
        saveQuietly()
    }

    /// Les tests de débit, du plus récent au plus ancien.
    public var speedTests: [SpeedTestResult] { state.speedTests }

    // MARK: - Validation

    private func validate(_ rule: AutomationRule) throws {
        guard !rule.name.isEmpty else {
            throw FluxaError.invalidRule("Donnez un nom à la règle.")
        }
        switch rule.trigger {
        case .dailyUsage(let bytes):
            guard bytes > 0 else {
                throw FluxaError.invalidRule("Le seuil de volume doit être supérieur à zéro.")
            }
        case .schedule(let startMinute, let endMinute, let weekdays):
            guard (0...1439).contains(startMinute), (0...1439).contains(endMinute) else {
                throw FluxaError.invalidRule(
                    "Les heures de la plage doivent être comprises entre 00:00 et 23:59.")
            }
            guard startMinute != endMinute else {
                throw FluxaError.invalidRule("Le début et la fin de la plage doivent être différents.")
            }
            guard weekdays.allSatisfy((1...7).contains) else {
                throw FluxaError.invalidRule(
                    "Les jours de la semaine vont de 1 (dimanche) à 7 (samedi).")
            }
        }
        if case .activateProfile(let id) = rule.action {
            guard state.profiles.contains(where: { $0.id == id }) else {
                throw FluxaError.unknownProfile(id: id)
            }
        }
    }

    // MARK: - Conditions

    /// Si la condition de la règle est vraie à `date`, l'instant où son effet prendra fin.
    private func conditionEnd(of rule: AutomationRule, at date: Date) -> Date? {
        switch rule.trigger {
        case .dailyUsage(let bytes):
            let totals = todayTotals(at: date)
            guard totals.received.saturatingAdd(totals.sent) >= bytes else { return nil }
            let today = calendar.startOfDay(for: date)
            return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        case .schedule(let startMinute, let endMinute, let weekdays):
            return occurrence(
                startMinute: startMinute, endMinute: endMinute, weekdays: weekdays, at: date)?.end
        }
    }

    /// L'occurrence de la plage qui contient `date`. Une plage qui passe minuit a pu
    /// commencer la veille : `weekdays` désigne le jour de son début.
    private func occurrence(startMinute: Int, endMinute: Int, weekdays: Set<Int>, at date: Date)
        -> DateInterval?
    {
        let today = calendar.startOfDay(for: date)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        for case let dayStart? in [today, yesterday] {
            let weekday = calendar.component(.weekday, from: dayStart)
            guard weekdays.isEmpty || weekdays.contains(weekday) else { continue }
            let endDay =
                endMinute > startMinute ? dayStart : calendar.date(byAdding: .day, value: 1, to: dayStart)
            guard let start = time(startMinute, on: dayStart), let endDay,
                let end = time(endMinute, on: endDay), end > start
            else { continue }
            if date >= start, date < end {
                return DateInterval(start: start, end: end)
            }
        }
        return nil
    }

    private func time(_ minute: Int, on dayStart: Date) -> Date? {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: dayStart)
    }

    // MARK: - Début et fin d'une règle

    private enum EndCause {
        case elapsed, disabled, modified, deleted
    }

    /// Ce qu'il advient du profil quand une règle se termine.
    private enum Outcome {
        /// La règle ne faisait que prévenir.
        case nothingToRestore
        /// Une règle déclenchée après elle tient encore son profil.
        case heldByAnotherRule
        /// L'utilisateur a choisi autre chose pendant la règle.
        case userChoiceKept
        /// Le profil d'avant était déjà celui de la règle.
        case unchanged(profileName: String)
        case profileRestored(name: String)
        /// La limite réglée à la main avant la règle revient.
        case limitRestored
        case noProfile
    }

    private func begin(_ rule: AutomationRule, until: Date, at date: Date) -> AutomationEvent {
        var activation = RuleActivation(ruleID: rule.id, since: date, until: until)
        var effect = "."
        if case .activateProfile(let id) = rule.action {
            if let profile = state.profiles.first(where: { $0.id == id }) {
                activation.previousProfileID = state.activeProfileID
                activation.previousResult = state.lastApplyResult
                if state.activeProfileID != id {
                    // Même chemin qu'un choix de l'utilisateur : la limite est simulée.
                    request(profile.policy, forDevice: false)
                    state.activeProfileID = id
                }
                activation.appliedProfileID = id
                effect = " : profil \(profile.name) choisi."
            } else {
                effect = " : le profil de la règle n’existe plus, rien n’est changé."
            }
        }
        state.activations.append(activation)

        let subject: String
        switch rule.trigger {
        case .dailyUsage(let bytes):
            subject = "Seuil de \(Self.volume(bytes)) atteint"
        case .schedule(let startMinute, let endMinute, _):
            subject = "Plage \(Self.range(startMinute, endMinute)) commencée"
        }
        return emit(rule, .started, subject + effect, at: date)
    }

    /// Termine une règle en cours d'effet et consigne l'événement, quand il y en a un.
    private func end(_ rule: AutomationRule, cause: EndCause, at date: Date) -> AutomationEvent? {
        guard let outcome = finish(ruleID: rule.id, at: date) else { return nil }

        let subject: String
        switch cause {
        case .disabled: subject = "Règle désactivée"
        case .modified: subject = "Règle modifiée"
        case .deleted: subject = "Règle supprimée"
        case .elapsed:
            switch rule.trigger {
            case .dailyUsage: subject = "Nouvelle journée"
            case .schedule(let startMinute, let endMinute, _):
                subject = "Plage \(Self.range(startMinute, endMinute)) terminée"
            }
        }

        // Une règle qui ne faisait que prévenir ne laisse une trace de fin que pour une
        // plage arrivée à son terme.
        if case .nothingToRestore = outcome {
            guard cause == .elapsed, case .schedule = rule.trigger else { return nil }
        }

        let effect: String
        switch outcome {
        case .nothingToRestore, .heldByAnotherRule: effect = "."
        case .userChoiceKept: effect = " : votre choix de profil est conservé."
        case .unchanged(let name): effect = " : le profil \(name) reste choisi."
        case .profileRestored(let name): effect = " : retour au profil \(name)."
        case .limitRestored: effect = " : retour à la limite précédente."
        case .noProfile: effect = " : plus aucun profil choisi."
        }
        return emit(rule, .ended, subject + effect, at: date)
    }

    /// Retire l'effet d'une règle modifiée, désactivée ou supprimée pendant qu'elle agit.
    private func release(_ rule: AutomationRule, cause: EndCause) {
        _ = end(rule, cause: cause, at: now())
    }

    /// Retire une règle de la pile et rend l'état d'avant elle, si c'est à elle de le
    /// faire. `nil` : la règle n'était pas en cours d'effet.
    private func finish(ruleID: String, at date: Date) -> Outcome? {
        guard let index = state.activations.firstIndex(where: { $0.ruleID == ruleID }) else {
            return nil
        }
        let activation = state.activations.remove(at: index)
        guard let applied = activation.appliedProfileID else { return .nothingToRestore }

        // Une règle déclenchée après elle tient un profil : elle hérite de l'état d'avant.
        if let later = state.activations[index...].firstIndex(where: { $0.appliedProfileID != nil }) {
            if state.activations[later].previousProfileID == applied {
                state.activations[later].previousProfileID = activation.previousProfileID
                state.activations[later].previousResult = activation.previousResult
            }
            return .heldByAnotherRule
        }
        guard state.activeProfileID == applied else { return .userChoiceKept }
        if activation.previousProfileID == applied {
            let name = state.profiles.first { $0.id == applied }?.name ?? applied
            return .unchanged(profileName: name)
        }

        if let previousID = activation.previousProfileID {
            if let profile = state.profiles.first(where: { $0.id == previousID }) {
                request(profile.policy, forDevice: false)
                state.activeProfileID = previousID
                return .profileRestored(name: profile.name)
            }
            // Le profil d'avant a été supprimé entre-temps.
            state.activeProfileID = nil
            state.lastApplyResult = nil
            return .noProfile
        }

        state.activeProfileID = nil
        if let result = activation.previousResult, !Self.isExpired(result, at: date) {
            state.lastApplyResult = result
            return .limitRestored
        }
        state.lastApplyResult = nil
        return .noProfile
    }

    private static func isExpired(_ result: ApplyResult, at date: Date) -> Bool {
        guard let seconds = result.requested.durationSeconds else { return false }
        return date >= result.date.addingTimeInterval(Double(seconds))
    }

    private func emit(_ rule: AutomationRule, _ kind: AutomationEvent.Kind, _ message: String, at date: Date)
        -> AutomationEvent
    {
        let event = AutomationEvent(
            id: state.nextAutomationEventID, date: date, ruleID: rule.id, ruleName: rule.name,
            kind: kind, message: message)
        state.nextAutomationEventID += 1
        state.automationLog.append(event)
        if state.automationLog.count > Self.automationLogCapacity {
            state.automationLog.removeFirst(state.automationLog.count - Self.automationLogCapacity)
        }
        log(.info, "Règle « \(rule.name) » : \(message)", at: date)
        return event
    }

    // MARK: - Mise en forme

    /// Un volume en unités décimales : « 2 Go », « 1,5 Go », « 500 Mo ».
    static func volume(_ bytes: UInt64) -> String {
        let units: [(size: Double, name: String)] = [(1e9, "Go"), (1e6, "Mo"), (1e3, "ko")]
        for unit in units where Double(bytes) >= unit.size {
            var text = String(format: "%.2f", Double(bytes) / unit.size)
            while text.hasSuffix("0") {
                text.removeLast()
            }
            if text.hasSuffix(".") {
                text.removeLast()
            }
            return "\(text.replacingOccurrences(of: ".", with: ",")) \(unit.name)"
        }
        return "\(bytes) o"
    }

    /// Une plage horaire : « 22:00–07:00 ».
    static func range(_ startMinute: Int, _ endMinute: Int) -> String {
        let clock = { (minute: Int) in String(format: "%02d:%02d", minute / 60, minute % 60) }
        return "\(clock(startMinute))–\(clock(endMinute))"
    }
}

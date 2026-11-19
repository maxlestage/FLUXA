import FluxaCore
import SwiftUI

/// Les automatisations : des règles sur le volume consommé ou sur l'heure, qui
/// préviennent ou changent le profil choisi.
struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: RuleDraft?

    var body: some View {
        List {
            Section {
                if model.rules.isEmpty {
                    Text("Aucune règle. Ajoutez-en une avec le bouton +.")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(model.rules) { rule in
                    HStack(spacing: 12) {
                        Button {
                            draft = RuleDraft(rule)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.name)
                                    .foregroundStyle(Theme.text)
                                Text(RuleText.summary(of: rule, profiles: model.profiles))
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Toggle(
                            "Activer \(rule.name)",
                            isOn: Binding(
                                get: { rule.isEnabled },
                                set: { model.setRule(rule, enabled: $0) }
                            )
                        )
                        .labelsHidden()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.deleteRule(rule)
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Règles")
            } footer: {
                Text("Les règles sont évaluées quand FLUXA est ouvert : iOS suspend l’app en arrière-plan. Elles changent le profil choisi dans l’app ; elles n’agissent pas sur le partage de connexion.")
            }

            Section {
                Toggle(
                    "Me prévenir par une notification",
                    isOn: Binding(
                        get: { model.notifiesAutomations },
                        set: { enabled in Task { await model.setNotifications(enabled) } }
                    )
                )
                if model.notificationAccess == .denied {
                    Text("Les notifications de FLUXA sont refusées dans Réglages. Autorisez-les pour être prévenu.")
                        .font(.footnote)
                        .foregroundStyle(Theme.reserved)
                }
            }

            Section("Journal") {
                if model.automationEvents.isEmpty {
                    Text("Aucune règle ne s’est encore déclenchée.")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(model.automationEvents) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.ruleName)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(Format.dateTime(event.date))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                        }
                        Text(event.message)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .fluxaBackground()
        .navigationTitle("Automatisations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    draft = RuleDraft(defaultProfile: model.profiles.first?.id)
                } label: {
                    Label("Nouvelle règle", systemImage: "plus")
                }
            }
        }
        .sheet(item: $draft) { draft in
            RuleEditor(draft: draft)
        }
        .task {
            await model.refreshNotificationAccess()
        }
    }
}

/// Une règle en cours de saisie.
struct RuleDraft: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case usage, schedule
        var id: String { rawValue }
        var title: String { self == .usage ? "Seuil de volume" : "Plage horaire" }
    }

    enum Unit: UInt64, CaseIterable, Identifiable {
        case megabytes = 1_000_000
        case gigabytes = 1_000_000_000
        var id: UInt64 { rawValue }
        var title: String { self == .megabytes ? "Mo" : "Go" }
    }

    let id = UUID()
    var ruleID = ""
    var name = ""
    var isEnabled = true
    var kind = Kind.usage
    var amount = 1.0
    var unit = Unit.gigabytes
    var start = RuleDraft.time(minutes: 22 * 60)
    var end = RuleDraft.time(minutes: 7 * 60)
    var weekdays: Set<Int> = []
    var changesProfile = false
    var profileID: String?

    init(defaultProfile: String?) {
        profileID = defaultProfile
    }

    init(_ rule: AutomationRule) {
        ruleID = rule.id
        name = rule.name
        isEnabled = rule.isEnabled
        switch rule.trigger {
        case .dailyUsage(let bytes):
            kind = .usage
            unit = bytes >= Unit.gigabytes.rawValue ? .gigabytes : .megabytes
            amount = Double(bytes) / Double(unit.rawValue)
        case .schedule(let startMinute, let endMinute, let days):
            kind = .schedule
            start = Self.time(minutes: startMinute)
            end = Self.time(minutes: endMinute)
            weekdays = days
        }
        switch rule.action {
        case .alert:
            changesProfile = false
        case .activateProfile(let id):
            changesProfile = true
            profileID = id
        }
    }

    /// La règle décrite par la saisie.
    var rule: AutomationRule {
        let trigger: AutomationRule.Trigger
        switch kind {
        case .usage:
            let bytes = amount.isFinite && amount > 0 ? amount * Double(unit.rawValue) : 0
            trigger = .dailyUsage(bytes: UInt64(min(bytes, 1e15).rounded()))
        case .schedule:
            trigger = .schedule(
                startMinute: Self.minutes(of: start),
                endMinute: Self.minutes(of: end),
                weekdays: weekdays
            )
        }
        let action: AutomationRule.Action
        if changesProfile, let profileID {
            action = .activateProfile(id: profileID)
        } else {
            action = .alert
        }
        return AutomationRule(id: ruleID, name: name, isEnabled: isEnabled, trigger: trigger, action: action)
    }

    static func time(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    static func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

private struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: RuleDraft
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Nom") {
                    TextField("Nom de la règle", text: $draft.name)
                }

                Section("Quand") {
                    Picker("Déclencheur", selection: $draft.kind) {
                        ForEach(RuleDraft.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch draft.kind {
                    case .usage:
                        LabeledContent("Volume du jour") {
                            HStack(spacing: 8) {
                                TextField("Volume", value: $draft.amount, format: .number.locale(Format.locale))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .font(.body.monospacedDigit())
                                    .frame(maxWidth: 90)
                                Picker("Unité", selection: $draft.unit) {
                                    ForEach(RuleDraft.Unit.allCases) { unit in
                                        Text(unit.title).tag(unit)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    case .schedule:
                        DatePicker("Début", selection: $draft.start, displayedComponents: .hourAndMinute)
                        DatePicker("Fin", selection: $draft.end, displayedComponents: .hourAndMinute)
                        WeekdayPicker(selection: $draft.weekdays)
                    }
                }

                Section {
                    Toggle("Choisir un profil", isOn: $draft.changesProfile)
                    if draft.changesProfile {
                        Picker("Profil", selection: $draft.profileID) {
                            ForEach(model.profiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                    }
                } header: {
                    Text("Alors")
                } footer: {
                    Text(draft.changesProfile
                        ? "Le profil précédent revient à la fin de la plage, ou le lendemain pour un seuil."
                        : "La règle vous prévient, sans rien changer.")
                }

                if let problem {
                    Section {
                        Text(problem)
                            .foregroundStyle(Theme.reserved)
                            .accessibilityIdentifier("erreur-regle")
                    }
                }
            }
            .fluxaBackground()
            .navigationTitle(draft.ruleID.isEmpty ? "Nouvelle règle" : "Modifier la règle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        problem = model.saveRule(draft.rule)
                        if problem == nil { dismiss() }
                    }
                }
            }
        }
    }
}

/// Les jours de la semaine, du lundi au dimanche. Aucun jour choisi : tous les jours.
private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    /// Les numéros de `Calendar` (1 : dimanche), dans l'ordre français.
    private let days: [(number: Int, letter: String, name: String)] = [
        (2, "L", "Lundi"), (3, "M", "Mardi"), (4, "M", "Mercredi"), (5, "J", "Jeudi"),
        (6, "V", "Vendredi"), (7, "S", "Samedi"), (1, "D", "Dimanche"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(days, id: \.number) { day in
                    let isOn = selection.contains(day.number)
                    Button {
                        if isOn {
                            selection.remove(day.number)
                        } else {
                            selection.insert(day.number)
                        }
                    } label: {
                        Text(day.letter)
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .foregroundStyle(isOn ? Theme.background : Theme.secondary)
                            .background(isOn ? Theme.down : Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day.name)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            Text(selection.isEmpty ? "Tous les jours" : "Les jours choisis")
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
        }
    }
}

/// La description d'une règle, en une phrase.
enum RuleText {
    static func summary(of rule: AutomationRule, profiles: [Profile]) -> String {
        let when: String
        switch rule.trigger {
        case .dailyUsage(let bytes):
            when = "À \(Format.bytes(bytes)) dans la journée"
        case .schedule(let start, let end, let weekdays):
            let days = weekdays.isEmpty ? "tous les jours" : "\(weekdays.count) jour\(weekdays.count > 1 ? "s" : "") par semaine"
            when = "De \(clock(start)) à \(clock(end)), \(days)"
        }
        let then: String
        switch rule.action {
        case .alert:
            then = "prévenir"
        case .activateProfile(let id):
            let name = profiles.first { $0.id == id }?.name ?? "profil supprimé"
            then = "profil \(name)"
        }
        return "\(when) : \(then)"
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

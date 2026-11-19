import FluxaCore
import SwiftUI

/// Le forfait mobile : son volume, son jour de remise à zéro, et où en est le cycle.
///
/// FLUXA ne lit pas le compteur de l'opérateur. Il additionne ce qu'il mesure sur le
/// réseau mobile, ce qu'il rattrape d'après les compteurs du système quand l'app était
/// fermée, et le recalage que l'utilisateur saisit.
struct PlanView: View {
    @Environment(AppModel.self) private var model
    // Les volumes sont saisis en texte et lus au moment d'enregistrer : un champ numérique
    // ne rend sa valeur qu'en perdant le curseur, après le toucher du bouton.
    @State private var allowance = ""
    @State private var resetDay = 1
    @State private var operatorUsage = ""
    @State private var problem: String?
    @State private var confirmsRemoval = false
    @FocusState private var isEditing: Bool

    var body: some View {
        Form {
            if let status = model.plan {
                Section {
                    PlanGauge(status: status)
                        .padding(.vertical, 4)
                    ValueRow("Reste", Format.bytes(status.remainingBytes))
                    ValueRow("Remise à zéro", PlanText.reset(status))
                    ValueRow("Budget par jour", Format.bytes(status.dailyBudgetBytes))
                } header: {
                    Text("Cycle en cours")
                } footer: {
                    Text(PlanText.projection(status))
                }

                Section {
                    ValueRow("Mesuré dans l’app", Format.bytes(status.measuredBytes))
                    ValueRow("Rattrapé hors de l’app", PlanText.atLeast(status.outsideAppBytes))
                    if let calibrated = status.calibratedBytes {
                        ValueRow("Recalage", Format.bytes(calibrated))
                    }
                } header: {
                    Text("D’où vient ce total")
                } footer: {
                    Text("Hors de l’app, FLUXA lit les compteurs du système à votre retour. Ils repartent de zéro tous les 4 Go et au redémarrage de l’iPhone : ce volume est un minimum. Recalez le total sur celui de votre opérateur quand vous le souhaitez.")
                }
            }

            Section {
                LabeledContent("Volume") {
                    HStack(spacing: 6) {
                        TextField("50", text: $allowance)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: 90)
                            .focused($isEditing)
                            .accessibilityIdentifier("volume-forfait")
                        Text("Go")
                            .foregroundStyle(Theme.secondary)
                    }
                }
                Picker("Remise à zéro le", selection: $resetDay) {
                    ForEach(1...31, id: \.self) { day in
                        Text("\(day)").tag(day)
                    }
                }
                Button(model.plan == nil ? "Suivre ce forfait" : "Enregistrer le forfait") {
                    save()
                }
                .accessibilityIdentifier("enregistrer-forfait")
            } header: {
                Text("Mon forfait")
            } footer: {
                Text("Le jour où votre opérateur remet le compteur à zéro. Dans un mois plus court, c’est son dernier jour.")
            }

            if model.plan != nil {
                Section {
                    LabeledContent("Mon opérateur indique") {
                        HStack(spacing: 6) {
                            TextField("0", text: $operatorUsage)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.body.monospacedDigit())
                                .frame(maxWidth: 90)
                                .focused($isEditing)
                                .accessibilityIdentifier("volume-operateur")
                            Text("Go")
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    Button("Recaler le total") {
                        calibrate()
                    }
                    .disabled(operatorUsage.isEmpty)
                } header: {
                    Text("Recalage")
                } footer: {
                    Text("Saisissez le volume utilisé que donne votre opérateur : FLUXA repart de ce nombre pour le reste du cycle.")
                }
            }

            if let problem {
                Section {
                    Text(problem)
                        .foregroundStyle(Theme.reserved)
                        .accessibilityIdentifier("erreur-forfait")
                }
            }

            if model.plan != nil {
                Section {
                    Button("Ne plus suivre le forfait", role: .destructive) {
                        confirmsRemoval = true
                    }
                    .confirmationDialog(
                        "Ne plus suivre le forfait ?",
                        isPresented: $confirmsRemoval,
                        titleVisibility: .visible
                    ) {
                        Button("Ne plus suivre", role: .destructive) {
                            problem = model.setDataPlan(nil)
                        }
                    } message: {
                        Text("Vos mesures sont conservées. Les règles liées au forfait ne se déclencheront plus.")
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .fluxaBackground()
        .navigationTitle("Forfait mobile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Terminé") { isEditing = false }
            }
        }
        .onAppear {
            guard let plan = model.dataPlan else { return }
            allowance = PlanText.field(plan.allowanceBytes)
            resetDay = plan.resetDay
        }
    }

    private func save() {
        isEditing = false
        guard let bytes = PlanText.bytes(fromGigabytes: allowance), bytes > 0 else {
            problem = "Indiquez le volume de votre forfait, en gigaoctets."
            return
        }
        problem = model.setDataPlan(DataPlan(allowanceBytes: bytes, resetDay: resetDay))
    }

    private func calibrate() {
        isEditing = false
        guard let bytes = PlanText.bytes(fromGigabytes: operatorUsage) else {
            problem = "Indiquez le volume utilisé, en gigaoctets."
            return
        }
        problem = model.calibratePlan(usedBytes: bytes)
        if problem == nil {
            operatorUsage = ""
        }
    }
}

/// La jauge du forfait : le volume utilisé sur le volume total, et une barre.
struct PlanGauge: View {
    let status: PlanStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.bytes(status.usedBytes))
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text("sur \(Format.gigabytes(status.plan.allowanceBytes))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text(Format.percent(status.fractionUsed * 100))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(PlanText.color(status))
            }
            ProgressView(value: min(max(status.fractionUsed, 0), 1))
                .tint(PlanText.color(status))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("jauge-forfait")
    }
}

/// Les phrases du forfait, séparées des écrans pour être testées.
enum PlanText {
    /// Le volume saisi en gigaoctets, en octets. `nil` : rien de saisi, ou une valeur
    /// négative ou démesurée.
    static func bytes(fromGigabytes text: String) -> UInt64? {
        // La virgule française comme le point sont acceptés.
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite, value >= 0, value <= 100_000 else { return nil }
        return UInt64((value * 1_000_000_000).rounded())
    }

    /// Un volume remis dans son champ de saisie, en gigaoctets : « 50 », « 12,5 ».
    static func field(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        return gigabytes.formatted(
            .number.precision(.fractionLength(0...3)).grouping(.never).locale(Format.locale))
    }

    /// « le 5 déc., dans 16 jours ».
    static func reset(_ status: PlanStatus) -> String {
        let days = status.daysRemaining
        let wait = days <= 1 ? "demain au plus tard" : "dans \(days) jours"
        return "le \(Format.day(status.cycleEnd)), \(wait)"
    }

    /// Ce que donne le rythme actuel en fin de cycle.
    static func projection(_ status: PlanStatus) -> String {
        if status.usedBytes >= status.plan.allowanceBytes {
            return "Le forfait est dépassé pour ce cycle."
        }
        guard let projected = status.projectedBytes else {
            return "La projection s’affiche après un jour de cycle."
        }
        let total = "À ce rythme : \(Format.bytes(projected)) en fin de cycle"
        if let exhaustion = status.exhaustionDate {
            return "\(total), forfait épuisé vers le \(Format.day(exhaustion))."
        }
        return "\(total), sous votre forfait."
    }

    /// Le résumé d'une ligne du tableau de bord : « Reste 37,6 Go · 16 jours ».
    static func summary(_ status: PlanStatus) -> String {
        if status.usedBytes >= status.plan.allowanceBytes {
            return "Forfait dépassé · remise à zéro le \(Format.day(status.cycleEnd))"
        }
        let days = status.daysRemaining
        return "Reste \(Format.bytes(status.remainingBytes)) · \(days) jour\(days > 1 ? "s" : "")"
    }

    /// Un volume rattrapé hors de l'app : toujours un minimum.
    static func atLeast(_ bytes: UInt64) -> String {
        bytes == 0 ? Format.bytes(0) : "au moins \(Format.bytes(bytes))"
    }

    /// Où en est le forfait : à l'aise, proche de la fin (80 %), ou atteint.
    enum Level: Equatable {
        case comfortable, close, reached
    }

    static func level(_ fraction: Double) -> Level {
        if fraction >= 1 { return .reached }
        if fraction >= 0.8 { return .close }
        return .comfortable
    }

    /// La couleur de la jauge : verte, orange à 80 %, rouge une fois le forfait atteint.
    static func color(_ status: PlanStatus) -> Color {
        switch level(status.fractionUsed) {
        case .reached: Theme.reserved
        case .close: Theme.up
        case .comfortable: Theme.ok
        }
    }
}

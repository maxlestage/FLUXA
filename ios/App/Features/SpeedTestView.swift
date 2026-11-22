import FluxaCore
import SwiftUI

/// Le test de débit : une mesure à la demande, et la liste des mesures précédentes.
struct SpeedTestView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsMeteredTest = false

    var body: some View {
        let runner = model.speedTest

        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Eyebrow(title(for: runner.phase))
                        Spacer()
                        if runner.phase.isRunning {
                            ProgressView()
                        }
                    }
                    Reading(
                        label: "↓ Descendant",
                        value: reading(final: runner.downloadBps, live: runner.phase == .download ? runner.liveBps : nil),
                        color: Theme.down
                    )
                    Reading(
                        label: "↑ Montant",
                        value: reading(final: runner.uploadBps, live: runner.phase == .upload ? runner.liveBps : nil),
                        color: Theme.up
                    )
                    HStack {
                        Text("Latence")
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(Format.milliseconds(runner.latencyMs))
                            .font(.body.monospacedDigit())
                    }
                    if case .failed(let message) = runner.phase {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Theme.reserved)
                            .accessibilityIdentifier("erreur-test")
                    }
                    if runner.phase == .finished {
                        Text("Test terminé · \(Format.bytes(runner.transferredBytes)) transférés")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .accessibilityIdentifier("test-termine")
                    }
                }
                .padding(.vertical, 6)

                if runner.phase.isRunning {
                    Button("Arrêter", role: .cancel) {
                        runner.cancel()
                    }
                } else {
                    Button {
                        // Sur un réseau facturé à l'usage, le volume du test se confirme.
                        if model.path.isExpensive {
                            confirmsMeteredTest = true
                        } else {
                            model.startSpeedTest()
                        }
                    } label: {
                        Label("Lancer le test", systemImage: "play.fill")
                    }
                    .disabled(!model.path.isOnline)
                    .confirmationDialog(
                        "Lancer le test sur ce réseau ?",
                        isPresented: $confirmsMeteredTest,
                        titleVisibility: .visible
                    ) {
                        Button("Lancer le test") {
                            model.startSpeedTest()
                        }
                    } message: {
                        Text(Self.meteredWarning(remaining: model.plan?.remainingBytes))
                    }
                }
            } footer: {
                Text(warning)
            }

            Section("Tests précédents") {
                if model.speedTests.isEmpty {
                    Text("Aucun test pour l’instant.")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(model.speedTests) { test in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(Format.dateTime(test.date))
                            Spacer()
                            Text(test.networkKind.title)
                                .font(.footnote)
                                .foregroundStyle(Theme.tertiary)
                        }
                        Text("↓ \(Format.rate(test.downloadBps)) · ↑ \(Format.rate(test.uploadBps)) · \(Format.milliseconds(test.latencyMs))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("test-precedent")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.deleteSpeedTest(test)
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .fluxaBackground()
        .navigationTitle("Test de débit")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Ce que coûte un test sur un réseau facturé à l'usage, et ce qu'il reste du forfait.
    static func meteredWarning(remaining: UInt64?) -> String {
        var text = "Ce réseau est facturé à l’usage : le test peut consommer jusqu’à 260 Mo de votre forfait."
        if let remaining {
            text += " Il vous reste \(Format.bytes(remaining)) d’après FLUXA."
        }
        return text
    }

    private func title(for phase: SpeedTestRunner.Phase) -> String {
        switch phase {
        case .idle: "Prêt"
        case .latency: "Mesure de la latence"
        case .download: "Téléchargement"
        case .upload: "Envoi"
        case .finished: "Résultat"
        case .failed: "Test interrompu"
        }
    }

    /// Le débit définitif d'une phase, ou sa valeur en cours de transfert.
    private func reading(final: Double?, live: Double?) -> String {
        Format.rate(final ?? live)
    }

    private var warning: String {
        let host = URL(string: model.speedTestServer)?.host ?? model.speedTestServer
        var text = "Le test transfère des données de test avec \(host) pendant une quinzaine de secondes : jusqu’à 260 Mo sur une connexion rapide."
        if model.path.isExpensive {
            text += " Vous êtes sur un réseau facturé à l’usage : ce volume sera décompté de votre forfait."
        }
        if !model.path.isOnline {
            text += " Aucun réseau pour l’instant."
        }
        return text
    }
}

private struct Reading: View {
    let label: String
    let value: String
    let color: Color
    /// Le résultat suit la taille de texte choisie dans les réglages d'iOS.
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(color)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}

import FluxaCore
import SwiftUI

/// Le test de débit : une mesure à la demande, et la liste des mesures précédentes.
struct SpeedTestView: View {
    @Environment(AppModel.self) private var model

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
                        model.startSpeedTest()
                    } label: {
                        Label("Lancer le test", systemImage: "play.fill")
                    }
                    .disabled(!model.path.isOnline)
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
                }
            }
        }
        .fluxaBackground()
        .navigationTitle("Test de débit")
        .navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(color)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}

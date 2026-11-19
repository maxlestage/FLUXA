import FluxaCore
import SwiftUI

/// Les réglages : la sonde de latence, la conservation, l'effacement des données.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsHistoryErase = false
    @State private var confirmsFullErase = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        PlanView()
                    } label: {
                        LabeledContent {
                            Text(model.plan.map { Format.gigabytes($0.plan.allowanceBytes) } ?? "Non réglé")
                                .font(.body.monospacedDigit())
                        } label: {
                            Label("Forfait mobile", systemImage: "simcard")
                        }
                    }
                    .accessibilityIdentifier("reglage-forfait")
                }

                Section {
                    LabeledContent("Hôte de la sonde") {
                        TextField(AppModel.defaultLatencyHost, text: $model.latencyHost)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                } header: {
                    Text("Latence")
                } footer: {
                    Text("Toutes les cinq secondes, FLUXA ouvre une connexion vers cet hôte et en mesure le délai ; moins souvent en mode économie d’énergie ou données réduites. Avec le test de débit, que vous lancez vous-même, c’est le seul échange réseau de l’app.")
                }

                Section {
                    LabeledContent("Serveur") {
                        TextField(SpeedTestRunner.defaultServer, text: $model.speedTestServer)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                } header: {
                    Text("Test de débit")
                } footer: {
                    Text("Le test ne part que lorsque vous le lancez. Il échange des données de test avec ce serveur, qui voit alors votre adresse IP.")
                }

                Section {
                    ValueRow("Débit", "chaque seconde")
                    ValueRow("Latence et gigue", Self.probeCadence(model.probeInterval))
                    ValueRow("Historique", "chaque minute")
                } header: {
                    Text("Cadences")
                } footer: {
                    Text("Au premier plan. iOS suspend l’app en arrière-plan : la mesure s’arrête et reprend à votre retour.")
                }

                Section {
                    ValueRow("Minutes", "7 jours")
                    ValueRow("Heures", "30 jours")
                    ValueRow("Jours", "12 mois")
                } header: {
                    Text("Conservation")
                } footer: {
                    Text("Les mesures sont enregistrées sur l’iPhone, sans compte et sans serveur.")
                }

                Section("Données") {
                    Button("Effacer l’historique", role: .destructive) {
                        confirmsHistoryErase = true
                    }
                    .confirmationDialog(
                        "Effacer les mesures et le journal des limites ?",
                        isPresented: $confirmsHistoryErase,
                        titleVisibility: .visible
                    ) {
                        Button("Effacer l’historique", role: .destructive) {
                            model.eraseHistory()
                        }
                    } message: {
                        Text("Vos profils et votre forfait sont conservés.")
                    }

                    Button("Tout effacer", role: .destructive) {
                        confirmsFullErase = true
                    }
                    .confirmationDialog(
                        "Effacer toutes les données de FLUXA ?",
                        isPresented: $confirmsFullErase,
                        titleVisibility: .visible
                    ) {
                        Button("Tout effacer", role: .destructive) {
                            model.eraseAll()
                        }
                    } message: {
                        Text("Les mesures, le journal, les profils créés, le forfait et les réglages sont supprimés.")
                    }
                }

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Centre de diagnostic", systemImage: "stethoscope")
                    }
                }

                Section("À propos") {
                    ValueRow("Version", appVersion)
                    ValueRow("Moteur", FluxaEngine.version)
                }
            }
            .fluxaBackground()
            .navigationTitle("Réglages")
        }
    }

    /// « toutes les 5 s », avec le mode du système qui ralentit la sonde.
    static func probeCadence(_ interval: Int) -> String {
        let cadence = "toutes les \(interval) s"
        switch interval {
        case AppModel.probeIntervals.lowData: return cadence + " (données réduites)"
        case AppModel.probeIntervals.lowPower: return cadence + " (économie d’énergie)"
        default: return cadence
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Format.missing
    }
}

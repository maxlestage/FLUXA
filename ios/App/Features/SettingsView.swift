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
                    Text("Toutes les cinq secondes, FLUXA ouvre une connexion vers cet hôte et en mesure le délai. C’est le seul échange réseau que l’app déclenche.")
                }

                Section {
                    ValueRow("Débit", "chaque seconde")
                    ValueRow("Latence et gigue", "toutes les 5 s")
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
                        Text("Vos profils sont conservés.")
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
                        Text("Les mesures, le journal, les profils créés et les réglages sont supprimés.")
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Format.missing
    }
}

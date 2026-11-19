import FluxaCore
import SwiftUI
import UIKit

/// Le partage de connexion : un guide, pas une commande. iOS réserve l'interrupteur à
/// l'utilisateur ; l'app explique le chemin et ouvre Réglages.
struct HotspotGuideView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private let steps = [
        "Ouvrez l’app Réglages.",
        "Touchez « Partage de connexion ».",
        "Activez « Autoriser d’autres utilisateurs ».",
        "Relevez le mot de passe Wi-Fi, ou changez-le.",
        "Revenez dans FLUXA pour suivre le débit de l’iPhone.",
    ]

    private let hotspot: Set<Capability> = [
        .hotspotActivation, .hotspotClientDiscovery, .hotspotLimit, .perDeviceShaping, .clientDisconnect,
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        StatusPill(.guide, "Guide")
                        Text("Le partage de connexion appartient à iOS")
                            .font(.title3.weight(.semibold))
                        Text("Aucune app ne peut l’activer, le couper ou en limiter le débit. FLUXA vous y conduit et mesure la connexion de l’iPhone pendant que vous partagez.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Activer le partage") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.callout.monospaced().weight(.semibold))
                                .foregroundStyle(Theme.tertiary)
                                .frame(width: 20, alignment: .leading)
                            Text(step)
                        }
                    }
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("Ouvrir l’app Réglages", systemImage: "gear")
                    }
                }

                Section {
                    ForEach(model.capabilities.filter { hotspot.contains($0.capability) }) { status in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(status.capability.title)
                                Spacer(minLength: 12)
                                StatusPill(status.support.pill, status.support.title)
                            }
                            Text(status.note)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Ce qu’iOS garde pour lui")
                } footer: {
                    Text("iOS laisse une app ouvrir sa propre page dans Réglages. De là, revenez à la liste principale pour trouver « Partage de connexion ».")
                }

                Section {
                    if let guide = URL(string: "https://support.apple.com/fr-fr/111785") {
                        Link(destination: guide) {
                            Label("Guide Apple du partage de connexion", systemImage: "arrow.up.right.square")
                        }
                    }
                }
            }
            .fluxaBackground()
            .navigationTitle("Partage")
        }
    }
}

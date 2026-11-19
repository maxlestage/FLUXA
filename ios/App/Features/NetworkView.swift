import FluxaCore
import SwiftUI

/// Mon réseau : ce que le système dit du chemin courant, et les compteurs des interfaces.
struct NetworkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Connexion") {
                ValueRow("Réseau", model.path.kind.title)
                if model.path.kind == .cellular {
                    ValueRow("Génération", model.path.radio ?? "Inconnue")
                }
                ValueRow("Internet", model.path.isOnline ? "Joignable" : "Injoignable")
                ValueRow("Facturé à l’usage", yesNo(model.path.isExpensive))
                ValueRow("Données réduites", yesNo(model.path.isConstrained))
                ValueRow("IPv4", yesNo(model.path.supportsIPv4))
                ValueRow("IPv6", yesNo(model.path.supportsIPv6))
                ValueRow("Résolution de noms", yesNo(model.path.supportsDNS))
            }

            Section {
                if model.interfaces.isEmpty {
                    Text("Aucune interface active.")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(model.interfaces, id: \.name) { interface in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(interface.kind.title)
                            Spacer()
                            Text(interface.name)
                                .font(.callout.monospaced())
                                .foregroundStyle(Theme.tertiary)
                        }
                        Text("↓ \(Format.bytes(interface.receivedBytes)) · ↑ \(Format.bytes(interface.sentBytes))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                }
            } header: {
                Text("Interfaces")
            } footer: {
                Text("Compteurs du système, sur 32 bits : ils repartent de zéro tous les 4 Go et au redémarrage de l’iPhone. Ils comptent tout le trafic de l’interface, toutes apps confondues.")
            }

            Section {
                Text("iOS ne dit pas à une app quels appareils sont reliés au partage de connexion, ni ce que chacun consomme. FLUXA n’affiche que ce que le système lui donne.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .fluxaBackground()
        .navigationTitle("Mon réseau")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Oui" : "Non"
    }
}

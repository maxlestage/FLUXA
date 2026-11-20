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

                Section {
                    NavigationLink {
                        RelayView()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("Relais de partage", systemImage: "arrow.left.arrow.right.circle")
                                Spacer()
                                if model.relayIsRunning {
                                    StatusPill(.supported, "En service")
                                }
                            }
                            Text("Plafonnez et suivez, appareil par appareil, le trafic des appareils reliés qui passent par FLUXA.")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .accessibilityIdentifier("lien-relais")
                }

                Section {
                    LabeledContent("État") {
                        if model.sharingDetected {
                            StatusPill(.supported, "Détecté")
                        } else {
                            StatusPill(.guide, "Non détecté")
                        }
                    }
                    if let sharing = model.sharing {
                        ValueRow("Durée", Format.span(sharing.session.duration))
                        ValueRow("Vers les appareils", Format.rate(sharing.toDevicesBps))
                        ValueRow("Depuis les appareils", Format.rate(sharing.fromDevicesBps))
                        ValueRow("Envoyé aux appareils", Format.bytes(sharing.session.toDevicesBytes))
                        ValueRow("Reçu des appareils", Format.bytes(sharing.session.fromDevicesBytes))
                    }
                } footer: {
                    Text("iOS ne dit pas à une app si le partage est actif. FLUXA le déduit de l’interface réseau que le système crée pour les appareils reliés, et y lit le trafic de tous les appareils ensemble. Ce signe peut manquer, par exemple tant qu’aucun appareil n’est connecté.")
                }

                if !model.sharingSessions.isEmpty {
                    Section {
                        ForEach(model.sharingSessions) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(Format.dateTime(session.start))
                                    Spacer()
                                    Text(Format.span(session.duration))
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(Theme.tertiary)
                                }
                                Text("\(SharingText.volume(session)) · ↓ \(Format.bytes(session.toDevicesBytes)) · ↑ \(Format.bytes(session.fromDevicesBytes))")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(Theme.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Sessions de partage")
                    } footer: {
                        Text("Mesurées quand FLUXA est ouvert, puis complétées à votre retour d’après les compteurs du système : « au moins » signale un volume rattrapé.")
                    }
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
                                .fixedSize(horizontal: false, vertical: true)
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
                    NavigationLink {
                        DevicesView()
                    } label: {
                        Label("Mes appareils", systemImage: "laptopcomputer.and.iphone")
                    }
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

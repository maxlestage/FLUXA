import FluxaCore
import SwiftUI
import UIKit

/// Le relais de partage : FLUXA relaie le trafic des appareils du partage de connexion
/// réglés sur lui, le plafonne et le compte par appareil.
///
/// iOS ne laisse aucune app brider le partage lui-même. Le relais est un mandataire : il
/// limite pour de vrai ce qui passe par lui, et seulement cela.
struct RelayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let status = model.relayStatus

        List {
            Section {
                Toggle(
                    "Relais de partage",
                    isOn: Binding(get: { model.relayEnabled }, set: { model.setRelay($0) })
                )
                .accessibilityIdentifier("interrupteur-relais")
                LabeledContent("État") {
                    if model.relayIsRunning {
                        StatusPill(.supported, "En service")
                    } else if model.relayError != nil {
                        StatusPill(.reserved, "Fermé")
                    } else {
                        StatusPill(.guide, "Arrêté")
                    }
                }
                .accessibilityIdentifier("etat-relais")
                if let status, status.running, let active = status.activeConnections, let maximum = status.maxConnections {
                    LabeledContent("Connexions") {
                        Text(RelayText.load(active: active, maximum: maximum))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(active >= maximum ? Theme.reserved : Theme.text)
                    }
                }
                if let error = model.relayError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.reserved)
                }
                if let notice = model.relayNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(Theme.up)
                }
                if model.relayIsRunning, !model.relayRunsInBackground {
                    Toggle("Garder l’écran allumé", isOn: $model.keepsScreenOnForRelay)
                }
            } footer: {
                Text(RelayText.runningNote(inBackground: model.relayRunsInBackground, running: model.relayIsRunning))
            }

            Section {
                CopyRow(label: "Mandataire", value: "\(status?.address ?? RelayBridge.defaultAddress):\(RelayBridge.port)")
                CopyRow(label: "Configuration automatique", value: RelayText.pacURL(address: status?.address))
                DisclosureGroup("Régler un appareil") {
                    ForEach(RelayText.instructions, id: \.platform) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.platform)
                                .font(.subheadline.weight(.semibold))
                            Text(item.steps)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Sur chaque appareil relié")
            } footer: {
                Text("Réglez une fois le mandataire de l’appareil sur la configuration automatique ci-dessus. Si FLUXA est fermé, l’appareil repasse en direct : il n’est jamais privé de connexion, mais il n’est plus plafonné.")
            }

            Section {
                LabeledContent("Plafond") {
                    Text(RelayText.cap(model.lastApply?.requested ?? model.activeProfile?.policy))
                        .font(.body.monospacedDigit())
                }
                if let result = model.lastApply {
                    LabeledContent("Statut") {
                        StatusPill(result.status.pill, result.status.title)
                    }
                    .accessibilityIdentifier("statut-limite-relais")
                    if let reason = result.reason {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                NavigationLink("Régler le plafond") {
                    LimiterView()
                }
            } header: {
                Text("Plafond de tout le trafic relayé")
            } footer: {
                Text("Le profil choisi ou le limiteur fixe ce plafond. « Partiel » : appliqué par FLUXA au trafic relayé, pas au partage tout entier.")
            }

            Section {
                let clients = status?.clients ?? []
                if clients.isEmpty {
                    Text(model.relayIsRunning
                        ? "Aucun appareil ne passe encore par le relais."
                        : "Ouvrez le relais pour voir les appareils qui l’utilisent.")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(clients) { client in
                    RelayClientRow(
                        client: client,
                        name: model.relayDeviceNames[client.address],
                        rate: model.relayRates[client.address],
                        profileID: model.relayDeviceProfiles[client.address],
                        profiles: model.profiles,
                        choose: { profileID in model.setRelayProfile(profileID, for: client.address) },
                        rename: { name in model.setRelayName(name, for: client.address) }
                    )
                }
            } header: {
                Text("Appareils relayés")
            } footer: {
                Text("Chaque appareil est reconnu par son adresse sur le partage, que l’iPhone peut lui changer d’une connexion à l’autre : son nom et son plafond suivent l’adresse. Un plafond propre à l’appareil s’ajoute au plafond de tout le trafic.")
            }
        }
        .fluxaBackground()
        .navigationTitle("Relais de partage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RelayClientRow: View {
    let client: RelayStatus.Client
    let name: String?
    let rate: RelayRate?
    let profileID: String?
    let profiles: [Profile]
    let choose: (String?) -> Void
    let rename: (String) -> Void
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RelayText.displayName(name, address: client.address))
                        .font(name == nil ? .body.monospaced() : .body.weight(.medium))
                    if name != nil {
                        Text(client.address)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                Spacer()
                Text(RelayText.connections(client.connections))
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                Button {
                    draft = name ?? ""
                    renaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Nommer \(RelayText.displayName(name, address: client.address))")
            }
            Text("↓ \(Format.rate(rate?.toDeviceBps)) · ↑ \(Format.rate(rate?.fromDeviceBps))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.text)
            Text("Relayé : ↓ \(Format.bytes(client.toDeviceBytes)) · ↑ \(Format.bytes(client.fromDeviceBytes))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondary)
            Picker("Plafond de l’appareil", selection: Binding(get: { profileID }, set: choose)) {
                Text("Aucun").tag(String?.none)
                ForEach(profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("appareil-relaye")
        .alert("Nom de l’appareil", isPresented: $renaming) {
            TextField(client.address, text: $draft)
            Button("Enregistrer") { rename(draft) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Un nom pour \(client.address), gardé sur cet iPhone. Laissez vide pour revenir à l’adresse.")
        }
    }
}

private struct CopyRow: View {
    let label: String
    let value: String

    var body: some View {
        Button {
            UIPasteboard.general.string = value
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                HStack {
                    Text(value)
                        .font(.callout.monospaced())
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                    Spacer()
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(Theme.down)
                }
            }
        }
        .accessibilityLabel("\(label) : \(value). Toucher pour copier.")
    }
}

/// Les phrases du relais, séparées de l'écran pour être testées.
enum RelayText {
    static func pacURL(address: String?) -> String {
        "http://\(address ?? RelayBridge.defaultAddress):\(RelayBridge.port)/proxy.pac"
    }

    static func cap(_ policy: BandwidthPolicy?) -> String {
        guard let policy, policy.downloadBps != nil || policy.uploadBps != nil else {
            return "Sans plafond"
        }
        return "↓ \(Format.cap(policy.downloadBps)) · ↑ \(Format.cap(policy.uploadBps))"
    }

    /// Où tourne le relais, et ce que cela change.
    static func runningNote(inBackground: Bool, running: Bool) -> String {
        if inBackground {
            return "Le relais tourne en arrière-plan dans une extension réseau, signalée par l’icône VPN. Ce « VPN » ne transporte aucun trafic de l’iPhone : il garde seulement le relais en service."
        }
        if running {
            return "Le relais tourne dans l’app : il s’arrête quand FLUXA passe en arrière-plan et se rouvre à votre retour."
        }
        return "À la première ouverture, iOS demande d’autoriser la configuration du relais : elle le garde en service quand FLUXA est en arrière-plan."
    }

    /// Le nom d'un appareil relayé, ou son adresse s'il n'en a pas.
    static func displayName(_ name: String?, address: String) -> String {
        cleanName(name ?? "") ?? address
    }

    /// Un nom saisi, sans espaces superflus et limité à 40 caractères. `nil` s'il est vide.
    static func cleanName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(40))
    }

    /// « 12 sur 192 », et la saturation quand le maximum est atteint.
    static func load(active: Int, maximum: Int) -> String {
        active >= maximum ? "\(active) sur \(maximum), nouvelles refusées" : "\(active) sur \(maximum)"
    }

    static func connections(_ count: Int) -> String {
        count == 0 ? "inactif" : "\(count) connexion\(count > 1 ? "s" : "")"
    }

    static let instructions: [(platform: String, steps: String)] = [
        ("iPhone, iPad", "Réglages → Wi-Fi → (i) à côté du partage → Configurer le proxy → Automatique → collez l’adresse de configuration automatique."),
        ("Mac", "Réglages Système → Wi-Fi → Détails du réseau du partage → Proxys → Configuration automatique du proxy → collez l’adresse."),
        ("Windows", "Paramètres → Réseau et Internet → Proxy → Utiliser un script d’installation → collez l’adresse → Enregistrer."),
        ("Android", "Wi-Fi → réseau du partage → Modifier → Options avancées → Proxy : configuration automatique → collez l’adresse."),
    ]
}

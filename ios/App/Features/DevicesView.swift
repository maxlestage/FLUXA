import FluxaCore
import SwiftUI

/// Mes appareils : un carnet des appareils reliés au partage de connexion, tenu à la
/// main. iOS n'en donne pas la liste : l'app ne montre que ce que l'utilisateur a noté.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: DeviceDraft?

    var body: some View {
        List {
            Section {
                if model.devices.isEmpty {
                    Text("Aucun appareil noté. Ajoutez-en un avec le bouton +.")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(model.devices) { device in
                    Button {
                        draft = DeviceDraft(device)
                    } label: {
                        DeviceRow(device: device, profile: model.profile(id: device.profileID), status: model.limitStatus(for: device))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.deleteDevice(device)
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Appareils notés")
            } footer: {
                Text("iOS ne dit pas à une app quels appareils sont reliés au partage, ni leur adresse, ni ce qu’ils consomment. Ce carnet garde le nom et le profil que vous prévoyez pour chacun ; ce profil n’est pas appliqué à l’appareil.")
            }

            Section("Ce qu’iOS ne fournit pas") {
                ValueRow("Adresse IP", "Inconnue")
                ValueRow("Adresse MAC", "Inconnue")
                ValueRow("Dernière activité", "Inconnue")
                ValueRow("Volume par appareil", "Inconnu")
            }

            // Ce qu'iOS ne fournit pas, le relais le voit pour les appareils réglés sur lui.
            Section {
                NavigationLink {
                    RelayView()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Relais de partage", systemImage: "arrow.left.arrow.right.circle")
                        Text(
                            model.relayIsRunning
                                ? RelayText.dashboardSummary(clients: model.relayStatus?.clients ?? [], rates: model.relayRates)
                                : "Relais arrêté"
                        )
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                    }
                }
                .accessibilityIdentifier("appareils-relais")
            } footer: {
                Text(RelayText.devicesNote)
            }
        }
        .fluxaBackground()
        .navigationTitle("Mes appareils")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    draft = DeviceDraft()
                } label: {
                    Label("Nouvel appareil", systemImage: "plus")
                }
            }
        }
        .sheet(item: $draft) { draft in
            DeviceEditor(draft: draft)
        }
    }
}

private struct DeviceRow: View {
    let device: Device
    let profile: Profile?
    let status: ApplyResult?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.kind.symbol)
                .font(.title3)
                .foregroundStyle(Theme.down)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            if let status {
                StatusPill(status.status.pill, status.status.title)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var detail: String {
        if let profile {
            return "\(device.kind.title) · profil \(profile.name), noté"
        }
        return "\(device.kind.title) · aucun profil"
    }
}

/// Un appareil en cours de saisie.
struct DeviceDraft: Identifiable {
    let id = UUID()
    var device: Device

    init() {
        device = Device(name: "")
    }

    init(_ device: Device) {
        self.device = device
    }
}

private struct DeviceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: DeviceDraft
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Appareil") {
                    TextField("Nom de l’appareil", text: $draft.device.name)
                    Picker("Type", selection: $draft.device.kind) {
                        ForEach(DeviceKind.allCases, id: \.self) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                }

                Section {
                    Picker("Profil prévu", selection: $draft.device.profileID) {
                        Text("Aucun").tag(String?.none)
                        ForEach(model.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                } footer: {
                    Text("Le profil est noté pour mémoire. iOS ne permet pas à une app de limiter un appareil relié au partage.")
                }

                Section("Note") {
                    TextField("Note", text: $draft.device.note, axis: .vertical)
                        .lineLimit(1...4)
                }

                if let problem {
                    Section {
                        Text(problem)
                            .foregroundStyle(Theme.reserved)
                            .accessibilityIdentifier("erreur-appareil")
                    }
                }
            }
            .fluxaBackground()
            .navigationTitle(draft.device.id.isEmpty ? "Nouvel appareil" : "Modifier l’appareil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        problem = model.saveDevice(draft.device)
                        if problem == nil { dismiss() }
                    }
                }
            }
        }
    }
}

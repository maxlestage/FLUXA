import FluxaCore
import SwiftUI

/// Les profils de débit : en choisir un, le modifier, en créer.
struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: ProfileDraft?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    verdict
                }

                Section {
                    ForEach(model.profiles) { profile in
                        Button {
                            model.activate(profile)
                        } label: {
                            ProfileRow(profile: profile, isActive: profile.id == model.activeProfileID)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            if !profile.isBuiltin {
                                Button(role: .destructive) {
                                    model.delete(profile)
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                            Button {
                                draft = ProfileDraft(profile)
                            } label: {
                                Label("Modifier", systemImage: "pencil")
                            }
                            .tint(Theme.raised)
                        }
                    }
                } header: {
                    Text("Profils")
                } footer: {
                    Text("Touchez un profil pour le choisir, balayez-le vers la gauche pour le modifier. Les valeurs sont des points de départ, pas des débits garantis.")
                }

                Section {
                    NavigationLink {
                        LimiterView()
                    } label: {
                        Label("Limiteur de débit", systemImage: "gauge.with.dots.needle.33percent")
                    }
                }
            }
            .fluxaBackground()
            .navigationTitle("Profils")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        draft = ProfileDraft()
                    } label: {
                        Label("Nouveau profil", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $draft) { draft in
                ProfileEditor(draft: draft)
            }
        }
    }

    /// Ce qui est enregistré, et ce que le système en fait.
    @ViewBuilder
    private var verdict: some View {
        if let result = model.lastApply {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.activeProfile?.name ?? "Limite personnalisée")
                        .font(.headline)
                    Spacer()
                    StatusPill(result.status.pill, result.status.title)
                }
                Text("↓ \(Format.cap(result.requested.downloadBps)) · ↑ \(Format.cap(result.requested.uploadBps))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                if let reason = result.reason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Configuré ne veut pas dire appliqué")
                    .font(.headline)
                Text("Choisissez un profil : FLUXA enregistre le plafond, vérifie ce que l’iPhone autorise, puis affiche le statut exact.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Theme.down : Theme.tertiary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .foregroundStyle(Theme.text)
                Text("↓ \(Format.cap(profile.downloadBps)) · ↑ \(Format.cap(profile.uploadBps))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

/// Un profil en cours de saisie.
struct ProfileDraft: Identifiable {
    let id = UUID()
    var profileID: String?
    var name = ""
    var limitsDownload = true
    var downloadMbps = 10.0
    var limitsUpload = true
    var uploadMbps = 5.0

    init() {}

    init(_ profile: Profile) {
        profileID = profile.id
        name = profile.name
        limitsDownload = profile.downloadBps != nil
        downloadMbps = profile.downloadBps.map(Limits.mbps(fromBps:)) ?? 10
        limitsUpload = profile.uploadBps != nil
        uploadMbps = profile.uploadBps.map(Limits.mbps(fromBps:)) ?? 5
    }
}

private struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: ProfileDraft

    var body: some View {
        NavigationStack {
            Form {
                Section("Nom") {
                    TextField("Nom du profil", text: $draft.name)
                }
                Section {
                    Toggle("Plafond descendant", isOn: $draft.limitsDownload)
                    if draft.limitsDownload {
                        RateField(label: "Descendant", value: $draft.downloadMbps)
                    }
                    Toggle("Plafond montant", isOn: $draft.limitsUpload)
                    if draft.limitsUpload {
                        RateField(label: "Montant", value: $draft.uploadMbps)
                    }
                } header: {
                    Text("Plafonds")
                } footer: {
                    Text("De 0,1 à 1 000 Mb/s. Sans plafond, le sens reste libre.")
                }
            }
            .fluxaBackground()
            .navigationTitle(draft.profileID == nil ? "Nouveau profil" : "Modifier le profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        let saved = model.saveProfile(
                            id: draft.profileID,
                            name: draft.name,
                            downloadMbps: draft.limitsDownload ? draft.downloadMbps : nil,
                            uploadMbps: draft.limitsUpload ? draft.uploadMbps : nil
                        )
                        if saved { dismiss() }
                    }
                }
            }
        }
    }
}

/// Un champ de débit, en Mb/s.
private struct RateField: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("Mb/s", value: $value, format: .number.locale(Format.locale))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: 110)
                Text("Mb/s")
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}

import SwiftUI
import UIKit

/// Les autorisations d'iOS dont FLUXA se sert : leur état, pourquoi, et comment les
/// accorder. Celles qu'iOS laisse demander se demandent ici ; les autres se changent
/// dans Réglages.
struct PermissionsView: View {
    @State private var permissions = PermissionCenter()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                Button {
                    Task { await permissions.askAll() }
                } label: {
                    HStack {
                        Label(
                            permissions.allGranted ? "Tout est accordé" : "Tout autoriser",
                            systemImage: permissions.allGranted ? "checkmark.seal.fill" : "hand.raised.fill"
                        )
                        Spacer()
                        if permissions.isAsking {
                            ProgressView()
                        }
                    }
                }
                .disabled(permissions.isAsking || permissions.allGranted)
                .accessibilityIdentifier("tout-autoriser")
            } footer: {
                Text("iOS pose ses questions l’une après l’autre. Ce qu’il ne laisse pas demander à une app se change dans Réglages : le bouton de chaque ligne y mène.")
            }

            Section {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(
                        kind: kind,
                        state: permissions.state(of: kind),
                        ask: { Task { await permissions.ask(kind) } },
                        openSettings: openSettings
                    )
                }
            } header: {
                Text("Ce que FLUXA utilise")
            } footer: {
                Text("FLUXA ne demande ni la localisation, ni les contacts, ni les photos, ni le micro : elle n’en a pas besoin, et Apple refuse les apps qui demandent ce dont elles ne se servent pas.")
            }
        }
        .fluxaBackground()
        .navigationTitle("Autorisations")
        .navigationBarTitleDisplayMode(.inline)
        .task { await permissions.refresh() }
        // Au retour de Réglages, les états sont relus.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await permissions.refresh() }
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let state: PermissionState
    let ask: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(kind.title, systemImage: kind.symbol)
                Spacer(minLength: 12)
                StatusPill(state.pill, state.title)
            }
            Text(kind.reason)
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
            switch PermissionText.action(for: kind, state: state) {
            case .ask:
                Button("Autoriser", action: ask)
                    .buttonStyle(.bordered)
            case .settings:
                Button("Ouvrir Réglages", action: openSettings)
                    .buttonStyle(.bordered)
            case .none:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("autorisation-\(kind.rawValue)")
    }
}

/// Ce qu'une ligne propose, séparé de la vue pour être testé.
enum PermissionText {
    enum Action: Equatable {
        case ask, settings, none
    }

    static func action(for kind: PermissionKind, state: PermissionState) -> Action {
        switch state {
        case .granted, .unavailable, .pending:
            return .none
        case .denied:
            // Une autorisation refusée ne se redemande pas : iOS ne repose pas la question.
            return .settings
        case .notAsked:
            return kind.canAsk ? .ask : .settings
        }
    }
}

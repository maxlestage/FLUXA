import SwiftUI

/// Les widgets et l'activité en direct : à quoi ils ressemblent, comment les ajouter, et
/// ce qu'ils peuvent ou non afficher.
struct WidgetsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let snapshot = model.widgetSnapshot()
        let relayState = model.relayActivityState(now: Date())

        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        WidgetFrame(width: 158, height: 158, title: "Petit") {
                            FluxaWidgetView(snapshot: snapshot, layout: .small)
                        }
                        WidgetFrame(width: 338, height: 158, title: "Moyen") {
                            FluxaWidgetView(snapshot: snapshot, layout: .medium)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("apercu-widgets")
                HStack(spacing: 14) {
                    AccessoryFrame(width: 72, height: 72, title: "Rond") {
                        FluxaWidgetView(snapshot: snapshot, layout: .circular)
                    }
                    AccessoryFrame(width: 170, height: 72, title: "Rectangle") {
                        FluxaWidgetView(snapshot: snapshot, layout: .rectangular)
                    }
                }
            } header: {
                Text("Écran d’accueil et écran verrouillé")
            } footer: {
                Text("Touchez longuement l’écran d’accueil ou l’écran verrouillé, puis « Modifier » et « Ajouter des widgets », et choisissez FLUXA. Un widget ne mesure rien lui-même : il affiche le dernier relevé de l’app et son heure.")
            }

            Section {
                RelayActivityBanner(startedAt: Date().addingTimeInterval(-754), state: relayState)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .accessibilityIdentifier("apercu-activite")
                IslandPreview(state: relayState)
                    .frame(maxWidth: .infinity)
                Toggle("Montrer le relais dans la Dynamic Island", isOn: $model.showsRelayActivity)
            } header: {
                Text("Activité en direct du relais")
            } footer: {
                Text("Quand le relais de partage est ouvert, il apparaît sur l’écran verrouillé et dans la Dynamic Island, avec le temps écoulé depuis son ouverture. En arrière-plan, FLUXA ne peut la mettre à jour que lorsqu’iOS le réveille, au mieux tous les quarts d’heure et sans garantie : le nombre d’appareils et le débit sont ceux du dernier relevé, et l’activité indique leur ancienneté.")
            }
        }
        .fluxaBackground()
        .navigationTitle("Widgets et Dynamic Island")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WidgetFrame<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 6) {
            content
                .padding(14)
                .frame(width: width, height: height)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line))
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

private struct AccessoryFrame<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 6) {
            content
                .foregroundStyle(.white)
                .padding(8)
                .frame(width: width, height: height)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// La Dynamic Island, réduite puis déployée, telle que l'extension la dessine.
private struct IslandPreview: View {
    let state: RelayActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                RelayIsland.CompactLeading()
                Spacer()
                RelayIsland.CompactTrailing(state: state)
            }
            .padding(.horizontal, 14)
            .frame(width: 230, height: 36)
            .background(.black, in: Capsule())
            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    RelayIsland.ExpandedLeading(state: state)
                    Spacer()
                    RelayIsland.ExpandedTrailing(startedAt: Date().addingTimeInterval(-754), state: state)
                }
                RelayIsland.ExpandedBottom(state: state)
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(width: 340)
            .background(.black, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("apercu-ile")
    }
}

import SwiftUI

/// L'accueil du premier lancement : ce que l'app mesure, ce qu'iOS garde pour lui, et où
/// vont les données. Trois faits, avant le premier écran.
struct WelcomeView: View {
    let onDone: () -> Void

    private let points: [(symbol: String, color: Color, title: String, text: String)] = [
        (
            "waveform.path.ecg", Theme.down,
            "Votre connexion, à la seconde",
            "Débit, latence et volume consommé par l’iPhone, tant que l’app est ouverte."
        ),
        (
            "lock.shield", Theme.simulated,
            "Ce qu’iOS garde pour lui",
            "Aucune app ne peut activer le partage de connexion ni en limiter le débit. Un plafond réglé ici est enregistré et simulé, jamais annoncé comme appliqué."
        ),
        (
            "iphone", Theme.ok,
            "Vos mesures restent sur l’iPhone",
            "Pas de compte, pas de serveur. Les seuls échanges sont la sonde de latence et le test de débit que vous lancez."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Bienvenue")
                    Text("FLUXA mesure, et dit ce qui est réellement appliqué.")
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(points, id: \.title) { point in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: point.symbol)
                            .font(.title2)
                            .foregroundStyle(point.color)
                            .frame(width: 36)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(point.title)
                                .font(.headline)
                            Text(point.text)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(24)
            .padding(.top, 24)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onDone) {
                Text("Commencer")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(24)
            .background(Theme.background)
        }
        .background(Theme.background)
        .interactiveDismissDisabled()
    }
}

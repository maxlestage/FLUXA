import FluxaCore
import SwiftUI

@main
struct FluxaApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.down)
                // `start` ne fait rien si la mesure tourne déjà.
                .task { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.start()
            case .background:
                // iOS suspend l'app en arrière-plan : la mesure s'arrête, l'état est enregistré.
                model.stop()
            default:
                break
            }
        }
    }
}

/// Les cinq onglets de l'app.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Launch.tab

    var body: some View {
        @Bindable var model = model
        content
            .alert(
                "Action impossible",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch Launch.screen {
        case "reseau":
            NavigationStack { NetworkView() }
        case "limiteur":
            NavigationStack { LimiterView() }
        case "diagnostic":
            NavigationStack { DiagnosticsView() }
        default:
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            DashboardView()
                .tabItem { Label("Réseau", systemImage: "waveform.path.ecg") }
                .tag(AppTab.dashboard)
            HotspotGuideView()
                .tabItem { Label("Partage", systemImage: "personalhotspot") }
                .tag(AppTab.hotspot)
            ProfilesView()
                .tabItem { Label("Profils", systemImage: "slider.horizontal.3") }
                .tag(AppTab.profiles)
            HistoryView()
                .tabItem { Label("Historique", systemImage: "chart.bar.xaxis") }
                .tag(AppTab.history)
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}

enum AppTab: String {
    case dashboard = "reseau"
    case hotspot = "partage"
    case profiles = "profils"
    case history = "historique"
    case settings = "reglages"
}

/// Les arguments de lancement, pour ouvrir l'app sur un écran précis :
/// `-fluxaTab profils`, ou `-fluxaScreen limiteur` pour un écran intérieur.
/// Le workflow s'en sert pour ses captures d'écran.
enum Launch {
    static var tab: AppTab {
        UserDefaults.standard.string(forKey: "fluxaTab").flatMap(AppTab.init(rawValue:)) ?? .dashboard
    }

    static var screen: String? {
        UserDefaults.standard.string(forKey: "fluxaScreen")
    }
}

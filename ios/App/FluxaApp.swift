import BackgroundTasks
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
                .environment(\.locale, Format.locale)
                .tint(Theme.down)
                // `start` ne fait rien si la mesure tourne déjà.
                .task { model.start() }
        }
        // Quand iOS réveille l'app en arrière-plan : l'activité du relais est mise à jour.
        .backgroundTask(.appRefresh(AppModel.relayRefreshIdentifier)) {
            await model.refreshRelayInBackground()
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
    /// Le relais ouvert par Siri ou un raccourci.
    @State private var showsRelay = false
    private let intents = IntentRouter.shared
    @State private var tab = Launch.tab
    /// L'accueil ne s'affiche qu'au premier lancement.
    @State private var showsWelcome = !UserDefaults.standard.bool(forKey: Launch.welcomeKey)

    var body: some View {
        @Bindable var model = model
        content
            .sheet(isPresented: $showsRelay) {
                NavigationStack {
                    RelayView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("OK") { showsRelay = false }
                            }
                        }
                }
            }
            // Une demande de Siri ou d'un raccourci : ouvrir le relais et l'écran du relais.
            .onChange(of: intents.pending, initial: true) { _, request in
                guard request != nil, intents.take() == .openRelay else { return }
                if !model.relayEnabled {
                    model.setRelay(true)
                }
                showsRelay = true
            }
            .fullScreenCover(isPresented: $showsWelcome) {
                WelcomeView {
                    UserDefaults.standard.set(true, forKey: Launch.welcomeKey)
                    showsWelcome = false
                }
            }
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
        case "test":
            NavigationStack { SpeedTestView() }
        case "automatisations":
            NavigationStack { AutomationsView() }
        case "appareils":
            NavigationStack { DevicesView() }
        case "forfait":
            NavigationStack { PlanView() }
        case "relais":
            NavigationStack { RelayView() }
        case "widgets":
            NavigationStack { WidgetsView() }
        case "autorisations":
            NavigationStack { PermissionsView() }
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
/// `-fluxaTab profils`, ou `-fluxaScreen limiteur` pour un écran intérieur
/// (`reseau`, `limiteur`, `diagnostic`, `test`, `automatisations`, `appareils`, `forfait`,
/// `relais`, `widgets`, `autorisations`).
/// Le workflow s'en sert pour ses captures d'écran.
enum Launch {
    static var tab: AppTab {
        UserDefaults.standard.string(forKey: "fluxaTab").flatMap(AppTab.init(rawValue:)) ?? .dashboard
    }

    /// Vrai une fois l'accueil du premier lancement passé (`-hasSeenWelcome YES` le saute).
    static let welcomeKey = "hasSeenWelcome"

    static var screen: String? {
        UserDefaults.standard.string(forKey: "fluxaScreen")
    }

    /// La durée à partir de laquelle une absence est signalée au retour dans l'app, en
    /// secondes : une minute, ou la valeur de `-fluxaAbsenceMinimum` pour les tests.
    static let absenceMinimum: TimeInterval = {
        let custom = UserDefaults.standard.double(forKey: "fluxaAbsenceMinimum")
        return custom > 0 ? custom : 60
    }()
}

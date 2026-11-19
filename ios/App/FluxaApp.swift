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

    var body: some View {
        @Bindable var model = model
        TabView {
            DashboardView()
                .tabItem { Label("Réseau", systemImage: "waveform.path.ecg") }
            HotspotGuideView()
                .tabItem { Label("Partage", systemImage: "personalhotspot") }
            ProfilesView()
                .tabItem { Label("Profils", systemImage: "slider.horizontal.3") }
            HistoryView()
                .tabItem { Label("Historique", systemImage: "chart.bar.xaxis") }
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
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
}

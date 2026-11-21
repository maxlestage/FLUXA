import AppIntents
import Foundation

// Siri et l'app Raccourcis. Les réponses viennent du dernier relevé de l'app (le même que
// celui des widgets), avec son heure : une intention ne mesure rien elle-même.

/// Le volume du jour, au dernier relevé.
struct TodayUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Volume du jour"
    static let description = IntentDescription("Le volume reçu et envoyé aujourd’hui par l’iPhone, au dernier relevé de FLUXA.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = IntentText.today(WidgetSnapshot.load())
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Ce qu'il reste du forfait mobile, au dernier relevé.
struct PlanRemainingIntent: AppIntent {
    static let title: LocalizedStringResource = "Forfait restant"
    static let description = IntentDescription("Ce qu’il reste du forfait mobile, au dernier relevé de FLUXA.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = IntentText.plan(WidgetSnapshot.load())
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Ouvre FLUXA sur le relais de partage, et l'ouvre.
struct OpenRelayIntent: AppIntent {
    static let title: LocalizedStringResource = "Ouvrir le relais de partage"
    static let description = IntentDescription("Ouvre FLUXA et son relais de partage, pour plafonner les appareils reliés.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.request(.openRelay)
        return .result()
    }
}

/// Les phrases que Siri reconnaît, en français.
struct FluxaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TodayUsageIntent(),
            phrases: [
                "Volume du jour dans \(.applicationName)",
                "Combien j’ai consommé avec \(.applicationName)",
            ],
            shortTitle: "Volume du jour",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: PlanRemainingIntent(),
            phrases: [
                "Forfait restant dans \(.applicationName)",
                "Combien il me reste de forfait avec \(.applicationName)",
            ],
            shortTitle: "Forfait restant",
            systemImageName: "simcard"
        )
        AppShortcut(
            intent: OpenRelayIntent(),
            phrases: [
                "Ouvre le relais \(.applicationName)",
                "Partage avec \(.applicationName)",
            ],
            shortTitle: "Relais de partage",
            systemImageName: "arrow.left.arrow.right.circle"
        )
    }
}

/// Ce que demande une intention à l'app ouverte.
@MainActor
@Observable
final class IntentRouter {
    enum Request: Equatable {
        case openRelay
    }

    static let shared = IntentRouter()
    private(set) var pending: Request?

    func request(_ request: Request) {
        pending = request
    }

    /// Prend la demande en cours, une seule fois.
    func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}

/// Les réponses des intentions, séparées pour être testées.
enum IntentText {
    static func today(_ snapshot: WidgetSnapshot?, now: Date = Date()) -> String {
        guard let snapshot else { return "Ouvrez FLUXA une fois pour qu’il fasse un premier relevé." }
        let day = WidgetText.day(of: snapshot.updatedAt, now: now)
        return "\(day) : \(Format.bytes(snapshot.todayBytes)) reçus et envoyés. \(WidgetText.updated(snapshot.updatedAt, now: now))."
    }

    static func plan(_ snapshot: WidgetSnapshot?, now: Date = Date()) -> String {
        guard let snapshot else { return "Ouvrez FLUXA une fois pour qu’il fasse un premier relevé." }
        guard let plan = snapshot.plan else { return "Aucun forfait n’est réglé dans FLUXA." }
        if plan.usedBytes >= plan.allowanceBytes {
            return "Forfait dépassé : \(Format.bytes(plan.usedBytes)) utilisés. \(WidgetText.updated(snapshot.updatedAt, now: now))."
        }
        return "Il reste \(Format.bytes(plan.remainingBytes)) sur \(Format.gigabytes(plan.allowanceBytes)). \(WidgetText.updated(snapshot.updatedAt, now: now))."
    }
}

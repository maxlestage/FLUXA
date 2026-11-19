import FluxaCore
import Foundation
import UserNotifications

/// Les notifications des automatisations. L'autorisation n'est demandée que lorsque
/// l'utilisateur active l'option, jamais au premier lancement.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Access: Equatable {
        case unknown, allowed, denied
    }

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func access() async -> Access {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .allowed
        case .denied:
            return .denied
        default:
            return .unknown
        }
    }

    /// Demande l'autorisation. Renvoie `true` si elle est accordée.
    func requestAccess() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ events: [AutomationEvent]) {
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.ruleName
            content.body = event.message
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "automatisation-\(event.id)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    // Les règles sont évaluées quand l'app est ouverte : la notification s'affiche donc
    // aussi au premier plan.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

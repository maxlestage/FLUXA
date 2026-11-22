import ActivityKit
import Foundation
import WidgetKit

/// Donne aux widgets le dernier relevé de l'app, sans épuiser le budget de
/// rafraîchissement qu'iOS accorde aux widgets.
@MainActor
final class WidgetPublisher {
    private var lastReload: Date?
    private var lastWrite: Date?
    private var lastShape: Shape?

    /// Ce qui, en changeant, mérite un rafraîchissement immédiat des widgets.
    private struct Shape: Equatable {
        var isOnline: Bool
        var hasPlan: Bool
        var relayDevices: Int?
    }

    /// Enregistre le relevé ; rafraîchit les widgets si leur allure change, s'il le faut
    /// (`force`, au passage en arrière-plan), ou au plus tous les quarts d'heure.
    func publish(_ snapshot: WidgetSnapshot, force: Bool = false) {
        let shape = Shape(isOnline: snapshot.isOnline, hasPlan: snapshot.plan != nil, relayDevices: snapshot.relay?.devices)
        let now = Date()
        // Le relevé n'est réécrit dans le trousseau que s'il change d'allure, s'il le faut,
        // ou toutes les cinq minutes : les widgets disent l'heure du relevé qu'ils montrent.
        guard Self.shouldWrite(force: force, shapeChanged: shape != lastShape, lastWrite: lastWrite, now: now),
            snapshot.publish()
        else { return }
        lastWrite = now
        if Self.shouldReload(force: force, shapeChanged: shape != lastShape, lastReload: lastReload, now: now) {
            WidgetCenter.shared.reloadAllTimelines()
            lastReload = now
        }
        lastShape = shape
    }

    static func shouldWrite(force: Bool, shapeChanged: Bool, lastWrite: Date?, now: Date) -> Bool {
        guard let lastWrite else { return true }
        return force || shapeChanged || now.timeIntervalSince(lastWrite) >= 5 * 60
    }

    static func shouldReload(force: Bool, shapeChanged: Bool, lastReload: Date?, now: Date) -> Bool {
        guard let lastReload else { return true }
        return force || shapeChanged || now.timeIntervalSince(lastReload) >= 15 * 60
    }
}

/// L'activité en direct du relais : ouverte avec le relais, mise à jour quand l'app tourne,
/// fermée avec lui.
@MainActor
final class RelayActivityController {
    private var activity: Activity<RelayActivityAttributes>?
    private var lastUpdate: Date?
    private var lastState: RelayActivityAttributes.ContentState?

    /// L'ancienneté au-delà de laquelle le système grise le relevé affiché.
    static let staleAfter: TimeInterval = 5 * 60

    var isRunning: Bool { activity != nil }

    func start(_ state: RelayActivityAttributes.ContentState, since startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Une activité restée ouverte pendant que l'app était fermée est reprise.
        if activity == nil {
            activity = Activity<RelayActivityAttributes>.activities.first
        }
        if activity == nil {
            activity = try? Activity.request(
                attributes: RelayActivityAttributes(startedAt: startedAt),
                content: ActivityContent(state: state, staleDate: state.updatedAt.addingTimeInterval(Self.staleAfter)),
                pushType: nil
            )
            lastUpdate = Date()
            lastState = state
        } else {
            update(state, force: true)
        }
    }

    /// Met à jour l'activité, au plus toutes les 10 secondes, sauf si les appareils changent
    /// ou si c'est demandé (`force`).
    func update(_ state: RelayActivityAttributes.ContentState, force: Bool = false) {
        guard let activity else { return }
        let now = Date()
        guard Self.shouldUpdate(force: force, devicesChanged: state.devices != lastState?.devices, lastUpdate: lastUpdate, now: now)
        else { return }
        lastUpdate = now
        lastState = state
        let content = ActivityContent(state: state, staleDate: state.updatedAt.addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content) }
    }

    static func shouldUpdate(force: Bool, devicesChanged: Bool, lastUpdate: Date?, now: Date) -> Bool {
        guard let lastUpdate else { return true }
        return force || devicesChanged || now.timeIntervalSince(lastUpdate) >= 10
    }

    func end() {
        let ending = activity ?? Activity<RelayActivityAttributes>.activities.first
        activity = nil
        lastUpdate = nil
        lastState = nil
        guard let ending else { return }
        Task { await ending.end(nil, dismissalPolicy: .immediate) }
    }
}

import ActivityKit
import CoreTelephony
import Foundation
import Network
import NetworkExtension
import UIKit

/// Les autorisations d'iOS dont FLUXA se sert, et celles-là seulement : une app qui
/// demande ce dont elle n'a pas besoin est refusée par Apple, et trahirait sa promesse.
enum PermissionKind: String, CaseIterable, Identifiable {
    case localNetwork, vpn, notifications, liveActivities, backgroundRefresh, cellularData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localNetwork: "Réseau local"
        case .vpn: "Configuration VPN"
        case .notifications: "Notifications"
        case .liveActivities: "Activités en direct"
        case .backgroundRefresh: "Actualisation en arrière-plan"
        case .cellularData: "Données cellulaires"
        }
    }

    var reason: String {
        switch self {
        case .localNetwork:
            "Les appareils reliés au partage joignent le relais par le réseau local. Sans cette autorisation, ils ne peuvent pas passer par lui."
        case .vpn:
            "Garde le relais en service quand FLUXA est en arrière-plan. Ce tunnel ne transporte aucun trafic de l’iPhone."
        case .notifications:
            "Prévient quand une règle se déclenche : seuil de volume, plage horaire, forfait."
        case .liveActivities:
            "Montre le relais ouvert sur l’écran verrouillé et dans la Dynamic Island."
        case .backgroundRefresh:
            "Permet à iOS de réveiller FLUXA de temps en temps pour mettre à jour l’activité du relais."
        case .cellularData:
            "Laisse FLUXA utiliser le réseau mobile : sonde de latence et test de débit en 4G ou 5G."
        }
    }

    var symbol: String {
        switch self {
        case .localNetwork: "network"
        case .vpn: "lock.shield"
        case .notifications: "bell.badge"
        case .liveActivities: "platter.filled.top.iphone"
        case .backgroundRefresh: "arrow.clockwise.circle"
        case .cellularData: "antenna.radiowaves.left.and.right"
        }
    }

    /// Vrai si l'app peut afficher la demande d'iOS ; sinon, seul l'utilisateur peut
    /// changer le réglage, dans Réglages.
    var canAsk: Bool {
        switch self {
        case .localNetwork, .vpn, .notifications: true
        case .liveActivities, .backgroundRefresh, .cellularData: false
        }
    }
}

enum PermissionState: Equatable {
    case granted, denied, notAsked, pending, unavailable

    var title: String {
        switch self {
        case .granted: "Accordée"
        case .denied: "Refusée"
        case .notAsked: "À demander"
        case .pending: "En attente"
        case .unavailable: "Indisponible ici"
        }
    }

    var pill: StatusPill.Kind {
        switch self {
        case .granted: .supported
        case .denied: .reserved
        case .notAsked, .pending: .guide
        case .unavailable: .simulated
        }
    }
}

/// L'état des autorisations, relu à la demande, et leur demande.
@MainActor
@Observable
final class PermissionCenter {
    private(set) var states: [PermissionKind: PermissionState] = [:]
    private(set) var isAsking = false
    @ObservationIgnored private let cellular = CTCellularData()
    @ObservationIgnored private let notifier = Notifier()

    private static let localNetworkAskedKey = "localNetworkAsked"

    func state(of kind: PermissionKind) -> PermissionState {
        states[kind] ?? .notAsked
    }

    /// Tout ce qui est accordé, ou ne peut l'être que dans Réglages et l'est déjà.
    var allGranted: Bool {
        PermissionKind.allCases.allSatisfy { [.granted, .unavailable].contains(state(of: $0)) }
    }

    /// Relit chaque état sans rien demander. Le réseau local n'a pas d'état lisible : il
    /// n'est vérifié qu'après une première demande, qui affiche la question d'iOS.
    func refresh() async {
        var states: [PermissionKind: PermissionState] = [:]
        states[.notifications] = Self.state(of: await notifier.access())
        states[.liveActivities] = ActivityAuthorizationInfo().areActivitiesEnabled ? .granted : .denied
        states[.backgroundRefresh] = Self.state(of: UIApplication.shared.backgroundRefreshStatus)
        states[.cellularData] = Self.state(of: cellular.restrictedState)
        states[.vpn] = await Self.vpnState()
        if UserDefaults.standard.bool(forKey: Self.localNetworkAskedKey) {
            states[.localNetwork] = await LocalNetworkCheck.run(timeout: 3)
        } else {
            states[.localNetwork] = .notAsked
        }
        self.states = states
    }

    /// Affiche la question d'iOS pour cette autorisation, puis relit son état.
    func ask(_ kind: PermissionKind) async {
        switch kind {
        case .notifications:
            _ = await notifier.requestAccess()
            states[.notifications] = Self.state(of: await notifier.access())
        case .localNetwork:
            UserDefaults.standard.set(true, forKey: Self.localNetworkAskedKey)
            states[.localNetwork] = .pending
            // La question reste affichée tant que l'utilisateur n'a pas répondu.
            states[.localNetwork] = await LocalNetworkCheck.run(timeout: 20)
        case .vpn:
            states[.vpn] = await TunnelRelayHost.installConfiguration() ? .granted : await Self.vpnState()
        case .liveActivities, .backgroundRefresh, .cellularData:
            break
        }
    }

    /// Demande, l'une après l'autre, les autorisations qu'iOS laisse demander et qui ne
    /// sont pas encore accordées.
    func askAll() async {
        guard !isAsking else { return }
        isAsking = true
        defer { isAsking = false }
        for kind in PermissionKind.allCases where kind.canAsk && ![.granted, .unavailable].contains(state(of: kind)) {
            await ask(kind)
        }
        await refresh()
    }

    // MARK: Lecture des états du système, séparée pour être testée

    static func state(of access: Notifier.Access) -> PermissionState {
        switch access {
        case .allowed: .granted
        case .denied: .denied
        case .unknown: .notAsked
        }
    }

    static func state(of status: UIBackgroundRefreshStatus) -> PermissionState {
        switch status {
        case .available: .granted
        case .denied, .restricted: .denied
        @unknown default: .notAsked
        }
    }

    static func state(of restriction: CTCellularDataRestrictedState) -> PermissionState {
        switch restriction {
        case .notRestricted: .granted
        case .restricted: .denied
        case .restrictedStateUnknown: .notAsked
        @unknown default: .notAsked
        }
    }

    private static func vpnState() async -> PermissionState {
        #if targetEnvironment(simulator)
        return .unavailable
        #else
        return await TunnelRelayHost.isConfigured() ? .granted : .notAsked
        #endif
    }
}

/// La vérification du réseau local : FLUXA annonce un service Bonjour et le cherche. La
/// première fois, iOS pose la question ; ensuite, le service est trouvé si l'accès est
/// accordé, et la recherche est refusée sinon.
enum LocalNetworkCheck {
    static let serviceType = "_fluxa._tcp"
    /// `kDNSServiceErr_PolicyDenied` : accès au réseau local refusé par l'utilisateur.
    static let policyDenied: Int32 = -65570

    static func run(timeout: TimeInterval) async -> PermissionState {
        guard let listener = try? NWListener(using: .tcp) else { return .notAsked }
        listener.service = NWListener.Service(name: "FLUXA-\(UUID().uuidString.prefix(8))", type: serviceType)
        listener.newConnectionHandler = { $0.cancel() }
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: NWParameters())
        let once = Once()

        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ state: PermissionState) {
                guard once.claim() else { return }
                listener.cancel()
                browser.cancel()
                continuation.resume(returning: state)
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == policyDenied {
                        finish(.denied)
                    }
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                if !results.isEmpty {
                    finish(.granted)
                }
            }
            listener.start(queue: .main)
            browser.start(queue: .main)
            // Pas de réponse : la question est peut-être encore affichée.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish(.pending)
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

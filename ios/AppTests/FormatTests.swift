import CoreTelephony
import UIKit
import FluxaCore
import XCTest

@testable import Fluxa

/// L'écriture des mesures et les petites règles de l'interface.
@MainActor
final class FormatTests: XCTestCase {
    private let space = "\u{00A0}"

    func testAMissingMeasureIsADashNeverAZero() {
        XCTAssertEqual(Format.rate(nil), "—")
        XCTAssertEqual(Format.rateParts(nil).value, "—")
        XCTAssertEqual(Format.milliseconds(nil), "—")
        XCTAssertEqual(Format.percent(nil), "—")
    }

    func testRatesAreWrittenTheFrenchWay() {
        XCTAssertEqual(Format.rate(42_800_000), "42,8\(space)Mb/s")
        XCTAssertEqual(Format.rate(0), "0,0\(space)Mb/s")
        XCTAssertEqual(Format.rateParts(50_000).unit, "kb/s")
        XCTAssertEqual(Format.rateParts(50_000).value, "50")
        XCTAssertEqual(Format.rateParts(800).unit, "b/s")
    }

    func testCapsShowTheirRateOrTheirAbsence() {
        XCTAssertEqual(Format.cap(25_000_000), "25\(space)Mb/s")
        XCTAssertEqual(Format.cap(500_000), "0,5\(space)Mb/s")
        XCTAssertEqual(Format.cap(nil), "Sans plafond")
    }

    func testVolumesUseDecimalUnits() {
        XCTAssertEqual(Format.bytes(0), "0\(space)o")
        XCTAssertEqual(Format.bytes(999), "999\(space)o")
        XCTAssertEqual(Format.bytes(2_500_000), "2,5\(space)Mo")
        XCTAssertEqual(Format.bytes(1_200_000_000), "1,20\(space)Go")
    }

    func testDurations() {
        XCTAssertEqual(Format.milliseconds(17.4), "17\(space)ms")
        XCTAssertEqual(Format.duration(seconds: 900), "15\(space)min")
        XCTAssertEqual(Format.duration(seconds: 28_800), "8\(space)h")
        XCTAssertEqual(Format.duration(seconds: nil), "Sans limite de temps")
    }

    func testTheLimiterScaleRunsFromATenthToAThousand() {
        XCTAssertEqual(LimiterView.mbps(at: 0), 0.1, accuracy: 1e-9)
        XCTAssertEqual(LimiterView.mbps(at: 1), 1_000, accuracy: 1e-6)
        XCTAssertEqual(LimiterView.mbps(at: LimiterView.position(forMbps: 25)), 25, accuracy: 1e-6)
        XCTAssertEqual(LimiterView.mbps(at: LimiterView.position(forMbps: 0.5)), 0.5, accuracy: 1e-9)
        // Hors de l'échelle, le curseur reste sur ses bornes.
        XCTAssertEqual(LimiterView.mbps(at: -1), 0.1, accuracy: 1e-9)
        XCTAssertEqual(LimiterView.mbps(at: 2), 1_000, accuracy: 1e-6)
        var previous = 0.0
        for step in 0...100 {
            let value = LimiterView.mbps(at: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertNoThrow(try FluxaEngine(store: MemoryStore()).validate(
                BandwidthPolicy(downloadBps: Limits.bps(fromMbps: value))
            ))
            previous = value
        }
    }

    func testOnlyInterfacesThatCarryInternetTrafficAreCounted() {
        XCTAssertEqual(InterfaceCounters.classify("en0"), .wifi)
        XCTAssertEqual(InterfaceCounters.classify("pdp_ip0"), .cellular)
        XCTAssertEqual(InterfaceCounters.classify("en2"), .wired)
        XCTAssertNil(InterfaceCounters.classify("utun3"))
        // Le pont du partage est suivi à part : il ne compte pas dans le débit de l'iPhone.
        XCTAssertEqual(InterfaceCounters.classify("bridge100"), .sharing)
        XCTAssertNil(InterfaceCounters.classify("bridge0"))
        XCTAssertNil(InterfaceCounters.classify("awdl0"))
        XCTAssertNil(InterfaceCounters.classify("lo0"))
    }

    func testTheSystemCountersAreReadable() {
        // Dans le simulateur comme sur un iPhone, au moins une interface est active.
        let readings = InterfaceCounters.read()
        XCTAssertFalse(readings.isEmpty)
        XCTAssertEqual(Set(readings.map(\.name)).count, readings.count, "une entrée par interface")
    }

    func testSharingIsDetectedFromItsBridgeInterface() {
        XCTAssertTrue(InterfaceCounters.isSharing([("en0", true), ("bridge100", true)]))
        XCTAssertFalse(InterfaceCounters.isSharing([("en0", true), ("bridge100", false)]), "interface à l'arrêt")
        // Le pont Thunderbolt d'un Mac (bridge0) n'est pas un partage de connexion.
        XCTAssertFalse(InterfaceCounters.isSharing([("en0", true), ("bridge0", true)]))
        XCTAssertFalse(InterfaceCounters.isSharing([]))
    }

    func testRulesAreSummarisedInOneSentence() {
        let profiles = [Profile(id: "economy", name: "Économie", downloadBps: 1_000_000, uploadBps: 500_000, isBuiltin: true)]
        let threshold = AutomationRule(name: "Forfait", trigger: .dailyUsage(bytes: 2_000_000_000), action: .alert)
        XCTAssertEqual(
            RuleText.summary(of: threshold, profiles: profiles),
            "À 2,00\(space)Go dans la journée : prévenir"
        )
        let night = AutomationRule(
            name: "Nuit",
            trigger: .schedule(startMinute: 22 * 60, endMinute: 7 * 60, weekdays: []),
            action: .activateProfile(id: "economy")
        )
        XCTAssertEqual(RuleText.summary(of: night, profiles: profiles), "De 22:00 à 07:00, tous les jours : profil Économie")
        let gone = AutomationRule(name: "x", trigger: .dailyUsage(bytes: 1_000_000), action: .activateProfile(id: "absent"))
        XCTAssertTrue(RuleText.summary(of: gone, profiles: profiles).hasSuffix("profil supprimé"))
    }

    func testARuleDraftGoesBackAndForth() {
        var draft = RuleDraft(defaultProfile: "economy")
        draft.name = "Forfait"
        draft.amount = 1.5
        draft.unit = .gigabytes
        XCTAssertEqual(draft.rule.trigger, .dailyUsage(bytes: 1_500_000_000))
        XCTAssertEqual(draft.rule.action, .alert)

        draft.kind = .schedule
        draft.start = RuleDraft.time(minutes: 22 * 60 + 30)
        draft.end = RuleDraft.time(minutes: 6 * 60)
        draft.weekdays = [2, 3]
        draft.changesProfile = true
        let rule = draft.rule
        XCTAssertEqual(rule.trigger, .schedule(startMinute: 1_350, endMinute: 360, weekdays: [2, 3]))
        XCTAssertEqual(rule.action, .activateProfile(id: "economy"))
        // Relue pour être modifiée, la règle donne la même saisie.
        XCTAssertEqual(RuleDraft(rule).rule, rule)

        // Une saisie invalide ne plante pas : elle donne un seuil nul, que le moteur refuse.
        draft.kind = .usage
        draft.amount = -3
        XCTAssertEqual(draft.rule.trigger, .dailyUsage(bytes: 0))
    }

    func testARuleCanWatchThePlan() {
        var draft = RuleDraft(defaultProfile: "economy")
        draft.name = "Fin de forfait"
        draft.kind = .plan
        draft.percent = 80
        let rule = draft.rule
        XCTAssertEqual(rule.trigger, .planUsage(percent: 80))
        XCTAssertEqual(RuleDraft(rule).rule, rule)
        XCTAssertEqual(RuleText.summary(of: rule, profiles: []), "À 80\(space)% du forfait : prévenir")
    }

    // MARK: Forfait, hors de l'app, partage

    private func planStatus(used: UInt64, projected: UInt64? = nil, exhaustion: Date? = nil, days: Int = 16)
        -> PlanStatus
    {
        let allowance: UInt64 = 50_000_000_000
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 0))!
        let end = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 5, hour: 0))!
        let remaining = allowance > used ? allowance - used : 0
        return PlanStatus(
            plan: DataPlan(allowanceBytes: allowance, resetDay: 5),
            cycleStart: start,
            cycleEnd: end,
            usedBytes: used,
            measuredBytes: used,
            outsideAppBytes: 0,
            calibratedBytes: nil,
            remainingBytes: remaining,
            fractionUsed: Double(used) / Double(allowance),
            daysRemaining: days,
            dailyBudgetBytes: remaining / UInt64(max(days, 1)),
            projectedBytes: projected,
            exhaustionDate: exhaustion
        )
    }

    func testThePlanIsTypedInGigabytes() {
        XCTAssertEqual(PlanText.bytes(fromGigabytes: "50"), 50_000_000_000)
        XCTAssertEqual(PlanText.bytes(fromGigabytes: " 12,5 "), 12_500_000_000)
        XCTAssertEqual(PlanText.bytes(fromGigabytes: "0.5"), 500_000_000)
        XCTAssertEqual(PlanText.bytes(fromGigabytes: "0"), 0)
        XCTAssertNil(PlanText.bytes(fromGigabytes: ""))
        XCTAssertNil(PlanText.bytes(fromGigabytes: "-3"))
        XCTAssertNil(PlanText.bytes(fromGigabytes: "beaucoup"))
        XCTAssertNil(PlanText.bytes(fromGigabytes: "1e12"))
        // Remis dans son champ, un volume se relit tel quel.
        XCTAssertEqual(PlanText.field(50_000_000_000), "50")
        XCTAssertEqual(PlanText.field(12_500_000_000), "12,5")
        XCTAssertEqual(PlanText.bytes(fromGigabytes: PlanText.field(1_234_000_000_000)), 1_234_000_000_000)
        XCTAssertEqual(Format.gigabytes(50_000_000_000), "50\(space)Go")
        XCTAssertEqual(Format.gigabytes(12_500_000_000), "12,5\(space)Go")
    }

    func testThePlanIsSummarisedWithoutPromisingMoreThanMeasured() {
        let comfortable = planStatus(used: 12_400_000_000, projected: 30_000_000_000)
        XCTAssertEqual(PlanText.summary(comfortable), "Reste 37,60\(space)Go · 16 jours")
        XCTAssertEqual(PlanText.level(comfortable.fractionUsed), .comfortable)
        XCTAssertEqual(PlanText.projection(comfortable), "À ce rythme : 30,00\(space)Go en fin de cycle, sous votre forfait.")
        XCTAssertTrue(PlanText.reset(comfortable).hasSuffix("dans 16 jours"))
        XCTAssertTrue(PlanText.reset(comfortable).contains("5"))

        let exhaustion = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 12))!
        let close = planStatus(used: 41_000_000_000, projected: 70_000_000_000, exhaustion: exhaustion, days: 1)
        XCTAssertEqual(PlanText.level(close.fractionUsed), .close)
        XCTAssertTrue(PlanText.projection(close).contains("forfait épuisé vers le 24"))
        XCTAssertEqual(PlanText.summary(close), "Reste 9,00\(space)Go · 1 jour")
        XCTAssertTrue(PlanText.reset(close).hasSuffix("demain au plus tard"))

        let over = planStatus(used: 51_000_000_000)
        XCTAssertEqual(PlanText.level(over.fractionUsed), .reached)
        XCTAssertEqual(PlanText.projection(over), "Le forfait est dépassé pour ce cycle.")
        XCTAssertTrue(PlanText.summary(over).hasPrefix("Forfait dépassé"))

        // Avant un jour de cycle, pas de projection inventée.
        XCTAssertEqual(PlanText.projection(planStatus(used: 1_000_000)), "La projection s’affiche après un jour de cycle.")
        // Sans volume, pas de rythme à prolonger.
        XCTAssertEqual(
            PlanText.projection(planStatus(used: 0, projected: 0)),
            "Aucun volume compté sur le réseau mobile dans ce cycle."
        )
        // Un volume rattrapé est un minimum, et le dit.
        XCTAssertEqual(PlanText.atLeast(1_200_000_000), "au moins 1,20\(space)Go")
        XCTAssertEqual(PlanText.atLeast(0), "0\(space)o")
    }

    func testWhatHappenedOutsideTheAppIsAMinimum() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let absence = AbsenceUsage(
            id: 1,
            start: start,
            end: start.addingTimeInterval(7_500),
            volumes: [
                NetworkVolume(kind: .wifi, receivedBytes: 500_000_000, sentBytes: 100_000_000),
                NetworkVolume(kind: .cellular, receivedBytes: 1_100_000_000, sentBytes: 100_000_000),
            ]
        )
        XCTAssertEqual(AbsenceText.headline(absence), "Au moins 1,80\(space)Go en 2\(space)h\(space)05")
        let detail = AbsenceText.detail(absence)
        XCTAssertTrue(detail.hasPrefix("Réseau mobile : 1,20\(space)Go · Wi-Fi : 600,0\(space)Mo."), detail)
        XCTAssertTrue(detail.contains("compteurs du système"))
    }

    func testDurationsAreWrittenShort() {
        XCTAssertEqual(Format.span(45), "45\(space)s")
        XCTAssertEqual(Format.span(12 * 60 + 20), "12\(space)min")
        XCTAssertEqual(Format.span(2 * 3_600 + 5 * 60), "2\(space)h\(space)05")
        XCTAssertEqual(Format.span(3 * 86_400 + 4 * 3_600), "3\(space)j\(space)4\(space)h")
        XCTAssertEqual(Format.span(-5), "0\(space)s")
    }

    func testASharingSessionSaysWhatWentToTheDevices() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var session = SharingSession(
            id: 1, start: start, end: start.addingTimeInterval(720),
            toDevicesBytes: 300_000_000, fromDevicesBytes: 40_000_000, isLowerBound: false)
        XCTAssertEqual(SharingText.session(session), "Session de 12\(space)min · 340,0\(space)Mo")
        session.isLowerBound = true
        XCTAssertEqual(SharingText.volume(session), "au moins 340,0\(space)Mo")
        let live = SharingStatus(session: session, toDevicesBps: 3_200_000, fromDevicesBps: nil)
        // Un débit pas encore mesuré reste un tiret.
        XCTAssertEqual(SharingText.rates(live), "↓ 3,2\(space)Mb/s vers les appareils · ↑ — reçus")
    }

    func testTheVolumePerNetworkSaysWhatWasCaughtUp() {
        let mobile = NetworkUsage(
            kind: .cellular, receivedBytes: 1_200_000_000, sentBytes: 80_000_000, outsideAppBytes: 900_000_000)
        XCTAssertEqual(
            HistoryView.detail(mobile),
            "↓ 1,20\(space)Go · ↑ 80,0\(space)Mo · dont au moins 900,0\(space)Mo hors de l’app"
        )
        let wifi = NetworkUsage(kind: .wifi, receivedBytes: 10_000_000, sentBytes: 0, outsideAppBytes: 0)
        XCTAssertEqual(HistoryView.detail(wifi), "↓ 10,0\(space)Mo · ↑ 0\(space)o")
        XCTAssertEqual(HistoryView.share(50, of: 200), 0.25)
        XCTAssertEqual(HistoryView.share(0, of: 0), 0)
        XCTAssertEqual(HistoryView.share(300, of: 200), 1)
        for kind in InterfaceClass.allCases { XCTAssertFalse(kind.title.isEmpty) }
    }

    func testTheProbeSlowsDownWhenTheSystemSaves() {
        XCTAssertEqual(AppModel.probeInterval(lowPower: false, lowData: false), 5)
        XCTAssertEqual(AppModel.probeInterval(lowPower: true, lowData: false), 15)
        // Le mode données réduites l'emporte : c'est lui qui compte les octets.
        XCTAssertEqual(AppModel.probeInterval(lowPower: true, lowData: true), 30)
        XCTAssertEqual(SettingsView.probeCadence(5), "toutes les 5 s")
        XCTAssertEqual(SettingsView.probeCadence(15), "toutes les 15 s (réseau mobile ou économie d’énergie)")
        // Sur réseau mobile, la radio n'est plus réveillée toutes les cinq secondes.
        XCTAssertEqual(AppModel.probeInterval(lowPower: false, lowData: false, metered: true), 15)
        XCTAssertEqual(AppModel.probeInterval(lowPower: false, lowData: true, metered: true), 30)
        XCTAssertEqual(SettingsView.probeCadence(30), "toutes les 30 s (données réduites)")
    }

    func testAMeteredSpeedTestSaysWhatItCosts() {
        XCTAssertTrue(SpeedTestView.meteredWarning(remaining: nil).contains("260 Mo"))
        XCTAssertTrue(
            SpeedTestView.meteredWarning(remaining: 9_000_000_000).hasSuffix("Il vous reste 9,00\(space)Go d’après FLUXA."))
    }

    func testTheBootTimeIsKnown() throws {
        // L'heure de démarrage sert à savoir si deux relevés des compteurs se comparent.
        let boot = try XCTUnwrap(InterfaceCounters.bootTime())
        XCTAssertLessThan(boot, Date())
        let again = try XCTUnwrap(InterfaceCounters.bootTime())
        XCTAssertEqual(boot.timeIntervalSince(again), 0, accuracy: 10)
    }

    func testTheRustModuleAnswersThroughTheCABI() throws {
        let report = try XCTUnwrap(KernelShaper.tryApply(BandwidthPolicyRates(downloadBps: 5_000_000, uploadBps: nil)))
        XCTAssertEqual(report.attempts.map(\.mechanism), ["pf", "dummynet", "sysctl"])
        XCTAssertEqual(report.downloadBps, 5_000_000)
        XCTAssertNil(report.uploadBps)
        // Aucune règle n'est posée : rien n'est jamais annoncé appliqué.
        XCTAssertFalse(report.applied)
        XCTAssertFalse(KernelShaper.version.isEmpty)
    }

    func testARefusalReportIsReadable() throws {
        let json = """
        {"version":"0.1.0","download_bps":1000000,"upload_bps":null,"sharing_interface":"bridge100",\
        "applied":false,"system_allows":false,"summary":"iOS a refusé.","attempts":[{"mechanism":"pf",\
        "title":"Filtre de paquets (pf)","outcome":"refused","code":"EPERM","message":"Refusé."}]}
        """
        let report = try XCTUnwrap(KernelShaper.decode(json))
        XCTAssertEqual(report.sharingInterface, "bridge100")
        XCTAssertEqual(report.attempts.first?.outcome, .refused)
        XCTAssertEqual(report.attempts.first?.code, "EPERM")
        XCTAssertEqual(LimiterView.title(for: .refused), "Refusé")
        XCTAssertEqual(LimiterView.title(for: .accepted), "Accordé")
    }

    // MARK: Relais de partage

    func testTheRelayOpensAndClosesThroughTheCABI() throws {
        XCTAssertEqual(RelayBridge.start(allowLoopback: true), 0)
        defer { RelayBridge.stop() }
        RelayBridge.setLimit(downloadBps: 8_000_000, uploadBps: nil)
        XCTAssertEqual(RelayBridge.setDeviceLimit(address: "172.20.10.3", downloadBps: 800_000, uploadBps: nil), 0)
        XCTAssertNotEqual(RelayBridge.setDeviceLimit(address: "pas une adresse", downloadBps: 1, uploadBps: 1), 0)
        let status = try XCTUnwrap(RelayBridge.status())
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.port, RelayBridge.port)
        XCTAssertEqual(status.downloadLimit, 1_000_000, "octets par seconde")
        XCTAssertEqual(status.uploadLimit, 0)
        RelayBridge.stop()
        XCTAssertEqual(RelayBridge.status()?.running, false)
    }

    func testMeasuresTakeOneColumnAtAccessibilitySizes() {
        XCTAssertEqual(MeasureTilesLayout.columnCount(for: .large), 2)
        XCTAssertEqual(MeasureTilesLayout.columnCount(for: .xxxLarge), 2)
        XCTAssertEqual(MeasureTilesLayout.columnCount(for: .accessibility1), 1)
        XCTAssertEqual(MeasureTilesLayout.columnCount(for: .accessibility5), 1)
    }

    // MARK: Crédits, Siri et Raccourcis

    func testTheAboutScreenNamesTheAuthorAndTheBuild() {
        XCTAssertEqual(AppInfo.author, "Maxime Nathan Lestage")
        XCTAssertEqual(AppInfo.line(version: "1.0", build: "12"), "Version 1.0 (build 12)")
        XCTAssertFalse(AppInfo.build.isEmpty)
    }

    func testSiriAnswersFromTheLastReading() {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let now = Date()
        var snapshot = WidgetSnapshot.example
        snapshot.updatedAt = now
        let today = IntentText.today(snapshot, now: now)
        XCTAssertTrue(today.hasPrefix("Aujourd’hui : 1,24\(space)Go reçus et envoyés."), today)
        XCTAssertTrue(today.contains("Relevé à"), "l'heure du relevé est dite")
        XCTAssertEqual(IntentText.plan(snapshot, now: now).hasPrefix("Il reste 37,60\(space)Go sur 50\(space)Go."), true)
        snapshot.plan = nil
        XCTAssertEqual(IntentText.plan(snapshot, now: now), "Aucun forfait n’est réglé dans FLUXA.")
        XCTAssertTrue(IntentText.today(nil).hasPrefix("Ouvrez FLUXA"))
    }

    func testAShortcutRequestIsTakenOnce() {
        let router = IntentRouter.shared
        router.request(.openRelay)
        XCTAssertEqual(router.take(), .openRelay)
        XCTAssertNil(router.take())
    }

    // MARK: Autorisations

    func testEachPermissionSaysWhyAndWhatToDo() {
        for kind in PermissionKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.reason.isEmpty)
        }
        // Ce qu'iOS laisse demander se demande ; le reste mène à Réglages.
        XCTAssertEqual(PermissionText.action(for: .notifications, state: .notAsked), .ask)
        XCTAssertEqual(PermissionText.action(for: .localNetwork, state: .notAsked), .ask)
        XCTAssertEqual(PermissionText.action(for: .vpn, state: .notAsked), .ask)
        XCTAssertEqual(PermissionText.action(for: .liveActivities, state: .notAsked), .settings)
        XCTAssertEqual(PermissionText.action(for: .cellularData, state: .notAsked), .settings)
        // Une autorisation refusée ne se redemande pas : iOS ne repose pas la question.
        XCTAssertEqual(PermissionText.action(for: .notifications, state: .denied), .settings)
        XCTAssertEqual(PermissionText.action(for: .localNetwork, state: .granted), .none)
        XCTAssertEqual(PermissionText.action(for: .vpn, state: .unavailable), .none)
    }

    func testSystemStatesAreReadPlainly() {
        XCTAssertEqual(PermissionCenter.state(of: Notifier.Access.allowed), .granted)
        XCTAssertEqual(PermissionCenter.state(of: Notifier.Access.denied), .denied)
        XCTAssertEqual(PermissionCenter.state(of: Notifier.Access.unknown), .notAsked)
        XCTAssertEqual(PermissionCenter.state(of: UIBackgroundRefreshStatus.available), .granted)
        XCTAssertEqual(PermissionCenter.state(of: UIBackgroundRefreshStatus.denied), .denied)
        XCTAssertEqual(PermissionCenter.state(of: UIBackgroundRefreshStatus.restricted), .denied)
        XCTAssertEqual(PermissionCenter.state(of: CTCellularDataRestrictedState.notRestricted), .granted)
        XCTAssertEqual(PermissionCenter.state(of: CTCellularDataRestrictedState.restricted), .denied)
        XCTAssertEqual(PermissionState.granted.title, "Accordée")
        XCTAssertEqual(PermissionState.denied.title, "Refusée")
    }

    // MARK: Widgets et activité en direct

    func testTheWidgetSnapshotSurvivesItsStorage() throws {
        XCTAssertNil(WidgetSnapshot.decode(nil), "sans relevé, rien")
        var snapshot = WidgetSnapshot.example
        snapshot.relay = WidgetSnapshot.Relay(devices: 2, toDevicesBps: 3_200_000, cap: "↓ 5 Mb/s · ↑ Sans plafond")
        XCTAssertEqual(WidgetSnapshot.decode(snapshot.encoded()), snapshot)
        // Un relevé illisible ne fait pas planter le widget.
        XCTAssertNil(WidgetSnapshot.decode(Data("abîmé".utf8)))
    }

    func testWidgetsSayWhenTheReadingWasTaken() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 15, minute: 0))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 14, minute: 32))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 22, minute: 5))!
        XCTAssertTrue(WidgetText.updated(earlier, now: now, calendar: calendar).hasPrefix("Relevé à "))
        XCTAssertTrue(WidgetText.updated(yesterday, now: now, calendar: calendar).hasPrefix("Relevé le "))
        // Après minuit, le volume de la veille n'est plus « aujourd’hui ».
        XCTAssertEqual(WidgetText.day(of: earlier, now: now, calendar: calendar), "Aujourd’hui")
        XCTAssertTrue(WidgetText.day(of: yesterday, now: now, calendar: calendar).hasPrefix("Le 20"))
        let plan = WidgetSnapshot.Plan(
            usedBytes: 12_400_000_000, allowanceBytes: 50_000_000_000, remainingBytes: 37_600_000_000,
            fractionUsed: 0.248, cycleEnd: now)
        XCTAssertEqual(WidgetText.planRemaining(plan), "Reste 37,60\(space)Go")
        var over = plan
        over.usedBytes = 51_000_000_000
        XCTAssertEqual(WidgetText.planRemaining(over), "Forfait dépassé")
        XCTAssertEqual(WidgetText.percent(0.248), "25\(space)%")
        XCTAssertEqual(RelayActivityText.devices(0), "Aucun appareil")
        XCTAssertEqual(RelayActivityText.devices(1), "1 appareil")
        XCTAssertEqual(RelayActivityText.devices(3), "3 appareils")
        XCTAssertEqual(RelayActivityText.rate(nil), "—", "un débit non mesuré reste un tiret")
    }

    func testABackgroundWakeUpGivesTheActivityFreshFigures() throws {
        func status(_ clients: [(String, Int, UInt64)]) -> RelayStatus {
            let list = clients.map { address, connections, bytes in
                "{\"address\":\"\(address)\",\"connections\":\(connections),\"to_device_bytes\":\(bytes),\"from_device_bytes\":0,\"idle_seconds\":0,\"download_limit\":0,\"upload_limit\":0}"
            }.joined(separator: ",")
            return RelayStatus.decode("{\"running\":true,\"clients\":[\(list)]}")!
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = status([("172.20.10.3", 2, 1_000_000), ("172.20.10.4", 0, 500)])
        let second = status([("172.20.10.3", 2, 1_400_000), ("172.20.10.4", 0, 500), ("172.20.10.5", 1, 9_000)])
        let state = AppModel.relayActivityState(first: first, second: second, seconds: 1, cap: "Sans plafond", now: now)
        // Deux appareils actifs ; le débit vient du seul appareil vu aux deux relevés.
        XCTAssertEqual(state.devices, 2)
        XCTAssertEqual(state.toDevicesBps, 3_200_000)
        XCTAssertEqual(state.updatedAt, now)
        // Sans écart mesurable, pas de débit inventé.
        let idle = AppModel.relayActivityState(first: second, second: second, seconds: 0, cap: "Sans plafond", now: now)
        XCTAssertNil(idle.toDevicesBps)
    }

    func testWidgetsAndTheActivityAreRefreshedSparingly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(WidgetPublisher.shouldReload(force: false, shapeChanged: false, lastReload: nil, now: now))
        XCTAssertFalse(WidgetPublisher.shouldReload(force: false, shapeChanged: false, lastReload: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(WidgetPublisher.shouldReload(force: false, shapeChanged: true, lastReload: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(WidgetPublisher.shouldReload(force: true, shapeChanged: false, lastReload: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(WidgetPublisher.shouldReload(force: false, shapeChanged: false, lastReload: now.addingTimeInterval(-900), now: now))
        XCTAssertFalse(RelayActivityController.shouldUpdate(force: false, devicesChanged: false, lastUpdate: now.addingTimeInterval(-3), now: now))
        XCTAssertTrue(RelayActivityController.shouldUpdate(force: false, devicesChanged: true, lastUpdate: now.addingTimeInterval(-3), now: now))
        XCTAssertTrue(RelayActivityController.shouldUpdate(force: false, devicesChanged: false, lastUpdate: now.addingTimeInterval(-10), now: now))
    }

    func testTheCopyConfirmationLastsTwoSecondsUnlessATestAsksMore() {
        let defaults = UserDefaults(suiteName: "copie-\(UUID().uuidString)")!
        XCTAssertEqual(RelayText.copyConfirmationSeconds(defaults), 2)
        defaults.set(30.0, forKey: "fluxaCopyConfirmationSeconds")
        XCTAssertEqual(RelayText.copyConfirmationSeconds(defaults), 30)
        defaults.set(0.5, forKey: "fluxaCopyConfirmationSeconds")
        XCTAssertEqual(RelayText.copyConfirmationSeconds(defaults), 2, "jamais moins de deux secondes")
    }

    func testACopyRowSaysWhetherItWasCopied() {
        XCTAssertEqual(
            RelayText.copyLabel("Mandataire", value: "172.20.10.1:8888", copied: false),
            "Mandataire : 172.20.10.1:8888. Toucher pour copier.")
        XCTAssertEqual(
            RelayText.copyLabel("Mandataire", value: "172.20.10.1:8888", copied: true),
            "Mandataire : 172.20.10.1:8888. Copié.")
    }

    func testTheDashboardSummarisesTheRelay() {
        func client(_ address: String, connections: Int) -> RelayStatus.Client {
            RelayStatus.Client(
                address: address, connections: connections, toDeviceBytes: 0, fromDeviceBytes: 0,
                idleSeconds: 0, downloadLimit: 0, uploadLimit: 0)
        }
        XCTAssertEqual(
            RelayText.dashboardSummary(clients: [], rates: [:]),
            "Relais ouvert : aucun appareil ne passe par lui pour l’instant."
        )
        // Un appareil inactif ne compte pas.
        XCTAssertEqual(
            RelayText.dashboardSummary(clients: [client("172.20.10.3", connections: 0)], rates: [:]),
            "Relais ouvert : aucun appareil ne passe par lui pour l’instant."
        )
        let clients = [client("172.20.10.3", connections: 2), client("172.20.10.4", connections: 1)]
        // Sans débit encore mesuré, pas de chiffre inventé.
        XCTAssertEqual(RelayText.dashboardSummary(clients: clients, rates: [:]), "2 appareils relayés")
        let rates = [
            "172.20.10.3": RelayRate(toDeviceBps: 3_000_000, fromDeviceBps: 0),
            "172.20.10.4": RelayRate(toDeviceBps: 400_000, fromDeviceBps: 0),
        ]
        XCTAssertEqual(
            RelayText.dashboardSummary(clients: clients, rates: rates), "2 appareils relayés · 3,4\(space)Mb/s vers eux")
        XCTAssertEqual(
            RelayText.dashboardSummary(clients: [clients[0]], rates: rates), "1 appareil relayé · 3,0\(space)Mb/s vers eux")
    }

    func testVoiceOverReadsARelayedDeviceInOneSentence() {
        let client = RelayStatus.Client(
            address: "172.20.10.3", connections: 2, toDeviceBytes: 120_000_000, fromDeviceBytes: 8_000_000,
            idleSeconds: 0, downloadLimit: 0, uploadLimit: 0)
        let rate = RelayRate(toDeviceBps: 3_200_000, fromDeviceBps: 400_000)
        let named = RelayText.spoken(name: "MacBook de Léa", client: client, rate: rate)
        XCTAssertEqual(
            named,
            "MacBook de Léa. 172.20.10.3. débit vers l’appareil 3,2\(space)Mb/s, depuis l’appareil 0,4\(space)Mb/s. relayé : 120,0\(space)Mo vers l’appareil, 8,0\(space)Mo depuis l’appareil. 2 connexions"
        )
        XCTAssertFalse(named.contains("↓") || named.contains("↑"), "les flèches ne se lisent pas")
        // Sans nom, l'adresse n'est pas répétée ; sans débit mesuré, un tiret, jamais un zéro.
        let anonymous = RelayText.spoken(name: nil, client: client, rate: nil)
        XCTAssertTrue(anonymous.hasPrefix("172.20.10.3. débit vers l’appareil —"), anonymous)
    }

    func testTheRelayIsPolledOftenOnlyWhenWatched() {
        XCTAssertEqual(AppModel.relayPollInterval(screenVisible: true), 1)
        XCTAssertEqual(AppModel.relayPollInterval(screenVisible: false), 5)
    }

    func testAStoppedRelayIsReopenedWithoutHammering() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(AppModel.shouldReopenRelay(lastAttempt: nil, now: now))
        XCTAssertFalse(AppModel.shouldReopenRelay(lastAttempt: now.addingTimeInterval(-10), now: now))
        XCTAssertTrue(AppModel.shouldReopenRelay(lastAttempt: now.addingTimeInterval(-30), now: now))
    }

    func testTheRelayFollowsTheDisplayedCap() {
        var sent = RelayLimits(download: 5_000_000, upload: 1_000_000)
        sent.devices["172.20.10.3"] = (800_000, nil)
        var same = RelayLimits(download: 5_000_000, upload: 1_000_000)
        same.devices["172.20.10.3"] = (800_000, nil)
        XCTAssertFalse(AppModel.relayNeedsUpdate(sent: sent, wanted: same))
        // Une règle change de profil, ou la limite arrive à échéance : le relais suit.
        XCTAssertTrue(AppModel.relayNeedsUpdate(sent: sent, wanted: RelayLimits(download: 1_000_000, upload: 500_000, devices: sent.devices)))
        XCTAssertTrue(AppModel.relayNeedsUpdate(sent: sent, wanted: RelayLimits(download: nil, upload: nil, devices: sent.devices)))
        // Le plafond d'un appareil change ou disparaît.
        XCTAssertTrue(AppModel.relayNeedsUpdate(sent: sent, wanted: RelayLimits(download: 5_000_000, upload: 1_000_000)))
        XCTAssertTrue(AppModel.relayNeedsUpdate(sent: nil, wanted: same))
        // Le message à l'extension garde un ordre stable.
        XCTAssertEqual(sent.message, same.message)
    }

    func testRelayRatesComeFromTwoReadings() {
        func client(_ down: UInt64, _ up: UInt64) -> RelayStatus.Client {
            RelayStatus.Client(
                address: "172.20.10.3", connections: 1, toDeviceBytes: down, fromDeviceBytes: up,
                idleSeconds: 0, downloadLimit: 0, uploadLimit: 0)
        }
        let rate = RelayRate.between(client(1_000_000, 10_000), client(2_250_000, 60_000), seconds: 2)
        XCTAssertEqual(rate.toDeviceBps, 5_000_000)
        XCTAssertEqual(rate.fromDeviceBps, 200_000)
        // Premier relevé, ou compteurs repartis de zéro : pas de débit inventé.
        XCTAssertNil(RelayRate.between(nil, client(5, 5), seconds: 1).toDeviceBps)
        XCTAssertNil(RelayRate.between(client(9, 9), client(5, 5), seconds: 1).toDeviceBps)
    }

    func testTheRelayStatusIsReadable() throws {
        let json = """
        {"running":true,"port":8888,"active_connections":3,"max_connections":192,"download_limit":625000,"upload_limit":0,"addresses":["172.20.10.1"],\
        "clients":[{"address":"172.20.10.3","connections":2,"to_device_bytes":1200,"from_device_bytes":300,\
        "idle_seconds":0.4,"download_limit":0,"upload_limit":0}]}
        """
        let status = try XCTUnwrap(RelayStatus.decode(json))
        XCTAssertEqual(status.address, "172.20.10.1")
        XCTAssertEqual(status.activeConnections, 3)
        XCTAssertEqual(status.maxConnections, 192)
        XCTAssertEqual(RelayText.load(active: 3, maximum: 192), "3 sur 192")
        XCTAssertEqual(RelayText.load(active: 192, maximum: 192), "192 sur 192, nouvelles refusées")
        XCTAssertEqual(status.clients?.first?.toDeviceBytes, 1_200)
        XCTAssertEqual(RelayStatus.decode("{\"running\":false}")?.running, false)
        XCTAssertEqual(RelayStatus.decode("{\"running\":false}")?.address, RelayBridge.defaultAddress)
        XCTAssertEqual(RelayText.pacURL(address: "172.20.10.1"), "http://172.20.10.1:8888/proxy.pac")
        XCTAssertEqual(RelayText.cap(nil), "Sans plafond")
        XCTAssertEqual(RelayText.cap(BandwidthPolicy(downloadBps: 5_000_000)), "↓ 5\(space)Mb/s · ↑ Sans plafond")
        XCTAssertEqual(RelayText.connections(0), "inactif")
        // Un appareil nommé garde son nom ; sinon, son adresse.
        XCTAssertEqual(RelayText.displayName("  MacBook de Léa  ", address: "172.20.10.3"), "MacBook de Léa")
        XCTAssertEqual(RelayText.displayName(nil, address: "172.20.10.3"), "172.20.10.3")
        XCTAssertEqual(RelayText.displayName("   ", address: "172.20.10.3"), "172.20.10.3")
        XCTAssertNil(RelayText.cleanName(" \n "))
        XCTAssertEqual(RelayText.cleanName(String(repeating: "a", count: 60))?.count, 40)
        XCTAssertEqual(RelayText.connections(2), "2 connexions")
        XCTAssertTrue(AppModel.relayProblem(EADDRINUSE).contains("8888"))
    }

    func testAChangeOfVolumeIsSaidPlainly() {
        func comparison(_ percent: Double?, now: UInt64 = 0, before: UInt64 = 0) -> UsageComparison {
            UsageComparison(
                current: UsageSummary(receivedBytes: now),
                previous: UsageSummary(receivedBytes: before),
                changePercent: percent
            )
        }
        XCTAssertEqual(HistoryView.change(comparison(12.4)), "+12\(space)% de volume")
        XCTAssertEqual(HistoryView.change(comparison(-8.6)), "−9\(space)% de volume")
        XCTAssertEqual(HistoryView.change(comparison(0.2)), "Volume stable")
        XCTAssertEqual(HistoryView.change(comparison(nil)), "Rien à comparer")
        XCTAssertEqual(
            HistoryView.previousDetail(comparison(100, now: 2_000_000, before: 1_000_000)),
            "2,0\(space)Mo sur cette période, 1,0\(space)Mo sur la précédente."
        )
        XCTAssertEqual(HistoryView.previousDetail(comparison(nil)), "La période précédente n’a pas de mesure.")
    }

    func testDeletingAUsedProfileSaysWhatChanges() {
        XCTAssertEqual(
            ProfilesView.warning(for: ProfileUsage(ruleNames: ["Nuit"], deviceNames: [])),
            "La règle Nuit le choisit : elle ne changera plus de profil."
        )
        XCTAssertEqual(
            ProfilesView.warning(for: ProfileUsage(ruleNames: ["Nuit", "Forfait"], deviceNames: ["MacBook"])),
            "Les règles Nuit, Forfait le choisissent : elles ne changeront plus de profil. L’appareil MacBook n’aura plus de profil."
        )
        XCTAssertTrue(ProfileUsage().isEmpty)
    }

    func testEveryDeviceKindHasANameAndASymbol() {
        for kind in DeviceKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.symbol.isEmpty)
        }
    }

    func testSpeedTestAddresses() {
        let base = URL(string: "https://speed.cloudflare.com/")!
        XCTAssertEqual(
            SpeedTestRunner.endpoint(base, "__down?bytes=50000000")?.absoluteString,
            "https://speed.cloudflare.com/__down?bytes=50000000"
        )
        XCTAssertEqual(SpeedTestRunner.endpoint(base, "__up")?.absoluteString, "https://speed.cloudflare.com/__up")
    }

    func testRadioGenerations() {
        XCTAssertEqual(RadioTechnology.generation(of: CTRadioAccessTechnologyNR), "5G")
        XCTAssertEqual(RadioTechnology.generation(of: CTRadioAccessTechnologyNRNSA), "5G")
        XCTAssertEqual(RadioTechnology.generation(of: CTRadioAccessTechnologyLTE), "4G")
        XCTAssertEqual(RadioTechnology.generation(of: CTRadioAccessTechnologyEdge), "2G")
        XCTAssertNil(RadioTechnology.generation(of: "inconnue"))
    }

    func testEveryEngineValueHasAFrenchName() {
        for kind in NetworkKind.allCases { XCTAssertFalse(kind.title.isEmpty) }
        for status in ApplyStatus.allCases { XCTAssertFalse(status.title.isEmpty) }
        for mode in LimitMode.allCases { XCTAssertFalse(mode.title.isEmpty) }
        for capability in Capability.allCases { XCTAssertFalse(capability.title.isEmpty) }
        // Seul un statut confirmé par le système s'appelle « Appliqué ».
        XCTAssertEqual(ApplyStatus.simulated.title, "Simulé")
        XCTAssertEqual(ApplyStatus.unsupported.title, "Réservé à iOS")
    }

    func testTheLatencyProbeAnswersOrGivesUp() async {
        // Un hôte qui n'existe pas : la sonde renvoie « pas de réponse », sans rester bloquée.
        let started = Date()
        let result = await LatencyProbe.measure(host: "hote-inexistant.invalid", timeout: 2)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }
}

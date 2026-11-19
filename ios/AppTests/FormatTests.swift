import CoreTelephony
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
        XCTAssertEqual(SettingsView.probeCadence(15), "toutes les 15 s (économie d’énergie)")
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

import XCTest

@testable import FluxaCore

/// Le 1er mars 2026 est un dimanche : `weekday` 1 dans `Calendar`.
final class AutomationTests: XCTestCase {
    private let midnight = noon.addingTimeInterval(-12 * hour)

    /// Place l'horloge à une heure donnée, `day` jours après le 1er mars.
    private func go(_ bench: Bench, day dayIndex: Int = 0, _ h: Int, _ m: Int, _ s: Int = 0) {
        bench.clock.date = midnight.addingTimeInterval(
            Double(dayIndex) * day + Double(h) * hour + Double(m) * minute + Double(s))
    }

    private func schedule(
        _ name: String = "Nuit", from start: Int, to end: Int, weekdays: Set<Int> = [],
        profile: String? = "economy"
    ) -> AutomationRule {
        AutomationRule(
            name: name,
            trigger: .schedule(startMinute: start, endMinute: end, weekdays: weekdays),
            action: profile.map { .activateProfile(id: $0) } ?? .alert)
    }

    private func messages(_ events: [AutomationEvent]) -> [String] { events.map(\.message) }

    // MARK: Règles

    func testRulesKeepTheirOrderAndIdentifiersAreNeverReused() throws {
        let engine = Bench().engine
        XCTAssertTrue(engine.automationRules.isEmpty)
        let first = try engine.saveRule(schedule("  Nuit \n", from: 1_320, to: 420))
        XCTAssertEqual(first.id, "rule-1")
        XCTAssertEqual(first.name, "Nuit", "le nom est nettoyé")
        XCTAssertTrue(first.isEnabled)
        let second = try engine.saveRule(
            AutomationRule(name: "Seuil", trigger: .dailyUsage(bytes: 1_000), action: .alert))
        XCTAssertEqual(second.id, "rule-2")

        // Remplacer une règle la laisse à sa place.
        var renamed = first
        renamed.name = "Soir"
        renamed.isEnabled = false
        XCTAssertEqual(try engine.saveRule(renamed), renamed)
        XCTAssertEqual(engine.automationRules.map(\.id), ["rule-1", "rule-2"])
        XCTAssertEqual(engine.automationRules.first, renamed)

        try engine.deleteRule(id: "rule-2")
        XCTAssertEqual(try engine.saveRule(schedule(from: 0, to: 60)).id, "rule-3")
        XCTAssertEqual(engine.automationRules.map(\.id), ["rule-1", "rule-3"])
    }

    func testRefusesInvalidRules() {
        let engine = Bench().engine
        let refused: [(AutomationRule, String)] = [
            (schedule("  \n", from: 0, to: 60), "Donnez un nom à la règle."),
            (
                AutomationRule(name: "Seuil", trigger: .dailyUsage(bytes: 0), action: .alert),
                "Le seuil de volume doit être supérieur à zéro."
            ),
            (schedule(from: -1, to: 60), "Les heures de la plage doivent être comprises entre 00:00 et 23:59."),
            (schedule(from: 0, to: 1_440), "Les heures de la plage doivent être comprises entre 00:00 et 23:59."),
            (schedule(from: 600, to: 600), "Le début et la fin de la plage doivent être différents."),
            (schedule(from: 0, to: 60, weekdays: [0, 3]), "Les jours de la semaine vont de 1 (dimanche) à 7 (samedi)."),
            (schedule(from: 0, to: 60, weekdays: [8]), "Les jours de la semaine vont de 1 (dimanche) à 7 (samedi)."),
        ]
        for (rule, reason) in refused {
            XCTAssertThrows(try engine.saveRule(rule), .invalidRule(reason))
            XCTAssertEqual(FluxaError.invalidRule(reason).localizedDescription, reason)
        }
        XCTAssertThrows(
            try engine.saveRule(schedule(from: 0, to: 60, profile: "absent")), .unknownProfile(id: "absent"))
        var ghost = schedule(from: 0, to: 60)
        ghost.id = "rule-9"
        XCTAssertThrows(try engine.saveRule(ghost), .invalidRule("Cette règle n’existe plus."))
        XCTAssertThrows(try engine.deleteRule(id: "rule-9"), .invalidRule("Cette règle n’existe plus."))
        XCTAssertTrue(engine.automationRules.isEmpty, "rien n'a été créé")
        // Les bornes sont acceptées : toute la journée moins une minute, tous les jours.
        XCTAssertNoThrow(try engine.saveRule(schedule(from: 0, to: 1_439, weekdays: [1, 2, 3, 4, 5, 6, 7])))
        XCTAssertEqual(engine.automationRules.first?.id, "rule-1", "un refus ne consomme pas d'identifiant")
    }

    // MARK: Seuil de volume

    func testAVolumeThresholdAlertsOncePerDay() throws {
        let bench = Bench().started()
        let rule = try bench.engine.saveRule(
            AutomationRule(name: "Dix mégas", trigger: .dailyUsage(bytes: 10_000_000), action: .alert))

        bench.measure(seconds: 7, down: 8, up: 2)  // 7 × 1,25 Mo : 8,75 Mo
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty)
        bench.measure(seconds: 1, down: 8, up: 2)  // 10 Mo, reçu et envoyé confondus
        let events = bench.engine.evaluateAutomations()
        XCTAssertEqual(messages(events), ["Seuil de 10 Mo atteint."])
        XCTAssertEqual(events.first?.kind, .started)
        XCTAssertEqual(events.first?.ruleID, rule.id)
        XCTAssertEqual(events.first?.ruleName, "Dix mégas")
        XCTAssertEqual(events.first?.date, bench.clock.date)
        XCTAssertNil(bench.engine.activeProfileID, "une alerte ne change rien")

        bench.measure(seconds: 30, down: 8, up: 2)
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty, "une seule fois par journée")

        // Le lendemain : pas d'événement de fin pour une alerte, et le seuil se réarme.
        go(bench, day: 1, 0, 0, 5)
        bench.rebase()
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty)
        bench.measure(seconds: 8, down: 8, up: 2)
        XCTAssertEqual(messages(bench.engine.evaluateAutomations()), ["Seuil de 10 Mo atteint."])
        XCTAssertEqual(bench.engine.automationLog(limit: 10).map(\.kind), [.started, .started])
    }

    func testAVolumeThresholdChoosesAProfileUntilTheNextDay() throws {
        let bench = Bench(counterWidth: .bits64).started()
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(
            AutomationRule(
                name: "Forfait", trigger: .dailyUsage(bytes: 2_000_000_000),
                action: .activateProfile(id: "economy")))

        bench.measure(seconds: 15, down: 1_000, up: 0)  // 1,875 Go
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty)
        bench.measure(seconds: 1, down: 1_000, up: 0)  // 2 Go
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Seuil de 2 Go atteint : profil Économie choisi."])
        XCTAssertEqual(bench.engine.activeProfileID, "economy")
        XCTAssertEqual(bench.engine.lastApplyResult?.status, .simulated, "le même chemin qu'un choix manuel")
        XCTAssertNil(bench.engine.lastApplyResult?.effective)
        XCTAssertEqual(bench.engine.lastApplyResult?.requested.downloadBps, 1_000_000)
        XCTAssertEqual(bench.engine.policyLog(limit: 10).count, 2)

        go(bench, 23, 59, 59)
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty)
        go(bench, day: 1, 0, 0)
        let events = bench.engine.evaluateAutomations()
        XCTAssertEqual(messages(events), ["Nouvelle journée : retour au profil Standard."])
        XCTAssertEqual(events.first?.kind, .ended)
        XCTAssertEqual(bench.engine.activeProfileID, "standard")
        XCTAssertEqual(bench.engine.lastApplyResult?.requested.downloadBps, 15_000_000)
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty, "le compteur du jour est reparti de zéro")
    }

    func testAThresholdAlreadyReachedFiresWhenTheRuleIsCreated() throws {
        let bench = Bench().started()
        bench.measure(seconds: 10, down: 8, up: 0)
        try bench.engine.saveRule(
            AutomationRule(name: "Seuil", trigger: .dailyUsage(bytes: 5_000_000), action: .alert))
        XCTAssertEqual(messages(bench.engine.evaluateAutomations()), ["Seuil de 5 Mo atteint."])
    }

    // MARK: Plage horaire

    func testAScheduleChoosesAProfileAndGivesItBack() throws {
        let bench = Bench()
        try bench.engine.saveRule(schedule("Sieste", from: 780, to: 840))  // 13:00–14:00

        go(bench, 12, 59, 59)
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty)
        go(bench, 13, 0)
        let started = bench.engine.evaluateAutomations()
        XCTAssertEqual(messages(started), ["Plage 13:00–14:00 commencée : profil Économie choisi."])
        XCTAssertEqual(started.first?.kind, .started)
        XCTAssertEqual(bench.engine.activeProfileID, "economy")
        XCTAssertEqual(bench.engine.lastApplyResult?.status, .simulated)

        go(bench, 13, 59, 59)
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty, "pas de redéclenchement pendant la plage")
        go(bench, 14, 0)
        // Aucun profil n'était choisi avant la plage : il n'y en a plus après.
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()),
            ["Plage 13:00–14:00 terminée : plus aucun profil choisi."])
        XCTAssertNil(bench.engine.activeProfileID)
        XCTAssertNil(bench.engine.lastApplyResult)
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty)

        // La plage revient le lendemain.
        go(bench, day: 1, 13, 30)
        XCTAssertEqual(bench.engine.evaluateAutomations().map(\.kind), [.started])
    }

    func testAScheduleGivesBackTheManualLimitThatWasInForce() throws {
        let bench = Bench()
        let manual = try bench.engine.apply(BandwidthPolicy(downloadBps: 12_000_000, uploadBps: 3_000_000))
        try bench.engine.saveRule(schedule(from: 780, to: 840))
        go(bench, 13, 0)
        bench.engine.evaluateAutomations()
        XCTAssertEqual(bench.engine.activeProfileID, "economy")
        go(bench, 14, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()),
            ["Plage 13:00–14:00 terminée : retour à la limite précédente."])
        XCTAssertNil(bench.engine.activeProfileID)
        XCTAssertEqual(bench.engine.lastApplyResult, manual)
    }

    func testATimedManualLimitThatExpiredDuringTheRangeDoesNotComeBack() throws {
        let bench = Bench()
        go(bench, 12, 50)
        try bench.engine.apply(BandwidthPolicy(downloadBps: 12_000_000, durationSeconds: 1_800))
        try bench.engine.saveRule(schedule(from: 780, to: 840))
        go(bench, 13, 0)
        bench.engine.evaluateAutomations()
        go(bench, 14, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()),
            ["Plage 13:00–14:00 terminée : plus aucun profil choisi."])
        XCTAssertNil(bench.engine.lastApplyResult)
    }

    func testAScheduleThatCrossesMidnight() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule(from: 1_320, to: 420))  // 22:00–07:00

        go(bench, 21, 59)
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty)
        go(bench, 22, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Plage 22:00–07:00 commencée : profil Économie choisi."])
        for (dayIndex, h, m) in [(0, 23, 59), (1, 0, 0), (1, 0, 30), (1, 6, 59)] {
            go(bench, day: dayIndex, h, m)
            XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty, "\(dayIndex) \(h):\(m)")
            XCTAssertEqual(bench.engine.activeProfileID, "economy")
        }
        go(bench, day: 1, 7, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Plage 22:00–07:00 terminée : retour au profil Standard."])
        XCTAssertEqual(bench.engine.activeProfileID, "standard")
        XCTAssertEqual(bench.engine.lastApplyResult?.requested.downloadBps, 15_000_000)
        XCTAssertEqual(bench.engine.lastApplyResult?.date, bench.clock.date, "une nouvelle demande, datée")
    }

    func testWeekdaysNameTheDayTheRangeBegins() throws {
        // Dimanche soir seulement.
        let sunday = Bench()
        try sunday.engine.saveRule(schedule(from: 1_320, to: 420, weekdays: [1]))
        go(sunday, 22, 30)
        XCTAssertEqual(sunday.engine.evaluateAutomations().map(\.kind), [.started])
        go(sunday, day: 1, 6, 0)
        XCTAssertTrue(sunday.engine.evaluateAutomations().isEmpty, "lundi matin : la plage de dimanche court encore")
        go(sunday, day: 1, 7, 0)
        XCTAssertEqual(sunday.engine.evaluateAutomations().map(\.kind), [.ended])
        go(sunday, day: 1, 22, 30)
        XCTAssertTrue(sunday.engine.evaluateAutomations().isEmpty, "lundi soir : pas de plage")
        go(sunday, day: 2, 3, 0)
        XCTAssertTrue(sunday.engine.evaluateAutomations().isEmpty, "mardi matin non plus")
        go(sunday, day: 7, 23, 0)
        XCTAssertEqual(sunday.engine.evaluateAutomations().map(\.kind), [.started], "le dimanche suivant")

        // Lundi soir seulement.
        let monday = Bench()
        try monday.engine.saveRule(schedule(from: 1_320, to: 420, weekdays: [2]))
        go(monday, 23, 0)
        XCTAssertTrue(monday.engine.evaluateAutomations().isEmpty, "dimanche soir")
        go(monday, day: 1, 1, 0)
        XCTAssertTrue(monday.engine.evaluateAutomations().isEmpty, "lundi 1 h appartient à la nuit de dimanche")
        go(monday, day: 1, 22, 0)
        XCTAssertEqual(monday.engine.evaluateAutomations().map(\.kind), [.started])
        go(monday, day: 2, 6, 59)
        XCTAssertTrue(monday.engine.evaluateAutomations().isEmpty)

        // Une plage de journée, en semaine seulement (lundi à vendredi).
        let office = Bench()
        try office.engine.saveRule(schedule(from: 540, to: 1_080, weekdays: [2, 3, 4, 5, 6]))
        go(office, 10, 0)
        XCTAssertTrue(office.engine.evaluateAutomations().isEmpty, "dimanche")
        go(office, day: 1, 10, 0)
        XCTAssertEqual(office.engine.evaluateAutomations().map(\.kind), [.started], "lundi")
        go(office, day: 6, 10, 0)
        XCTAssertEqual(office.engine.evaluateAutomations().map(\.kind), [.ended], "samedi : seule la fin de vendredi")
    }

    func testStartingInTheMiddleOfARange() throws {
        let store = MemoryStore()
        let clock = TestClock()
        let first = Bench(store: store, clock: clock)
        try first.engine.activateProfile(id: "standard")
        try first.engine.saveRule(schedule(from: 1_320, to: 420))
        try first.engine.flush()

        // L'app est relancée à 2 h du matin, en pleine plage.
        clock.date = midnight.addingTimeInterval(day + 2 * hour)
        let reopened = FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
        XCTAssertEqual(reopened.activeProfileID, "standard", "rien ne bouge avant l'évaluation")
        XCTAssertEqual(
            messages(reopened.evaluateAutomations()), ["Plage 22:00–07:00 commencée : profil Économie choisi."])
        clock.date = midnight.addingTimeInterval(day + 7 * hour)
        XCTAssertEqual(
            messages(reopened.evaluateAutomations()), ["Plage 22:00–07:00 terminée : retour au profil Standard."])
    }

    func testAMissedRangeEndsAndTheNextOneStartsInTheSameEvaluation() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule(from: 780, to: 840))
        go(bench, 13, 30)
        bench.engine.evaluateAutomations()
        // L'app reste fermée trois jours et rouvre en pleine plage.
        go(bench, day: 3, 13, 10)
        let events = bench.engine.evaluateAutomations()
        XCTAssertEqual(events.map(\.kind), [.ended, .started])
        XCTAssertEqual(bench.engine.activeProfileID, "economy")
        go(bench, day: 3, 14, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Plage 13:00–14:00 terminée : retour au profil Standard."])
    }

    func testAScheduleThatOnlyAlerts() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule("Heures pleines", from: 780, to: 840, profile: nil))
        go(bench, 13, 0)
        XCTAssertEqual(messages(bench.engine.evaluateAutomations()), ["Plage 13:00–14:00 commencée."])
        go(bench, 14, 0)
        XCTAssertEqual(messages(bench.engine.evaluateAutomations()), ["Plage 13:00–14:00 terminée."])
        XCTAssertEqual(bench.engine.activeProfileID, "standard")
        XCTAssertEqual(bench.engine.policyLog(limit: 10).count, 1, "aucune demande de limite")
    }

    // MARK: Règle changée en cours d'effet

    func testDisablingAnActiveRuleGivesTheProfileBackOnce() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        var rule = try bench.engine.saveRule(schedule(from: 780, to: 840))
        go(bench, 13, 10)
        bench.engine.evaluateAutomations()
        XCTAssertEqual(bench.engine.activeProfileID, "economy")

        rule.isEnabled = false
        go(bench, 13, 20)
        try bench.engine.saveRule(rule)
        XCTAssertEqual(bench.engine.activeProfileID, "standard", "rendu tout de suite")
        XCTAssertEqual(
            bench.engine.automationLog(limit: 1).map(\.message), ["Règle désactivée : retour au profil Standard."])
        XCTAssertEqual(bench.engine.automationLog(limit: 1).first?.kind, .ended)

        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty, "désactivée : plus rien")
        go(bench, 14, 0)
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty, "pas de seconde fin")
        XCTAssertEqual(bench.engine.automationLog(limit: 10).map(\.kind), [.ended, .started])

        // Réactivée en pleine plage, le lendemain : elle reprend.
        rule.isEnabled = true
        go(bench, day: 1, 13, 30)
        try bench.engine.saveRule(rule)
        XCTAssertEqual(bench.engine.evaluateAutomations().map(\.kind), [.started])
    }

    func testDeletingAnActiveRuleGivesTheProfileBack() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        let rule = try bench.engine.saveRule(schedule(from: 780, to: 840))
        go(bench, 13, 10)
        bench.engine.evaluateAutomations()
        try bench.engine.deleteRule(id: rule.id)
        XCTAssertEqual(bench.engine.activeProfileID, "standard")
        XCTAssertTrue(bench.engine.automationRules.isEmpty)
        XCTAssertEqual(
            bench.engine.automationLog(limit: 1).map(\.message), ["Règle supprimée : retour au profil Standard."])
        go(bench, 14, 0)
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty)
    }

    func testModifyingAnActiveRuleRestartsItCleanly() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        var rule = try bench.engine.saveRule(schedule(from: 780, to: 840))
        go(bench, 13, 10)
        bench.engine.evaluateAutomations()

        // Seul le nom change : la règle continue, sans événement.
        rule.name = "Déjeuner"
        try bench.engine.saveRule(rule)
        XCTAssertEqual(bench.engine.activeProfileID, "economy")
        XCTAssertEqual(bench.engine.automationLog(limit: 10).count, 1)

        // L'action change : l'ancien effet est retiré, puis la règle se redéclenche.
        rule.action = .activateProfile(id: "browsing")
        try bench.engine.saveRule(rule)
        XCTAssertEqual(bench.engine.activeProfileID, "standard")
        XCTAssertEqual(
            bench.engine.automationLog(limit: 1).map(\.message), ["Règle modifiée : retour au profil Standard."])
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Plage 13:00–14:00 commencée : profil Navigation choisi."])

        // La plage change et ne contient plus l'heure courante.
        rule.trigger = .schedule(startMinute: 900, endMinute: 960, weekdays: [])
        try bench.engine.saveRule(rule)
        XCTAssertEqual(bench.engine.activeProfileID, "standard")
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty)
        go(bench, 14, 0)
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty, "l'ancienne fin ne produit rien")
        XCTAssertEqual(bench.engine.automationLog(limit: 1).first?.ruleName, "Déjeuner")
    }

    func testDisablingARuleThatOnlyAlertsLeavesNoTrace() throws {
        let bench = Bench()
        var rule = try bench.engine.saveRule(schedule(from: 780, to: 840, profile: nil))
        go(bench, 13, 10)
        bench.engine.evaluateAutomations()
        rule.isEnabled = false
        try bench.engine.saveRule(rule)
        XCTAssertEqual(bench.engine.automationLog(limit: 10).map(\.kind), [.started])
    }

    // MARK: Choix de l'utilisateur

    func testAManualChoiceDuringARuleIsKept() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule(from: 780, to: 840))
        go(bench, 13, 0)
        bench.engine.evaluateAutomations()

        go(bench, 13, 30)
        try bench.engine.activateProfile(id: "streaming")
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty, "la règle ne reprend pas la main")
        XCTAssertEqual(bench.engine.activeProfileID, "streaming")
        go(bench, 14, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()),
            ["Plage 13:00–14:00 terminée : votre choix de profil est conservé."])
        XCTAssertEqual(bench.engine.activeProfileID, "streaming")
    }

    func testAManualLimitDuringARuleIsKept() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule(from: 780, to: 840))
        go(bench, 13, 0)
        bench.engine.evaluateAutomations()
        let manual = try bench.engine.apply(BandwidthPolicy(downloadBps: 3_000_000))
        go(bench, 14, 0)
        XCTAssertEqual(bench.engine.evaluateAutomations().map(\.kind), [.ended])
        XCTAssertNil(bench.engine.activeProfileID)
        XCTAssertEqual(bench.engine.lastApplyResult, manual)
    }

    func testARuleWhoseProfileIsAlreadyChosenChangesNothing() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "economy")
        try bench.engine.saveRule(schedule(from: 780, to: 840))
        go(bench, 13, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Plage 13:00–14:00 commencée : profil Économie choisi."])
        go(bench, 14, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()),
            ["Plage 13:00–14:00 terminée : le profil Économie reste choisi."])
        XCTAssertEqual(bench.engine.activeProfileID, "economy")
        XCTAssertEqual(bench.engine.policyLog(limit: 10).count, 1, "aucune demande redondante")
    }

    func testARuleWhoseProfileWasDeletedSaysSo() throws {
        let bench = Bench()
        let custom = try bench.engine.saveProfile(id: nil, name: "Visio", downloadMbps: 8, uploadMbps: 4)
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule(from: 780, to: 840, profile: custom.id))
        try bench.engine.deleteProfile(id: custom.id)
        go(bench, 13, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()),
            ["Plage 13:00–14:00 commencée : le profil de la règle n’existe plus, rien n’est changé."])
        XCTAssertEqual(bench.engine.activeProfileID, "standard")
        go(bench, 14, 0)
        XCTAssertEqual(messages(bench.engine.evaluateAutomations()), ["Plage 13:00–14:00 terminée."])
    }

    func testThePreviousProfileDeletedDuringARule() throws {
        let bench = Bench()
        let custom = try bench.engine.saveProfile(id: nil, name: "Visio", downloadMbps: 8, uploadMbps: 4)
        try bench.engine.activateProfile(id: custom.id)
        try bench.engine.saveRule(schedule(from: 780, to: 840))
        go(bench, 13, 0)
        bench.engine.evaluateAutomations()
        try bench.engine.deleteProfile(id: custom.id)
        go(bench, 14, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()),
            ["Plage 13:00–14:00 terminée : plus aucun profil choisi."])
        XCTAssertNil(bench.engine.activeProfileID)
    }

    // MARK: Deux règles

    func testTheLastTriggeredRuleWinsAndEndsFirst() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule("Longue", from: 780, to: 900))  // 13:00–15:00
        try bench.engine.saveRule(schedule("Courte", from: 840, to: 870, profile: "streaming"))  // 14:00–14:30
        go(bench, 13, 0)
        bench.engine.evaluateAutomations()
        XCTAssertEqual(bench.engine.activeProfileID, "economy")
        go(bench, 14, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Plage 14:00–14:30 commencée : profil Streaming choisi."])
        XCTAssertEqual(bench.engine.activeProfileID, "streaming")
        go(bench, 14, 30)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Plage 14:00–14:30 terminée : retour au profil Économie."])
        go(bench, 15, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Plage 13:00–15:00 terminée : retour au profil Standard."])
        XCTAssertEqual(bench.engine.activeProfileID, "standard")
    }

    func testWhenTheFirstRuleEndsFirstTheSecondReturnsToTheStateBeforeBoth() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule("Première", from: 780, to: 870))  // 13:00–14:30
        try bench.engine.saveRule(schedule("Seconde", from: 840, to: 900, profile: "streaming"))  // 14:00–15:00
        go(bench, 13, 0)
        bench.engine.evaluateAutomations()
        go(bench, 14, 0)
        bench.engine.evaluateAutomations()
        go(bench, 14, 30)
        // La première se termine : le profil de la seconde reste en place.
        XCTAssertEqual(messages(bench.engine.evaluateAutomations()), ["Plage 13:00–14:30 terminée."])
        XCTAssertEqual(bench.engine.activeProfileID, "streaming")
        go(bench, 15, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Plage 14:00–15:00 terminée : retour au profil Standard."],
            "pas au profil de la première règle, terminée entre-temps")
        XCTAssertEqual(bench.engine.activeProfileID, "standard")
    }

    func testTwoRulesWithTheSameProfile() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule("A", from: 780, to: 870))
        try bench.engine.saveRule(schedule("B", from: 840, to: 900))
        go(bench, 14, 10)
        XCTAssertEqual(bench.engine.evaluateAutomations().map(\.ruleName), ["A", "B"])
        go(bench, 14, 30)
        XCTAssertEqual(messages(bench.engine.evaluateAutomations()), ["Plage 13:00–14:30 terminée."])
        XCTAssertEqual(bench.engine.activeProfileID, "economy", "B tient encore le profil")
        go(bench, 15, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Plage 14:00–15:00 terminée : retour au profil Standard."])
    }

    func testTwoRulesEndingTogetherReturnStraightToTheStateBefore() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule("A", from: 780, to: 900))
        try bench.engine.saveRule(schedule("B", from: 840, to: 900, profile: "streaming"))
        go(bench, 13, 0)
        bench.engine.evaluateAutomations()
        go(bench, 14, 0)
        bench.engine.evaluateAutomations()
        let requests = bench.engine.policyLog(limit: 50).count
        go(bench, 15, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()),
            ["Plage 13:00–15:00 terminée.", "Plage 14:00–15:00 terminée : retour au profil Standard."])
        XCTAssertEqual(bench.engine.policyLog(limit: 50).count, requests + 1, "un seul retour, sans passer par Économie")
    }

    // MARK: Journal

    func testEvaluationReturnsOnlyNewEventsAndTheLogIsBounded() throws {
        let bench = Bench()
        try bench.engine.saveRule(schedule(from: 780, to: 840, profile: nil))
        go(bench, 13, 0)
        let first = bench.engine.evaluateAutomations()
        go(bench, 14, 0)
        let second = bench.engine.evaluateAutomations()
        XCTAssertEqual(first.map(\.id), [1])
        XCTAssertEqual(second.map(\.id), [2])
        XCTAssertEqual(bench.engine.automationLog(limit: 10).map(\.id), [2, 1], "du plus récent au plus ancien")
        XCTAssertEqual(bench.engine.automationLog(limit: 1).map(\.id), [2])
        XCTAssertTrue(bench.engine.automationLog(limit: 0).isEmpty)
        XCTAssertTrue(bench.engine.automationLog(limit: -1).isEmpty)

        for dayIndex in 1...110 {
            go(bench, day: dayIndex, 13, 0)
            bench.engine.evaluateAutomations()
            go(bench, day: dayIndex, 14, 0)
            bench.engine.evaluateAutomations()
        }
        let log = bench.engine.automationLog(limit: 1_000)
        XCTAssertEqual(log.count, FluxaEngine.automationLogCapacity)
        XCTAssertEqual(log.first?.id, 222)
        XCTAssertEqual(log.last?.id, 23)
        XCTAssertTrue(
            bench.engine.diagnostics().events.contains { $0.message.hasPrefix("Règle « Nuit » : Plage") },
            "les événements des règles figurent aussi au diagnostic")
    }

    // MARK: Persistance

    func testRulesTheirEffectAndTheLogSurviveARestart() throws {
        let store = MemoryStore()
        let clock = TestClock()
        let bench = Bench(store: store, clock: clock)
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule(from: 1_320, to: 420))
        try bench.engine.saveRule(
            AutomationRule(name: "Seuil", isEnabled: false, trigger: .dailyUsage(bytes: 5), action: .alert))
        go(bench, 22, 0)
        bench.engine.evaluateAutomations()  // enregistre de lui-même

        clock.date = midnight.addingTimeInterval(day + 3 * hour)
        let reopened = FluxaEngine(store: store, calendar: calendar(), now: { clock.date })
        XCTAssertEqual(reopened.automationRules, bench.engine.automationRules)
        XCTAssertEqual(reopened.automationRules.map(\.isEnabled), [true, false])
        XCTAssertEqual(reopened.automationLog(limit: 10), bench.engine.automationLog(limit: 10))
        XCTAssertEqual(reopened.activeProfileID, "economy")
        XCTAssertTrue(reopened.evaluateAutomations().isEmpty, "la plage en cours ne se redéclenche pas")

        clock.date = midnight.addingTimeInterval(day + 7 * hour)
        let events = reopened.evaluateAutomations()
        XCTAssertEqual(messages(events), ["Plage 22:00–07:00 terminée : retour au profil Standard."])
        XCTAssertEqual(events.first?.id, 2, "la numérotation continue")
        XCTAssertEqual(reopened.activeProfileID, "standard")
        XCTAssertEqual(try reopened.saveRule(schedule(from: 0, to: 60)).id, "rule-3")
    }

    func testTheFileStoreKeepsRulesAndSpeedTests() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = TestClock()
        let bench = Bench(store: FileStore(url: url), clock: clock)
        try bench.engine.saveRule(schedule(from: 780, to: 840, weekdays: [2, 4]))
        try bench.engine.saveRule(
            AutomationRule(name: "Seuil", trigger: .dailyUsage(bytes: 2_000_000_000), action: .alert))
        bench.engine.recordSpeedTest(speedTest(at: noon, mbps: 42.8))
        go(bench, day: 1, 13, 0)
        bench.engine.evaluateAutomations()

        let reopened = FluxaEngine(store: FileStore(url: url), calendar: calendar(), now: { clock.date })
        XCTAssertEqual(reopened.automationRules, bench.engine.automationRules)
        XCTAssertEqual(reopened.automationLog(limit: 5), bench.engine.automationLog(limit: 5))
        XCTAssertEqual(reopened.speedTests, bench.engine.speedTests)
        XCTAssertEqual(reopened.activeProfileID, "economy")
    }

    func testAStateSavedBeforeAutomationsStillLoads() throws {
        // Un fichier écrit par la version précédente : ni règles, ni journal, ni tests.
        let old = Data(
            #"""
            {"version":1,"activeProfileID":"standard","nextProfileNumber":2,"policyLog":[],
             "profiles":[{"id":"custom-1","name":"Visio","downloadBps":8000000,"isBuiltin":false}],
             "minutes":[],"hours":[],"days":[]}
            """#.utf8)
        let state = try JSONDecoder().decode(EngineState.self, from: old)
        XCTAssertEqual(state.rules, [])
        XCTAssertEqual(state.activations, [])
        XCTAssertEqual(state.automationLog, [])
        XCTAssertEqual(state.speedTests, [])
        XCTAssertEqual(state.nextRuleNumber, 1)
        XCTAssertEqual(state.nextAutomationEventID, 1)

        let store = MemoryStore()
        try store.save(state)
        let engine = FluxaEngine(store: store, calendar: calendar(), now: { noon })
        XCTAssertEqual(engine.activeProfileID, "standard")
        XCTAssertEqual(engine.profiles.count, 8)
        XCTAssertTrue(engine.automationRules.isEmpty)
        XCTAssertTrue(engine.evaluateAutomations().isEmpty)
        XCTAssertEqual(engine.diagnostics().events.map(\.level), [.info], "aucune erreur de lecture")
        XCTAssertEqual(try engine.saveRule(schedule(from: 0, to: 60)).id, "rule-1")

        // Et l'état d'aujourd'hui se relit tel quel.
        let saved = try XCTUnwrap(try store.load())
        let reloaded = try JSONDecoder().decode(EngineState.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded, saved)
        XCTAssertEqual(reloaded.rules.count, 1)
    }

    func testErasingTheHistoryKeepsRulesButEmptiesTheirLogAndTheSpeedTests() throws {
        let bench = Bench()
        try bench.engine.activateProfile(id: "standard")
        try bench.engine.saveRule(schedule(from: 780, to: 840))
        bench.engine.recordSpeedTest(speedTest(at: noon, mbps: 10))
        go(bench, 13, 0)
        bench.engine.evaluateAutomations()

        try bench.engine.eraseHistory()
        XCTAssertEqual(bench.engine.automationRules.count, 1)
        XCTAssertTrue(bench.engine.automationLog(limit: 10).isEmpty)
        XCTAssertTrue(bench.engine.speedTests.isEmpty)
        // La règle en cours garde son effet et rend bien le profil à la fin.
        XCTAssertEqual(bench.engine.activeProfileID, "economy")
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty)
        go(bench, 14, 0)
        XCTAssertEqual(
            messages(bench.engine.evaluateAutomations()), ["Plage 13:00–14:00 terminée : retour au profil Standard."])

        try bench.engine.eraseAll()
        XCTAssertTrue(bench.engine.automationRules.isEmpty)
        XCTAssertTrue(bench.engine.automationLog(limit: 10).isEmpty)
        XCTAssertTrue(bench.engine.evaluateAutomations().isEmpty)
        XCTAssertEqual(try bench.engine.saveRule(schedule(from: 0, to: 60)).id, "rule-1", "tout repart de un")
    }

    // MARK: Tests de débit

    private func speedTest(at date: Date, mbps: Double) -> SpeedTestResult {
        SpeedTestResult(
            date: date, downloadBps: mbps * 1_000_000, uploadBps: nil, latencyMs: 28, networkKind: .wifi,
            server: "test.example", downloadedBytes: 25_000_000, uploadedBytes: 0)
    }

    func testSpeedTestsAreKeptNewestFirstAndBoundedToFifty() throws {
        let store = MemoryStore()
        let bench = Bench(store: store)
        XCTAssertTrue(bench.engine.speedTests.isEmpty)
        // Soixante résultats, donnés dans le désordre.
        for index in (0..<60).map({ ($0 * 37) % 60 }) {
            bench.engine.recordSpeedTest(
                speedTest(at: noon.addingTimeInterval(Double(index) * minute), mbps: Double(index)))
        }
        let tests = bench.engine.speedTests
        XCTAssertEqual(tests.count, FluxaEngine.speedTestCapacity)
        XCTAssertEqual(tests.map(\.date), tests.map(\.date).sorted(by: >))
        XCTAssertEqual(tests.first?.downloadBps, 59_000_000)
        XCTAssertEqual(tests.last?.downloadBps, 10_000_000, "les dix plus anciens sont partis")
        XCTAssertNil(tests.first?.uploadBps, "une phase absente reste absente")

        // Un résultat plus ancien que tous les autres n'entre pas ; même date : remplacé.
        bench.engine.recordSpeedTest(speedTest(at: noon.addingTimeInterval(-hour), mbps: 1))
        XCTAssertEqual(bench.engine.speedTests.last?.downloadBps, 10_000_000)
        bench.engine.recordSpeedTest(speedTest(at: noon.addingTimeInterval(59 * minute), mbps: 77))
        XCTAssertEqual(bench.engine.speedTests.count, 50)
        XCTAssertEqual(bench.engine.speedTests.first?.downloadBps, 77_000_000)
        XCTAssertEqual(Set(bench.engine.speedTests.map(\.id)).count, 50, "identifiants uniques")

        // Enregistré sans attendre.
        let reopened = FluxaEngine(store: store, calendar: calendar(), now: { noon })
        XCTAssertEqual(reopened.speedTests, bench.engine.speedTests)
    }

    // MARK: Mise en forme

    func testVolumesAndRangesAreFormattedInFrench() {
        XCTAssertEqual(FluxaEngine.volume(2_000_000_000), "2 Go")
        XCTAssertEqual(FluxaEngine.volume(1_500_000_000), "1,5 Go")
        XCTAssertEqual(FluxaEngine.volume(1_250_000), "1,25 Mo")
        XCTAssertEqual(FluxaEngine.volume(500_000_000), "500 Mo")
        XCTAssertEqual(FluxaEngine.volume(999_999_999), "1 Go", "pas « 1000 Mo »")
        XCTAssertEqual(FluxaEngine.volume(64_000), "64 ko")
        XCTAssertEqual(FluxaEngine.volume(994), "994 o")
        XCTAssertEqual(FluxaEngine.volume(999), "1 ko", "arrondi à deux décimales, comme pour les Go")
        XCTAssertEqual(FluxaEngine.volume(0), "0 o")
        XCTAssertEqual(FluxaEngine.range(1_320, 420), "22:00–07:00")
        XCTAssertEqual(FluxaEngine.range(5, 1_439), "00:05–23:59")
    }
}

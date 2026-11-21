import XCTest

/// L'app, manipulée comme le ferait quelqu'un : chaque test la lance et vérifie un écran.
final class FluxaUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Lance l'app. L'accueil du premier lancement est passé, sauf si le test le demande.
    private func launch(_ arguments: [String] = [], welcome: Bool = false) {
        app.launchArguments = arguments + ["-hasSeenWelcome", welcome ? "NO" : "YES"]
        app.launch()
    }

    /// Le premier élément dont le libellé contient `text`.
    private func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    private func button(startingWith text: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text))
    }

    private func button(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Si un élément porte exactement ce libellé.
    private func hasElement(labelled text: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch.exists
    }

    /// Fait défiler la page jusqu'à ce que l'élément soit à l'écran.
    @discardableResult
    private func scroll(to element: XCUIElement, swipes: Int = 10) -> Bool {
        for _ in 0..<swipes {
            if isOnScreen(element) { return true }
            app.swipeUp(velocity: .slow)
        }
        return isOnScreen(element)
    }

    /// Visible et touchable : ni sous la barre de navigation, ni sous la barre d'onglets,
    /// qui flotte par-dessus le bas de la page.
    private func isOnScreen(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let screen = app.windows.firstMatch.frame
        let middle = element.frame.midY
        return middle > screen.minY + 110 && middle < screen.maxY - 130
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = NSPredicate(format: "exists == NO")
        let waiting = XCTNSPredicateExpectation(predicate: gone, object: element)
        return XCTWaiter().wait(for: [waiting], timeout: timeout) == .completed
    }

    /// Donne le clavier à un champ, en le touchant de nouveau si le premier geste n'a pas
    /// suffi (la feuille vient parfois de finir son animation).
    private func focus(_ field: XCUIElement) {
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        }
    }

    /// Allume un interrupteur, en touchant le bouton lui-même si la ligne ne suffit pas.
    private func turnOn(_ toggle: XCUIElement) {
        if (toggle.value as? String) == "1" { return }
        toggle.tap()
        if (toggle.value as? String) != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
    }

    /// Referme le clavier par le bouton de sa barre, s'il est affiché.
    private func closeKeyboard() {
        let done = app.buttons["Terminé"]
        if done.waitForExistence(timeout: 3) {
            done.tap()
        }
    }

    private func assertNoError(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            app.alerts["Action impossible"].waitForExistence(timeout: 2),
            "l'app a affiché une erreur",
            file: file,
            line: line
        )
    }

    // MARK: Premier lancement

    func testTheFirstLaunchExplainsTheAppBeforeAnythingElse() {
        launch(welcome: true)
        XCTAssertTrue(element(containing: "FLUXA mesure, et dit ce qui est réellement appliqué.").waitForExistence(timeout: 30))
        XCTAssertTrue(element(containing: "Ce qu’iOS garde pour lui").exists)
        XCTAssertTrue(element(containing: "Vos mesures restent sur l’iPhone").exists)
        app.buttons["Commencer"].tap()
        XCTAssertTrue(waitForDisappearance(of: element(containing: "Ce qu’iOS garde pour lui"), timeout: 10))
        XCTAssertTrue(app.navigationBars["Tableau de bord"].waitForExistence(timeout: 10))
    }

    // MARK: Tableau de bord

    func testTheDashboardMeasuresTheConnection() {
        launch()
        XCTAssertTrue(app.navigationBars["Tableau de bord"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Mesure active"].waitForExistence(timeout: 10))

        // Après quelques relevés, le débit est un nombre : plus de tiret.
        let throughput = app.descendants(matching: .any)["debit"]
        XCTAssertTrue(throughput.waitForExistence(timeout: 10))
        let measured = NSPredicate(format: "NOT (label CONTAINS %@)", "—")
        expectation(for: measured, evaluatedWith: throughput)
        waitForExpectations(timeout: 30)
        assertNoError()
    }

    func testTheDashboardStaysReadableWithLargeText() {
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        XCTAssertTrue(app.navigationBars["Tableau de bord"].waitForExistence(timeout: 30))
        let throughput = app.descendants(matching: .any)["debit"]
        XCTAssertTrue(throughput.waitForExistence(timeout: 10))
        // Les mesures, sur une colonne, restent atteignables en faisant défiler.
        XCTAssertTrue(scroll(to: element(containing: "Latence"), swipes: 12))
        XCTAssertTrue(scroll(to: element(containing: "Aujourd"), swipes: 12))
        assertNoError()
    }

    func testEveryTabOpens() {
        launch()
        XCTAssertTrue(app.navigationBars["Tableau de bord"].waitForExistence(timeout: 30))
        for (tab, title) in [
            ("Partage", "Partage"),
            ("Profils", "Profils"),
            ("Historique", "Historique"),
            ("Réglages", "Réglages"),
            ("Réseau", "Tableau de bord"),
        ] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "onglet \(tab)")
        }
        assertNoError()
    }

    func testMyNetworkListsThePathAndTheInterfaces() {
        launch(["-fluxaScreen", "reseau"])
        XCTAssertTrue(app.navigationBars["Mon réseau"].waitForExistence(timeout: 30))
        XCTAssertTrue(element(containing: "Internet").waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Joignable").waitForExistence(timeout: 15))
    }

    // MARK: Partage de connexion

    func testTheSharingGuideExplainsWhatIOSKeeps() {
        launch(["-fluxaTab", "partage"])
        XCTAssertTrue(app.navigationBars["Partage"].waitForExistence(timeout: 30))
        XCTAssertTrue(element(containing: "Le partage de connexion appartient à iOS").exists)
        XCTAssertTrue(scroll(to: button(startingWith: "Ouvrir").firstMatch))
        // Les capacités réservées au système sont listées avec leur statut.
        XCTAssertTrue(scroll(to: element(containing: "Activer le partage depuis une app")))
        XCTAssertTrue(element(containing: "Réservé à iOS").exists)
    }

    // MARK: Profils et limites

    func testChoosingAProfileIsReportedAsSimulated() {
        launch(["-fluxaTab", "profils"])
        XCTAssertTrue(app.navigationBars["Profils"].waitForExistence(timeout: 30))
        // Les sept préréglages sont là.
        for name in ["Économie", "Navigation", "Streaming", "Maximum"] {
            XCTAssertTrue(scroll(to: button(containing: name)), name)
        }
        app.swipeDown()
        app.swipeDown()
        let streaming = button(containing: "Streaming")
        XCTAssertTrue(scroll(to: streaming))
        streaming.tap()
        assertNoError()
        app.swipeDown()
        app.swipeDown()
        // Le statut affiché est « Simulé », jamais « Appliqué ».
        XCTAssertTrue(element(containing: "Simulé").waitForExistence(timeout: 5))
        XCTAssertFalse(hasElement(labelled: "Appliqué"))
    }

    func testANewProfileCanBeCreated() {
        launch(["-fluxaTab", "profils"])
        XCTAssertTrue(app.navigationBars["Profils"].waitForExistence(timeout: 30))
        app.navigationBars["Profils"].buttons["Nouveau profil"].tap()
        let name = app.textFields["Nom du profil"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        focus(name)
        name.typeText("Essai")
        app.navigationBars.buttons["Enregistrer"].tap()
        assertNoError()
        XCTAssertTrue(scroll(to: button(containing: "Essai")))
    }

    func testAProfileWithoutNameIsRefused() {
        launch(["-fluxaTab", "profils"])
        XCTAssertTrue(app.navigationBars["Profils"].waitForExistence(timeout: 30))
        app.navigationBars["Profils"].buttons["Nouveau profil"].tap()
        XCTAssertTrue(app.textFields["Nom du profil"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Enregistrer"].tap()
        // L'app explique le refus dans la feuille, et ne la referme pas.
        XCTAssertTrue(app.descendants(matching: .any)["erreur-profil"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Nom du profil"].exists)
        app.navigationBars.buttons["Annuler"].tap()
        assertNoError()
    }

    func testTheLimiterSimulatesOnTheMeasuredRate() {
        launch(["-fluxaScreen", "limiteur"])
        XCTAssertTrue(app.navigationBars["Limiteur de débit"].waitForExistence(timeout: 30))
        XCTAssertTrue(scroll(to: element(containing: "Effet simulé")))
        // Dès que le débit est mesuré, la simulation le reprend : le message d'attente part.
        XCTAssertTrue(waitForDisappearance(of: element(containing: "Pas encore de débit mesuré"), timeout: 30))
    }

    func testTheLimiterNeverClaimsToApply() {
        launch(["-fluxaScreen", "limiteur"])
        XCTAssertTrue(app.navigationBars["Limiteur de débit"].waitForExistence(timeout: 30))
        XCTAssertTrue(scroll(to: element(containing: "Réservé à iOS")))
        XCTAssertTrue(element(containing: "Simulé").exists)
        let save = app.buttons["Enregistrer la limite"]
        XCTAssertTrue(scroll(to: save))
        save.tap()
        assertNoError()
        // Après l'enregistrement, rien n'est annoncé comme appliqué.
        XCTAssertFalse(hasElement(labelled: "Appliqué"))
    }

    func testTheLimiterTriesTheSystemAndReportsItsAnswer() {
        launch(["-fluxaScreen", "limiteur"])
        XCTAssertTrue(app.navigationBars["Limiteur de débit"].waitForExistence(timeout: 30))
        let attempt = app.buttons["tenter-application"]
        XCTAssertTrue(scroll(to: attempt))
        attempt.tap()
        // Le module Rust répond, voie par voie, et le bilan ne prétend rien appliquer. Les
        // lignes ajoutées poussent le bilan plus bas : la liste ne le crée qu'à l'écran.
        XCTAssertTrue(element(containing: "Filtre de paquets").waitForExistence(timeout: 10))
        let summary = app.descendants(matching: .any)["bilan-tentative"]
        XCTAssertTrue(scroll(to: summary))
        XCTAssertTrue(summary.label.contains("Rien n’est appliqué") || summary.label.contains("rien n’est appliqué"), summary.label)
        XCTAssertFalse(hasElement(labelled: "Appliqué"))
        assertNoError()
    }

    // MARK: Appareils

    func testADeviceCanBeNoted() {
        launch(["-fluxaScreen", "appareils"])
        XCTAssertTrue(app.navigationBars["Mes appareils"].waitForExistence(timeout: 30))
        // L'app dit ce qu'iOS ne fournit pas, au lieu de l'inventer.
        XCTAssertTrue(element(containing: "Adresse MAC").exists)
        app.navigationBars["Mes appareils"].buttons["Nouvel appareil"].tap()
        let name = app.textFields["Nom de l’appareil"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        focus(name)
        name.typeText("MacBook")
        app.navigationBars.buttons["Enregistrer"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["erreur-appareil"].waitForExistence(timeout: 2))
        XCTAssertTrue(button(containing: "MacBook").waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "aucun profil").exists)
    }

    func testADeviceWithoutNameIsRefused() {
        launch(["-fluxaScreen", "appareils"])
        XCTAssertTrue(app.navigationBars["Mes appareils"].waitForExistence(timeout: 30))
        app.navigationBars["Mes appareils"].buttons["Nouvel appareil"].tap()
        XCTAssertTrue(app.textFields["Nom de l’appareil"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Enregistrer"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["erreur-appareil"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Annuler"].tap()
        assertNoError()
    }

    // MARK: Test de débit

    func testTheSpeedTestMeasuresBothDirections() {
        launch(["-fluxaScreen", "test", "-fluxaShortSpeedTest", "YES"])
        XCTAssertTrue(app.navigationBars["Test de débit"].waitForExistence(timeout: 30))
        let start = button(startingWith: "Lancer le test").firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        // Le bouton attend que le réseau soit reconnu.
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == YES"), object: start)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 15), .completed)
        start.tap()
        // Latence, téléchargement puis envoi. Le test s'achève sur un résultat ou sur un
        // message d'erreur : on attend l'un des deux, et seul le résultat est accepté.
        let done = app.descendants(matching: .any)["test-termine"]
        let failed = app.descendants(matching: .any)["erreur-test"]
        let ended = NSPredicate { _, _ in done.exists || failed.exists }
        let waiting = XCTNSPredicateExpectation(predicate: ended, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [waiting], timeout: 60), .completed, "le test ne s'est pas terminé")
        XCTAssertFalse(failed.exists, "le test a échoué : \(failed.exists ? failed.label : "")")
        XCTAssertTrue(done.exists)
        // Les deux sens ont un débit : plus aucun tiret dans les mesures.
        XCTAssertFalse(element(containing: "Descendant, —").exists)
        XCTAssertFalse(element(containing: "Montant, —").exists)
        // Le résultat rejoint les tests précédents.
        XCTAssertFalse(element(containing: "Aucun test pour l").exists)
    }

    // MARK: Automatisations

    func testARuleCanBeCreatedAndSwitchedOff() {
        launch(["-fluxaScreen", "automatisations"])
        XCTAssertTrue(app.navigationBars["Automatisations"].waitForExistence(timeout: 30))
        app.navigationBars["Automatisations"].buttons["Nouvelle règle"].tap()
        let name = app.textFields["Nom de la règle"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        focus(name)
        name.typeText("Forfait")
        app.navigationBars.buttons["Enregistrer"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["erreur-regle"].waitForExistence(timeout: 2))
        XCTAssertTrue(button(containing: "Forfait").waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "dans la journée : prévenir").exists)
        // La règle se coupe d'un geste.
        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Forfait")).firstMatch
        XCTAssertTrue(toggle.exists)
        toggle.tap()
        assertNoError()
    }

    func testARuleWithoutNameIsRefused() {
        launch(["-fluxaScreen", "automatisations"])
        XCTAssertTrue(app.navigationBars["Automatisations"].waitForExistence(timeout: 30))
        app.navigationBars["Automatisations"].buttons["Nouvelle règle"].tap()
        XCTAssertTrue(app.textFields["Nom de la règle"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Enregistrer"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["erreur-regle"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Annuler"].tap()
        assertNoError()
    }

    func testTheDashboardShowsTheSharingState() {
        launch()
        XCTAssertTrue(app.navigationBars["Tableau de bord"].waitForExistence(timeout: 30))
        // Dans le simulateur, aucun partage : l'app le dit sans rien inventer.
        XCTAssertTrue(scroll(to: app.descendants(matching: .any)["partage"]))
        XCTAssertTrue(element(containing: "Non détecté").exists)
    }

    // MARK: Forfait et retour dans l'app

    func testAPlanCanBeFollowed() {
        launch(["-fluxaScreen", "forfait"])
        XCTAssertTrue(app.navigationBars["Forfait mobile"].waitForExistence(timeout: 30))
        let volume = app.textFields["volume-forfait"]
        XCTAssertTrue(scroll(to: volume))
        focus(volume)
        // Un forfait déjà réglé par un test précédent est remplacé.
        volume.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "50")
        closeKeyboard()
        let save = app.buttons["enregistrer-forfait"]
        XCTAssertTrue(scroll(to: save))
        save.tap()
        XCTAssertFalse(app.descendants(matching: .any)["erreur-forfait"].exists)
        app.swipeDown()
        app.swipeDown()
        let gauge = app.descendants(matching: .any)["jauge-forfait"]
        XCTAssertTrue(gauge.waitForExistence(timeout: 5))
        XCTAssertTrue(gauge.label.contains("sur 50"), gauge.label)
        XCTAssertTrue(element(containing: "Budget par jour").exists)
        assertNoError()
    }

    func testAPlanWithoutVolumeIsRefused() {
        launch(["-fluxaScreen", "forfait"])
        XCTAssertTrue(app.navigationBars["Forfait mobile"].waitForExistence(timeout: 30))
        let volume = app.textFields["volume-forfait"]
        XCTAssertTrue(scroll(to: volume))
        focus(volume)
        // Une saisie qui n'est pas un nombre.
        volume.typeText("x")
        closeKeyboard()
        let save = app.buttons["enregistrer-forfait"]
        XCTAssertTrue(scroll(to: save))
        save.tap()
        XCTAssertTrue(scroll(to: app.descendants(matching: .any)["erreur-forfait"]))
    }

    func testComingBackShowsWhatHappenedMeanwhile() {
        launch(["-fluxaAbsenceMinimum", "1"])
        XCTAssertTrue(app.navigationBars["Tableau de bord"].waitForExistence(timeout: 30))
        // Quelques relevés d'abord : le dernier sert de point de reprise.
        let throughput = app.descendants(matching: .any)["debit"]
        XCTAssertTrue(throughput.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "NOT (label CONTAINS %@)", "—"), evaluatedWith: throughput)
        waitForExpectations(timeout: 30)

        XCUIDevice.shared.press(.home)
        // Du trafic pendant l'absence : les compteurs du système avancent sans l'app.
        let fetched = expectation(description: "page téléchargée")
        URLSession.shared.dataTask(with: URL(string: "https://www.apple.com/")!) { _, _, _ in
            fetched.fulfill()
        }.resume()
        _ = XCTWaiter().wait(for: [fetched], timeout: 20)
        sleep(3)
        app.activate()

        let card = app.descendants(matching: .any)["hors-app"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(scroll(to: card))
        XCTAssertTrue(card.label.contains("Au moins"), card.label)
        assertNoError()
    }

    // MARK: Autorisations

    func testThePermissionsScreenListsWhatFluxaUses() {
        launch(["-fluxaScreen", "autorisations"])
        XCTAssertTrue(app.navigationBars["Autorisations"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["tout-autoriser"].waitForExistence(timeout: 10))
        for kind in ["localNetwork", "vpn", "notifications", "liveActivities", "backgroundRefresh", "cellularData"] {
            XCTAssertTrue(
                scroll(to: app.descendants(matching: .any)["autorisation-\(kind)"].firstMatch, swipes: 6),
                "ligne absente : \(kind)")
        }
        assertNoError()
    }

    func testThePermissionsAreReachableFromSettings() {
        launch(["-fluxaTab", "reglages"])
        XCTAssertTrue(app.navigationBars["Réglages"].waitForExistence(timeout: 30))
        let link = app.descendants(matching: .any)["reglage-autorisations"]
        XCTAssertTrue(scroll(to: link))
        link.tap()
        XCTAssertTrue(app.navigationBars["Autorisations"].waitForExistence(timeout: 10))
    }

    // MARK: Widgets et Dynamic Island

    func testTheWidgetsAndTheIslandCanBePreviewed() {
        launch(["-fluxaScreen", "widgets"])
        XCTAssertTrue(app.navigationBars["Widgets et Dynamic Island"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["apercu-widgets"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Aujourd’hui").exists)
        XCTAssertTrue(scroll(to: app.descendants(matching: .any)["apercu-ile"]))
        XCTAssertTrue(element(containing: "Relais de partage").exists)
        assertNoError()
    }

    func testTheWidgetsAreReachableFromSettings() {
        launch(["-fluxaTab", "reglages"])
        XCTAssertTrue(app.navigationBars["Réglages"].waitForExistence(timeout: 30))
        let link = app.descendants(matching: .any)["reglage-widgets"]
        XCTAssertTrue(scroll(to: link))
        link.tap()
        XCTAssertTrue(app.navigationBars["Widgets et Dynamic Island"].waitForExistence(timeout: 10))
    }

    // MARK: Relais de partage

    func testTheRelayCarriesAndCountsADevicesTraffic() {
        launch(["-fluxaScreen", "relais"])
        XCTAssertTrue(app.navigationBars["Relais de partage"].waitForExistence(timeout: 30))
        let toggle = app.switches["interrupteur-relais"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        turnOn(toggle)
        XCTAssertTrue(element(containing: "En service").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "proxy.pac").exists)

        // Un appareil relié : le lanceur de tests, qui passe par le relais (boucle locale).
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 8888,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 8888,
        ]
        let answered = expectation(description: "page relayée")
        let result = Box()
        URLSession(configuration: configuration).dataTask(with: URL(string: "https://www.apple.com/")!) { data, response, _ in
            result.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result.bytes = data?.count ?? 0
            answered.fulfill()
        }.resume()
        wait(for: [answered], timeout: 30)
        XCTAssertEqual(result.status, 200)
        XCTAssertGreaterThan(result.bytes, 0)

        // L'appareil apparaît, avec son trafic relayé.
        let device = app.descendants(matching: .any)["appareil-relaye"].firstMatch
        XCTAssertTrue(scroll(to: device))
        XCTAssertTrue(element(containing: "127.0.0.1").exists)
        XCTAssertFalse(element(containing: "relayé : 0\u{00A0}o vers").exists)
        assertNoError()
    }

    // MARK: Historique, réglages, diagnostic

    func testTheHistoryShowsItsSummary() {
        launch(["-fluxaTab", "historique"])
        XCTAssertTrue(app.navigationBars["Historique"].waitForExistence(timeout: 30))
        XCTAssertTrue(scroll(to: element(containing: "Reçu")))
        // La comparaison avec la période précédente et l'export sont là.
        XCTAssertTrue(scroll(to: app.descendants(matching: .any)["comparaison"]))
        XCTAssertTrue(app.navigationBars.buttons["Exporter"].exists)
        app.swipeDown()
        app.swipeDown()
        for period in ["30 jours", "1 heure", "24 heures"] {
            app.buttons[period].tap()
            assertNoError()
        }
        // Sur un jour, le volume se lit aussi par réseau.
        let networks = app.descendants(matching: .any).matching(identifier: "par-reseau").firstMatch
        XCTAssertTrue(networks.waitForExistence(timeout: 10))
        XCTAssertTrue(scroll(to: element(containing: "PAR RÉSEAU")))
    }

    func testTheHistoryCanBeErased() {
        launch(["-fluxaTab", "reglages"])
        XCTAssertTrue(app.navigationBars["Réglages"].waitForExistence(timeout: 30))
        let erase = button(startingWith: "Effacer l")
        XCTAssertTrue(scroll(to: erase.firstMatch))
        erase.firstMatch.tap()
        XCTAssertTrue(element(containing: "Vos profils et votre forfait sont conservés").waitForExistence(timeout: 5))
        // La confirmation propose le même libellé. Le bouton de la page est masqué par elle :
        // celui qu'on peut toucher est le sien.
        let confirm = button(startingWith: "Effacer l").allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(confirm, "le bouton de confirmation n'est pas touchable")
        confirm?.tap()
        assertNoError()
        XCTAssertTrue(app.navigationBars["Réglages"].exists)
    }

    func testTheDiagnosticsListWhatTheIPhoneAllows() {
        launch(["-fluxaScreen", "diagnostic"])
        XCTAssertTrue(app.navigationBars["Diagnostic"].waitForExistence(timeout: 30))
        XCTAssertTrue(element(containing: "Mesurer la connexion").waitForExistence(timeout: 5))
        XCTAssertTrue(scroll(to: element(containing: "internet_monitoring"), swipes: 12))
    }
}

/// Un résultat rempli par une tâche réseau, lu par le test.
private final class Box: @unchecked Sendable {
    var status = 0
    var bytes = 0
}

import XCTest

/// L'app, manipulée comme le ferait quelqu'un : chaque test la lance et vérifie un écran.
final class FluxaUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ arguments: [String] = []) {
        app.launchArguments = arguments
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

    private func assertNoError(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            app.alerts["Action impossible"].waitForExistence(timeout: 2),
            "l'app a affiché une erreur",
            file: file,
            line: line
        )
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
        XCTAssertTrue(button(startingWith: "Ouvrir").firstMatch.exists)
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
        name.tap()
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

    // MARK: Historique, réglages, diagnostic

    func testTheHistoryShowsItsSummary() {
        launch(["-fluxaTab", "historique"])
        XCTAssertTrue(app.navigationBars["Historique"].waitForExistence(timeout: 30))
        XCTAssertTrue(scroll(to: element(containing: "Reçu")))
        app.swipeDown()
        app.swipeDown()
        for period in ["24 heures", "30 jours", "1 heure"] {
            app.buttons[period].tap()
            assertNoError()
        }
    }

    func testTheHistoryCanBeErased() {
        launch(["-fluxaTab", "reglages"])
        XCTAssertTrue(app.navigationBars["Réglages"].waitForExistence(timeout: 30))
        let erase = button(startingWith: "Effacer l")
        XCTAssertTrue(scroll(to: erase.firstMatch))
        erase.firstMatch.tap()
        XCTAssertTrue(element(containing: "Vos profils sont conservés").waitForExistence(timeout: 5))
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

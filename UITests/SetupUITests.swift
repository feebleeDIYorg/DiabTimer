import XCTest

/// Startet die App ohne gespeicherten Server und prüft die Einrichtung.
/// Alles in einem Test, damit der Simulator die App nur einmal starten muss.
final class SetupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSetupValidatesInput() {
        let app = XCUIApplication()
        app.launch()

        let urlField = app.textFields["serverURL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 30))
        let token = app.secureTextFields["token"]
        XCTAssertTrue(token.exists)

        let connect = app.buttons["connect"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled, "Ohne Adresse und Token darf nicht verbunden werden")

        urlField.tap()
        urlField.typeText("http://")
        token.tap()
        token.typeText("abc")
        XCTAssertTrue(connect.isEnabled)
        connect.tap()

        XCTAssertTrue(app.staticTexts["Die Adresse ist ungültig."].waitForExistence(timeout: 10))
    }
}

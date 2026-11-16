import XCTest

/// Startet die App ohne gespeicherten Server und prüft die Einrichtung.
final class SetupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSetupIsShownWithoutServer() {
        let app = XCUIApplication()
        app.launch()

        let urlField = app.textFields["serverURL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["token"].exists)

        let connect = app.buttons["connect"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled, "Ohne Adresse und Token darf nicht verbunden werden")
    }

    @MainActor
    func testInvalidAddressShowsMessage() {
        let app = XCUIApplication()
        app.launch()

        let urlField = app.textFields["serverURL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10))
        urlField.tap()
        urlField.typeText("http://")
        let token = app.secureTextFields["token"]
        token.tap()
        token.typeText("abc")
        app.buttons["connect"].tap()

        XCTAssertTrue(app.staticTexts["Die Adresse ist ungültig."].waitForExistence(timeout: 5))
    }
}

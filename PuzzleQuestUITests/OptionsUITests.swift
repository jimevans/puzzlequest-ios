import XCTest

/// Choosing the server in Options. These launch the app without
/// PQ_SERVER_URL, so it uses the server Options says (Production, until a
/// test chooses the test server). They never sign in to Production, or ask
/// it anything: a new install has no session there to check.
final class OptionsUITests: XCTestCase {
    private var server: TestServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try TestServer.fromEnvironment()
    }

    /// How the app names the test server, such as localhost:3970.
    private var serverName: String {
        [server.url.host(), server.url.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
    }

    @MainActor
    func testOptionsStartsWithProduction() {
        let app = XCUIApplication.launchedAsNew()
        XCTAssertTrue(
            app.textFields["sign-in.user-name"].waitForExistence(timeout: 30),
            "the sign-in screen didn't show")
        // Production isn't named on the sign-in screen.
        XCTAssertFalse(app.element("sign-in.server").exists)

        app.element("sign-in.options").tapWhenHittable()
        let current = app.element("options.current")
        XCTAssertTrue(current.waitForExistence(timeout: 10), "Options didn't open")
        XCTAssertTrue(
            current.label.contains("thepuzzlequest.com") || "\(current.value ?? "")".contains("thepuzzlequest.com"),
            "the server in use is \(current.label) \(current.value ?? "")")
        XCTAssertTrue(app.element("options.server.production").isSelected, "Production isn't chosen")
        XCTAssertFalse(app.element("options.server.custom").isSelected)
        XCTAssertTrue(app.element("options.server.this-mac").exists, "a debug build offers This Mac")

        app.element("options.done").tap()
        XCTAssertTrue(
            app.textFields["sign-in.user-name"].waitForExistence(timeout: 10),
            "Options didn't close")
    }

    @MainActor
    func testACustomServerIsCheckedNamedAndSignedInTo() {
        let app = XCUIApplication.launchedAsNew()
        chooseTestServer(in: app)

        let note = app.element("sign-in.server")
        XCTAssertTrue(note.waitForExistence(timeout: 10), "the sign-in screen didn't name the server")
        XCTAssertTrue(note.label.contains("Signing in to \(serverName)"), "it says \(note.label)")

        app.signIn(userName: server.userName, password: server.password)
        XCTAssertTrue(
            app.navigationBars["Your quests"].waitForExistence(timeout: 30),
            "signing in to the custom server didn't work")
    }

    @MainActor
    func testSwitchingServersAsksThenSignsOut() {
        let app = XCUIApplication.launchedAsNew()
        chooseTestServer(in: app)
        app.signIn(userName: server.userName, password: server.password)
        let home = app.navigationBars["Your quests"]
        XCTAssertTrue(home.waitForExistence(timeout: 30), "the home screen didn't show")
        app.dismissSavePassword()

        openOptionsFromHome(app)
        app.element("options.server.production").tapWhenHittable()
        let confirm = app.buttons["Switch and sign out"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "switching didn't ask first")

        // Staying changes nothing. On an iPhone the question shows as a
        // popover without a Cancel button; tapping outside it is cancelling.
        app.element("options.current").tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10), "the question didn't go away")
        XCTAssertTrue(
            app.element("options.server.custom").isSelected, "cancelling changed the choice")
        app.element("options.done").tap()
        XCTAssertTrue(home.waitForExistence(timeout: 10), "cancelling signed out")

        openOptionsFromHome(app)
        app.element("options.server.production").tapWhenHittable()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "switching didn't ask first")
        confirm.tap()
        XCTAssertTrue(
            app.textFields["sign-in.user-name"].waitForExistence(timeout: 30),
            "switching didn't sign out")
        XCTAssertFalse(app.element("sign-in.server").exists, "Production shouldn't be named")
    }

    /// From the sign-in screen, chooses Custom in Options and types the test
    /// server's address, which the app checks before switching to it.
    @MainActor
    private func chooseTestServer(in app: XCUIApplication) {
        XCTAssertTrue(
            app.textFields["sign-in.user-name"].waitForExistence(timeout: 30),
            "the sign-in screen didn't show")
        app.element("sign-in.options").tapWhenHittable()
        let custom = app.element("options.server.custom")
        XCTAssertTrue(custom.waitForExistence(timeout: 10), "Options didn't open")
        custom.tap()
        let address = app.textFields["options.custom-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "there's nowhere to type an address")
        address.typeWhenFocused(server.url.absoluteString)
        app.buttons["options.use-custom"].tap()
        // Switching rebuilds the screens for the new server, closing Options.
        XCTAssertTrue(
            custom.waitForNonExistence(timeout: 30),
            "Options didn't close: \(app.element("options.error").label)")
    }

    /// Opens Options from the home screen's account menu.
    @MainActor
    private func openOptionsFromHome(_ app: XCUIApplication) {
        app.element("home.account").tapWhenHittable()
        // A menu's items don't keep accessibility identifiers.
        let options = app.buttons["Options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10), "the account menu didn't open")
        options.tap()
        XCTAssertTrue(
            app.element("options.current").waitForExistence(timeout: 10), "Options didn't open")
    }
}

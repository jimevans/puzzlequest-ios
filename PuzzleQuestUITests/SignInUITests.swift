import XCTest

/// The sign-in journey in the app, against the real server started by
/// scripts/start-test-server.sh (see TestServer).
final class SignInUITests: XCTestCase {
    private var server: TestServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try TestServer.fromEnvironment()
    }

    @MainActor
    func testSignInStaySignedInAndSignOut() {
        let app = XCUIApplication.launchedSignedOut(server)
        app.signIn(userName: server.userName, password: server.password)

        let home = app.navigationBars["Your quests"]
        XCTAssertTrue(home.waitForExistence(timeout: 30), "the home screen didn't show")
        app.dismissSavePassword()

        // The next launch picks up the session kept in the Keychain.
        app.terminate()
        app.launchEnvironment["PQ_SIGNED_OUT"] = nil
        app.launch()
        XCTAssertTrue(home.waitForExistence(timeout: 30), "the session wasn't restored")

        // Signing out is in the account menu, which says who is signed in.
        app.element("home.account").tapWhenHittable()
        XCTAssertTrue(
            app.staticTexts["Signed in as \(server.displayName)"].waitForExistence(timeout: 10),
            "the account menu didn't say who is signed in")
        app.buttons["Sign out"].tap()
        XCTAssertTrue(
            app.textFields["sign-in.user-name"].waitForExistence(timeout: 30),
            "signing out didn't return to the sign-in screen")

        // And stays signed out.
        app.terminate()
        app.launch()
        XCTAssertTrue(
            app.textFields["sign-in.user-name"].waitForExistence(timeout: 30),
            "the session was restored after signing out")
    }

    @MainActor
    func testWrongPasswordIsExplained() {
        let app = XCUIApplication.launchedSignedOut(server)
        // A user name of its own, since failed sign-ins are limited per name.
        app.signIn(userName: "nobody-\(UUID().uuidString.prefix(8))", password: "wrong")

        let error = app.element("sign-in.error")
        XCTAssertTrue(error.waitForExistence(timeout: 30), "no error was shown")
        XCTAssertEqual(
            error.label,
            "That user name and password don't match an account. Check them and try again.")
    }

    @MainActor
    func testSigningUpIsOnTheWebsite() {
        let app = XCUIApplication.launchedSignedOut(server)
        let signUp = app.element("sign-in.sign-up")
        XCTAssertTrue(signUp.waitForExistence(timeout: 30), "there's no way to sign up")
        XCTAssertEqual(signUp.label, "New to PuzzleQuest? Sign up on the website")
    }

    @MainActor
    func testStaffAndAdministratorsAreSentToTheWebsite() {
        let app = XCUIApplication.launchedSignedOut(server)
        app.signIn(userName: server.adminUserName, password: server.adminPassword)

        let note = app.element("website.note")
        XCTAssertTrue(note.waitForExistence(timeout: 30), "the website note didn't show")
        app.dismissSavePassword()
        XCTAssertTrue(app.element("website.open").exists, "there's no link to the website")
        XCTAssertFalse(app.navigationBars["Your quests"].exists)

        app.element("website.sign-out").tapWhenHittable()
        XCTAssertTrue(
            app.textFields["sign-in.user-name"].waitForExistence(timeout: 30),
            "signing out didn't return to the sign-in screen")
    }
}

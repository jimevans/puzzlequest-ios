import XCTest

/// The sign-in journey in the app, against the real server started by
/// scripts/start-test-server.sh. xcodebuild passes the test server's details
/// to these tests from environment variables prefixed with TEST_RUNNER_
/// (TEST_RUNNER_PQ_TEST_SERVER_URL arrives as PQ_TEST_SERVER_URL); without
/// them the tests are skipped.
final class SignInUITests: XCTestCase {
    private struct TestServer {
        var url: String
        var userName: String
        var password: String
        var displayName: String
    }

    private var server: TestServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["PQ_TEST_SERVER_URL"],
            let userName = environment["PQ_TEST_USER_NAME"],
            let password = environment["PQ_TEST_PASSWORD"]
        else {
            throw XCTSkip(
                "Set TEST_RUNNER_PQ_TEST_SERVER_URL, TEST_RUNNER_PQ_TEST_USER_NAME and "
                    + "TEST_RUNNER_PQ_TEST_PASSWORD (see scripts/start-test-server.sh)")
        }
        server = TestServer(
            url: url, userName: userName, password: password,
            displayName: environment["PQ_TEST_DISPLAY_NAME"] ?? userName)
    }

    /// The app, using the test server, starting signed out.
    @MainActor
    private func launchSignedOut() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["PQ_SERVER_URL": server.url, "PQ_SIGNED_OUT": "1"]
        app.launch()
        return app
    }

    @MainActor
    private func signIn(_ app: XCUIApplication, userName: String, password: String) {
        let userNameField = app.textFields["sign-in.user-name"]
        XCTAssertTrue(userNameField.waitForExistence(timeout: 30), "the sign-in screen didn't show")
        userNameField.tap()
        userNameField.typeText(userName)
        let passwordField = app.secureTextFields["sign-in.password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["sign-in.submit"].tap()
    }

    @MainActor
    func testSignInStaySignedInAndSignOut() {
        let app = launchSignedOut()
        signIn(app, userName: server.userName, password: server.password)

        let greeting = app.staticTexts["signed-in.name"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 30), "the signed-in screen didn't show")
        XCTAssertEqual(greeting.label, "Signed in as \(server.displayName)")

        // The next launch picks up the session kept in the Keychain.
        app.terminate()
        app.launchEnvironment["PQ_SIGNED_OUT"] = nil
        app.launch()
        XCTAssertTrue(greeting.waitForExistence(timeout: 30), "the session wasn't restored")

        app.buttons["signed-in.sign-out"].tap()
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
        let app = launchSignedOut()
        // A user name of its own, since failed sign-ins are limited per name.
        signIn(app, userName: "nobody-\(UUID().uuidString.prefix(8))", password: "wrong")

        let error = app.descendants(matching: .any)["sign-in.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 30), "no error was shown")
        XCTAssertEqual(
            error.label,
            "That user name and password don't match an account. Check them and try again.")
    }
}

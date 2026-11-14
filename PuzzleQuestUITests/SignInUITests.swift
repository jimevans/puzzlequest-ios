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
    func testSignUpThenDeleteTheAccount() {
        let app = XCUIApplication.launchedSignedOut(server)
        let signUp = app.element("sign-in.sign-up")
        XCTAssertTrue(signUp.waitForExistence(timeout: 30), "there's no way to sign up")
        XCTAssertEqual(signUp.label, "New to PuzzleQuest? Sign up")
        signUp.tapWhenHittable()

        // What's missing is said at its field, before anything is sent.
        let submit = app.buttons["sign-up.submit"]
        XCTAssertTrue(app.scrollTo(submit, timeout: 30), "the sign-up button isn't there")
        submit.tapWhenHittable()
        app.swipeDown()
        let userNameProblem = app.element("sign-up.userName.error")
        XCTAssertTrue(userNameProblem.waitForExistence(timeout: 10), "nothing was said at the user name")
        XCTAssertEqual(userNameProblem.label, "Required.")

        // Filled in, it signs up and goes straight to the new player's home.
        let userName = TestServer.unique("signup")
        app.textFields["sign-up.userName"].typeWhenFocused(userName)
        let newPassword = app.secureTextFields["sign-up.password"]
        newPassword.tapWhenHittable()
        app.dismissStrongPasswordOffer()
        newPassword.typeWhenFocused(server.password)
        app.secureTextFields["sign-up.confirmPassword"].typeWhenFocused(server.password)
        app.textFields["sign-up.displayName"].typeWhenFocused("Player \(userName)")
        app.textFields["sign-up.email"].typeWhenFocused("\(userName)@example.com")
        // Fixing one field leaves the keyboard there: every letter lands where
        // it was typed.
        XCTAssertEqual(app.textFields["sign-up.userName"].value as? String, userName)
        XCTAssertEqual(app.textFields["sign-up.displayName"].value as? String, "Player \(userName)")
        XCTAssertEqual(app.textFields["sign-up.email"].value as? String, "\(userName)@example.com")
        // Scrolling puts the keyboard away from over the button.
        app.swipeUp()
        XCTAssertTrue(app.scrollTo(submit), "the sign-up button isn't there")
        XCTAssertTrue(
            app.element("sign-up.sms-consent").label.hasPrefix(
                "Checking this box gives The PuzzleQuest Game consent"),
            "the SMS consent isn't shown")
        submit.tapWhenHittable()
        XCTAssertTrue(
            app.navigationBars["Your quests"].waitForExistence(timeout: 30),
            "signing up didn't go to the home screen")
        app.dismissSavePassword()
        XCTAssertTrue(
            app.element("email-reminder.send").waitForExistence(timeout: 10),
            "a new player wasn't asked to verify their email address")

        // Deleting is in the account menu, and needs the right password.
        app.element("home.account").tapWhenHittable()
        let deleteAccount = app.buttons["Delete account"]
        XCTAssertTrue(deleteAccount.waitForExistence(timeout: 10), "the account menu didn't open")
        deleteAccount.tap()
        let password = app.secureTextFields["delete-account.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 30), "the delete screen didn't show")
        XCTAssertFalse(app.buttons["delete-account.delete"].isEnabled, "it deletes with no password")
        password.typeWhenFocused("not the password")
        app.buttons["delete-account.delete"].tapWhenHittable()
        let error = app.element("delete-account.error")
        XCTAssertTrue(error.waitForExistence(timeout: 30), "a wrong password wasn't refused")
        XCTAssertEqual(error.label, "That isn't your password. Check it and try again.")

        password.typeWhenFocused(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 16))
        password.typeText(server.password)
        app.buttons["delete-account.delete"].tapWhenHittable()
        XCTAssertTrue(
            app.textFields["sign-in.user-name"].waitForExistence(timeout: 30),
            "deleting didn't return to the sign-in screen")

        // Gone: it no longer signs in.
        app.signIn(userName: userName, password: server.password)
        let signInError = app.element("sign-in.error")
        XCTAssertTrue(signInError.waitForExistence(timeout: 30), "the deleted account signed in")
        XCTAssertEqual(
            signInError.label,
            "That user name and password don't match an account. Check them and try again.")
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

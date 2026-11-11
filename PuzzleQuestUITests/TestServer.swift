import Foundation
import XCTest

/// The real server started by scripts/start-test-server.sh. xcodebuild passes
/// its details to the UI tests from environment variables prefixed with
/// TEST_RUNNER_ (TEST_RUNNER_PQ_TEST_SERVER_URL arrives as
/// PQ_TEST_SERVER_URL); without them the tests are skipped.
struct TestServer {
    var url: URL
    /// The test player, and an administrator.
    var userName: String
    var password: String
    var displayName: String
    var adminUserName: String
    var adminPassword: String

    /// The server, or a skip when the variables aren't set.
    static func fromEnvironment() throws -> TestServer {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["PQ_TEST_SERVER_URL"], let url = URL(string: address),
            let userName = environment["PQ_TEST_USER_NAME"],
            let password = environment["PQ_TEST_PASSWORD"],
            let adminUserName = environment["PQ_TEST_ADMIN_USER_NAME"],
            let adminPassword = environment["PQ_TEST_ADMIN_PASSWORD"]
        else {
            throw XCTSkip(
                "Set TEST_RUNNER_PQ_TEST_SERVER_URL and the test users' TEST_RUNNER_ variables "
                    + "(see scripts/start-test-server.sh)")
        }
        return TestServer(
            url: url, userName: userName, password: password,
            displayName: environment["PQ_TEST_DISPLAY_NAME"] ?? userName,
            adminUserName: adminUserName, adminPassword: adminPassword)
    }

    // MARK: Setting up through the API

    // The UI tests can't use the app's API client (it's internal to
    // PuzzleQuestKit), so they make the few calls they need as plain JSON.

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Sends a request to the API and returns its JSON answer.
    @discardableResult
    func call(
        _ method: String, _ path: String, token: String? = nil, body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url.appending(path: "api/v1").appending(path: path))
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure(
                description: "\(method) \(path): \(status) \(String(decoding: data, as: UTF8.self))")
        }
        return (data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)) as? [String: Any]
            ?? [:]
    }

    /// A name no one has used, for a user or a quest.
    static func unique(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Signs up a new player, who has no quests, and returns their user name.
    /// They sign in with the test player's password.
    func newPlayer() async throws -> String {
        let userName = Self.unique("player")
        try await call(
            "POST", "users",
            body: [
                "userName": userName, "displayName": "Player \(userName)",
                "email": "\(userName)@example.com", "password": password,
            ])
        return userName
    }

    /// Signs in as the administrator.
    func adminToken() async throws -> String {
        let session = try await call(
            "POST", "sessions",
            body: ["userName": adminUserName, "password": adminPassword, "client": "native"])
        guard let token = session["token"] as? String else {
            throw Failure(description: "signing in as the administrator gave no token")
        }
        return token
    }

    /// As the administrator, makes a quest of one stop for a player to play on
    /// their own, and returns its name and display name. It isn't started.
    func makeQuest(for player: String, admin token: String) async throws -> (
        questName: String, displayName: String
    ) {
        let puzzleName = Self.unique("puzzle")
        try await call(
            "POST", "puzzles", token: token,
            body: [
                "puzzleName": puzzleName, "displayName": "A puzzle", "text": "What has keys?",
                "solutionKeyword": "piano", "solutionText": "A piano",
            ])
        let questName = Self.unique("quest")
        let displayName = "Quest \(questName)"
        try await call(
            "POST", "quests", token: token,
            body: [
                "questName": questName, "displayName": displayName,
                "entrants": [["kind": "player", "name": player]],
                "puzzles": [["puzzleName": puzzleName]],
            ])
        return (questName, displayName)
    }

    /// As the administrator, starts a quest for its players.
    func start(_ questName: String, admin token: String) async throws {
        try await call("POST", "quests/\(questName)/start", token: token)
    }
}

extension XCUIApplication {
    /// The app, using the test server for this run (PQ_SERVER_URL, whatever
    /// Options says), starting signed out.
    @MainActor
    static func launchedSignedOut(_ server: TestServer) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PQ_SERVER_URL": server.url.absoluteString,
            // Signed out of every server, with Options as on a new install.
            "PQ_SIGNED_OUT": "1", "PQ_RESET_SERVER": "1",
            // Shows the home screen's live-update state to the tests.
            "PQ_UI_TESTING": "1",
        ]
        app.launch()
        return app
    }

    /// The app as a new install has it: signed out, using the server chosen
    /// in Options, which is Production until a test chooses another.
    @MainActor
    static func launchedAsNew() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PQ_SIGNED_OUT": "1", "PQ_RESET_SERVER": "1", "PQ_UI_TESTING": "1",
        ]
        app.launch()
        return app
    }

    @MainActor
    func signIn(userName: String, password: String) {
        let userNameField = textFields["sign-in.user-name"]
        XCTAssertTrue(userNameField.waitForExistence(timeout: 30), "the sign-in screen didn't show")
        userNameField.tap()
        userNameField.typeText(userName)
        let passwordField = secureTextFields["sign-in.password"]
        passwordField.tap()
        passwordField.typeText(password)
        buttons["sign-in.submit"].tap()
    }

    /// Dismisses iOS's offer to save the password just used, if it makes one;
    /// it covers the screen. Call it once the screen after signing in shows.
    @MainActor
    func dismissSavePassword() {
        let notNow = buttons["Not Now"]
        guard notNow.waitForExistence(timeout: 5) else { return }
        // A tap while the sheet is still sliding in is lost, so tap until it
        // has gone.
        for _ in 1...3 where notNow.exists {
            notNow.tapWhenHittable()
            if notNow.waitForNonExistence(timeout: 3) { return }
        }
        XCTAssertFalse(notNow.exists, "the offer didn't go away")
    }

    /// Signs out through the home screen's account menu.
    @MainActor
    func signOutFromHome() {
        element("home.account").tapWhenHittable()
        let signOut = buttons["Sign out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), "the account menu didn't open")
        signOut.tap()
    }

    /// Anything with that accessibility identifier.
    @MainActor
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }
}

extension XCUIElement {
    /// Taps it once it can be tapped: a sheet going away can still cover it
    /// for a moment, and on CI's slower simulators a screen can be in the
    /// app's hierarchy for many seconds before it's drawn and can be tapped,
    /// so this waits as long as the tests wait for a screen to appear.
    @MainActor
    func tapWhenHittable(timeout: TimeInterval = 30) {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: self)
        XCTAssertEqual(
            XCTWaiter.wait(for: [hittable], timeout: timeout), .completed,
            "\(self) couldn't be tapped")
        tap()
    }
}

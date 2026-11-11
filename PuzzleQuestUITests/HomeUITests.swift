import XCTest

/// A player's home screen, against the real server started by
/// scripts/start-test-server.sh (see TestServer). Each test signs up a new
/// player, so it starts with no quests.
final class HomeUITests: XCTestCase {
    private var server: TestServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try TestServer.fromEnvironment()
    }

    @MainActor
    func testAQuestAppearsAsItStarts() async throws {
        let player = try await server.newPlayer()
        let admin = try await server.adminToken()
        let quest = try await server.makeQuest(for: player, admin: admin)

        let app = XCUIApplication.launchedSignedOut(server)
        app.signIn(userName: player, password: server.password)
        XCTAssertTrue(
            app.element("home.empty").waitForExistence(timeout: 30),
            "the empty list didn't show")
        XCTAssertEqual(app.element("home.empty").label, "You have no quests yet.")
        app.dismissSavePassword()

        // Once live updates are connected (and the list fetched since), start
        // the quest. It can then only appear through the live update
        // (questsChanged): nothing else fetches the list.
        let live = app.element("home.live-updates")
        XCTAssertTrue(live.waitForExistence(timeout: 30), "the live-update state isn't shown")
        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'connected'"), object: live)
        XCTAssertEqual(
            XCTWaiter.wait(for: [connected], timeout: 30), .completed,
            "live updates didn't connect")
        try await server.start(quest.questName, admin: admin)
        let row = app.element("home.quest.\(quest.questName)")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the live update didn't show the quest")
        XCTAssertTrue(row.label.contains(quest.displayName), "the row is \(row.label)")
        XCTAssertTrue(row.label.contains("In progress"), "the row is \(row.label)")
        XCTAssertFalse(app.element("home.empty").exists)

        row.tapWhenHittable()
        let placeholder = app.element("quest.placeholder")
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10), "the quest didn't open")
        XCTAssertEqual(placeholder.label, "Coming soon")
        XCTAssertTrue(app.navigationBars[quest.displayName].exists)
        app.navigationBars.buttons["Your quests"].tap()

        app.signOutFromHome()
        XCTAssertTrue(
            app.textFields["sign-in.user-name"].waitForExistence(timeout: 30),
            "signing out didn't return to the sign-in screen")
    }

    @MainActor
    func testTheVerificationEmailCanBeSentAgain() async throws {
        let player = try await server.newPlayer()
        let app = XCUIApplication.launchedSignedOut(server)
        app.signIn(userName: player, password: server.password)

        let send = app.element("email-reminder.send")
        XCTAssertTrue(send.waitForExistence(timeout: 30), "the email reminder didn't show")
        app.dismissSavePassword()
        send.tapWhenHittable()
        let result = app.element("email-reminder.result")
        XCTAssertTrue(result.waitForExistence(timeout: 30), "nothing was said")
        XCTAssertEqual(result.label, "Sent. Check your inbox.")
        XCTAssertFalse(send.isEnabled, "it can be sent again at once")
    }
}

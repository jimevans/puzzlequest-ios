import XCTest

/// Offering notifications on a quest, and turning them on, against the real
/// server started by scripts/start-test-server.sh (see TestServer). iOS asks
/// a player once per install, and the simulator remembers the answer between
/// runs, so the offer is checked only while iOS hasn't asked yet; these run
/// in name order, so the offer is checked first.
final class NotificationUITests: XCTestCase {
    private var server: TestServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try TestServer.fromEnvironment()
    }

    /// A new player, with a quest started for them.
    private func newPlayerWithQuest() async throws -> (
        player: String, questName: String, admin: String
    ) {
        let player = try await server.newPlayer()
        let admin = try await server.adminToken()
        let quest = try await server.makeQuest(for: player, admin: admin)
        try await server.start(quest.questName, admin: admin)
        return (player, quest.questName, admin)
    }

    /// Signs in as the player, and opens the quest.
    @MainActor
    private func openQuest(_ questName: String, as player: String) -> XCUIApplication {
        let app = XCUIApplication.launchedSignedOut(server)
        app.signIn(userName: player, password: server.password)
        let row = app.element("home.quest.\(questName)")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the quest isn't on the home screen")
        app.dismissSavePassword()
        row.tapWhenHittable()
        XCTAssertTrue(
            app.element("quest.current-stop").waitForExistence(timeout: 30), "the quest didn't open")
        return app
    }

    @MainActor
    func testAQuestOffersNotificationsUntilThePlayerSaysNotNow() async throws {
        let (player, questName, _) = try await newPlayerWithQuest()
        let app = openQuest(questName, as: player)
        let notNow = app.buttons["quest.notifications.not-now"]
        guard notNow.waitForExistence(timeout: 10) else {
            throw XCTSkip("this simulator has already answered iOS about notifications")
        }
        XCTAssertTrue(app.buttons["quest.notifications.turn-on"].exists)
        notNow.tapWhenHittable()
        XCTAssertTrue(notNow.waitForNonExistence(timeout: 10), "the offer stayed")

        // Not offered on this quest again, even after the app starts again.
        app.terminate()
        app.launchEnvironment["PQ_SIGNED_OUT"] = nil
        app.launch()
        let row = app.element("home.quest.\(questName)")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the quest isn't on the home screen")
        row.tapWhenHittable()
        XCTAssertTrue(
            app.element("quest.current-stop").waitForExistence(timeout: 30), "the quest didn't open")
        XCTAssertFalse(notNow.exists, "it was offered again")
    }

    @MainActor
    func testTurningNotificationsOnLetsThePuzzleMasterReachAPlayerWhoCantBeTexted() async throws {
        let (player, questName, admin) = try await newPlayerWithQuest()
        // Before signing in on this phone, a new player, who has no phone
        // number, can't be reached.
        do {
            try await server.sendMessage(questName, to: player, message: "Hello", admin: admin)
            XCTFail("a player with no way to be reached was sent a message")
        } catch {}
        let app = openQuest(questName, as: player)

        let turnOn = app.buttons["quest.notifications.turn-on"]
        if turnOn.waitForExistence(timeout: 10) {
            turnOn.tapWhenHittable()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                .alerts.buttons["Allow"]
            XCTAssertTrue(allow.waitForExistence(timeout: 15), "iOS didn't ask")
            allow.tap()
            XCTAssertTrue(turnOn.waitForNonExistence(timeout: 10), "the offer stayed")
        }

        // Registered with the session: now the message has somewhere to go.
        var reached = false
        for _ in 0..<20 where !reached {
            do {
                try await server.sendMessage(questName, to: player, message: "Hello", admin: admin)
                reached = true
            } catch {
                try await Task.sleep(for: .seconds(1))
            }
        }
        XCTAssertTrue(reached, "the phone wasn't registered for the player's notifications")
        // And it pops up, as on a phone.
        XCTAssertTrue(
            app.staticTexts["Hello"].waitForExistence(timeout: 15), "the message didn't show")
    }
}

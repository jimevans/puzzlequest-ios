import XCTest

/// A player's quest screen, against the real server started by
/// scripts/start-test-server.sh (see TestServer). Each test makes its own
/// players and quest, starts it, and plays it through the API while the
/// screen is open, so what the screen shows can only come from its live
/// updates.
final class QuestUITests: XCTestCase {
    private var server: TestServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try TestServer.fromEnvironment()
    }

    /// Signs in as the player and opens the quest from the home screen.
    @MainActor
    private func openQuest(_ questName: String, as player: String) -> XCUIApplication {
        let app = XCUIApplication.launchedSignedOut(server)
        app.signIn(userName: player, password: server.password)
        let row = app.element("home.quest.\(questName)")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the quest isn't on the home screen")
        app.dismissSavePassword()
        row.tapWhenHittable()
        XCTAssertTrue(
            app.element("quest.current-stop").waitForExistence(timeout: 30),
            "the quest didn't open")
        app.waitForLiveUpdates("quest.live-updates")
        return app
    }

    @MainActor
    func testTheCurrentStopShowsAndPausingIsShownAsItHappens() async throws {
        let player = try await server.newPlayer()
        let admin = try await server.adminToken()
        let quest = try await server.makeQuest(for: player, admin: admin)
        try await server.start(quest.questName, admin: admin)

        let app = openQuest(quest.questName, as: player)
        let stop = app.element("quest.current-stop")
        XCTAssertTrue(stop.label.contains("Stop 1"), "the stop is \(stop.label)")
        XCTAssertTrue(stop.label.contains("A puzzle"), "the stop is \(stop.label)")
        // It never says how many stops there are.
        XCTAssertFalse(stop.label.contains(" of "), "the stop is \(stop.label)")
        XCTAssertTrue(app.element("quest.summary").label.contains("Total time"))

        try await server.pause(quest.questName, admin: admin)
        XCTAssertTrue(
            app.element("quest.paused").waitForExistence(timeout: 15), "the pause didn't show")
        try await server.resume(quest.questName, admin: admin)
        XCTAssertTrue(
            app.element("quest.paused").waitForNonExistence(timeout: 15),
            "the pause didn't go away")
    }

    @MainActor
    func testFinishingARaceShowsTheFinishTheSolutionAndTheStandings() async throws {
        let player = try await server.newPlayer()
        let rival = try await server.newPlayer()
        let admin = try await server.adminToken()
        let quest = try await server.makeQuest(for: [player, rival], admin: admin)
        try await server.start(quest.questName, admin: admin)
        // The rival finishes first.
        try await server.solveCurrentStop(
            quest.questName, player: try await server.token(for: rival), admin: admin)

        let app = openQuest(quest.questName, as: player)
        // Racing: nothing of the rival yet.
        let standingRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'quest.standing.'"))
        XCTAssertEqual(standingRows.count, 0)

        try await server.solveCurrentStop(
            quest.questName, player: try await server.token(for: player), admin: admin)
        let finished = app.element("quest.finished")
        XCTAssertTrue(finished.waitForExistence(timeout: 15), "the finish didn't show")
        XCTAssertTrue(finished.label.contains("End of the line"), "it says \(finished.label)")
        XCTAssertFalse(app.element("quest.current-stop").exists)

        // Both have finished: the final standings, the rival first.
        let standings = app.staticTexts["Final standings"]
        XCTAssertTrue(standings.waitForExistence(timeout: 15), "the standings didn't show")
        let ownRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'quest.standing.' AND label CONTAINS 'You'"))
            .firstMatch
        XCTAssertTrue(ownRow.waitForExistence(timeout: 5), "the player's own entry isn't marked")
        XCTAssertTrue(ownRow.label.contains("2nd"), "the player's row is \(ownRow.label)")

        // The solved stop opens to its solution.
        let solved = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'quest.solved.'")).firstMatch
        solved.tapWhenHittable()
        let solution = app.element("stop.solution")
        XCTAssertTrue(solution.waitForExistence(timeout: 15), "the stop's details didn't open")
        XCTAssertEqual(solution.label, "A piano")
    }

    @MainActor
    func testAQuestResetWhileOpenIsNoLongerAvailableOnRefreshing() async throws {
        let player = try await server.newPlayer()
        let admin = try await server.adminToken()
        let quest = try await server.makeQuest(for: player, admin: admin)
        try await server.start(quest.questName, admin: admin)

        let app = openQuest(quest.questName, as: player)
        try await server.reset(quest.questName, admin: admin)
        // Resetting sends the quest's followers no update (the API's
        // description says so), so the player sees it on refreshing.
        app.pullToRefresh(from: app.element("quest.summary"))
        XCTAssertTrue(
            app.element("quest.not-available").waitForExistence(timeout: 15),
            "the reset didn't show")
        app.buttons["Back to your quests"].tapWhenHittable()
        XCTAssertTrue(
            app.navigationBars["Your quests"].waitForExistence(timeout: 15),
            "it didn't go back to the home screen")
    }
}

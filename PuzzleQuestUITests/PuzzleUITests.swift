import XCTest

/// A player's puzzle screen, against the real server started by
/// scripts/start-test-server.sh (see TestServer). A simulator has no camera
/// VisionKit can scan with, so the screen offers typing the code, as it does
/// on a phone whose camera can't be used.
final class PuzzleUITests: XCTestCase {
    private var server: TestServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try TestServer.fromEnvironment()
    }

    /// Signs in as the player, opens the quest, and opens its current stop.
    @MainActor
    private func openCurrentStop(_ questName: String, as player: String) -> XCUIApplication {
        let app = XCUIApplication.launchedSignedOut(server)
        app.signIn(userName: player, password: server.password)
        let row = app.element("home.quest.\(questName)")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the quest isn't on the home screen")
        app.dismissSavePassword()
        row.tapWhenHittable()
        app.element("quest.current-stop").tapWhenHittable()
        XCTAssertTrue(
            app.element("puzzle.header").waitForExistence(timeout: 30), "the puzzle didn't open")
        app.waitForLiveUpdates("puzzle.live-updates")
        return app
    }

    /// Types into a field, replacing what's there, and sends it.
    @MainActor
    private func send(_ text: String, in identifier: String, _ app: XCUIApplication) {
        let field = app.textFields[identifier]
        let old = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        let delete = old == placeholder ? "" : String(
            repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)
        field.typeWhenFocused(delete + text)
        app.buttons["\(identifier).send"].tapWhenHittable()
    }

    @MainActor
    func testFindingSolvingAndGoingOnToTheNextStop() async throws {
        let player = try await server.newPlayer()
        let admin = try await server.adminToken()
        let quest = try await server.makeQuest(for: player, stops: 2, admin: admin)
        try await server.start(quest.questName, admin: admin)
        let puzzleName = try await server.currentStop(
            quest.questName, player: try await server.token(for: player))
        let code = try await server.activationCode(
            quest.questName, puzzleName: puzzleName, admin: admin)

        let app = openCurrentStop(quest.questName, as: player)
        let header = app.element("puzzle.header")
        XCTAssertTrue(header.label.contains("Stop 1"), "the header is \(header.label)")
        XCTAssertTrue(header.label.contains("A puzzle"), "the header is \(header.label)")
        // Nothing of the puzzle until it's found.
        XCTAssertFalse(app.staticTexts["What has keys?"].exists)

        // A wrong code, then the right one, in any letter case.
        send("not-the-code", in: "puzzle.activation-code", app)
        let error = app.element("puzzle.action-error")
        XCTAssertTrue(error.waitForExistence(timeout: 15), "the wrong code wasn't refused")
        XCTAssertTrue(error.label.contains("isn't this puzzle's code"), "it says \(error.label)")
        send(code.lowercased(), in: "puzzle.activation-code", app)
        XCTAssertTrue(
            app.staticTexts["What has keys?"].waitForExistence(timeout: 15),
            "the puzzle didn't show")

        // A hint, at its cost; the next gives the solution away, so it asks.
        let revealHint = app.buttons["puzzle.reveal-hint"]
        XCTAssertTrue(revealHint.label.contains("1 minute"), "the button is \(revealHint.label)")
        revealHint.tapWhenHittable()
        let hint = app.element("puzzle.hint.1")
        XCTAssertTrue(hint.waitForExistence(timeout: 15), "the hint didn't show")
        XCTAssertTrue(hint.label.contains("It makes music"), "the hint is \(hint.label)")
        revealHint.tapWhenHittable()
        let keepTrying = app.alerts.buttons["Keep trying"]
        XCTAssertTrue(keepTrying.waitForExistence(timeout: 15), "it didn't ask first")
        keepTrying.tap()
        XCTAssertFalse(app.element("puzzle.hint.2").exists)

        send("an organ", in: "puzzle.answer", app)
        XCTAssertTrue(
            app.element("puzzle.action-error").waitForExistence(timeout: 15),
            "the wrong answer wasn't refused")
        XCTAssertTrue(
            app.element("puzzle.action-error").label.contains("not the answer"),
            "it says \(app.element("puzzle.action-error").label)")
        send("A Piano", in: "puzzle.answer", app)
        let solution = app.element("puzzle.solution")
        XCTAssertTrue(solution.waitForExistence(timeout: 15), "it wasn't solved")
        XCTAssertEqual(solution.label, "A piano")

        let next = app.buttons["puzzle.next-stop"]
        XCTAssertTrue(next.label.contains("Another puzzle"), "the button is \(next.label)")
        next.tapWhenHittable()
        let stop2 = NSPredicate(format: "label CONTAINS 'Stop 2'")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: stop2, object: header)], timeout: 15),
            .completed, "it didn't go on to the next stop")
        XCTAssertTrue(app.textFields["puzzle.activation-code"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testPausingAndSolvingElsewhereShowAsTheyHappenThroughToTheFinish() async throws {
        let player = try await server.newPlayer()
        let admin = try await server.adminToken()
        let quest = try await server.makeQuest(for: player, admin: admin)
        try await server.start(quest.questName, admin: admin)
        let token = try await server.token(for: player)

        let app = openCurrentStop(quest.questName, as: player)
        try await server.pause(quest.questName, admin: admin)
        XCTAssertTrue(
            app.element("puzzle.paused").waitForExistence(timeout: 15), "the pause didn't show")
        XCTAssertFalse(app.textFields["puzzle.activation-code"].isEnabled)
        try await server.resume(quest.questName, admin: admin)
        XCTAssertTrue(
            app.element("puzzle.paused").waitForNonExistence(timeout: 15),
            "the pause didn't go away")

        // Solved elsewhere, as by a teammate on another phone.
        try await server.solveCurrentStop(quest.questName, player: token, admin: admin)
        let finished = app.element("puzzle.finished")
        XCTAssertTrue(finished.waitForExistence(timeout: 15), "the finish didn't show")
        XCTAssertTrue(finished.label.contains("End of the line"), "it says \(finished.label)")
        XCTAssertEqual(app.element("puzzle.solution").label, "A piano")

        app.buttons["Back to the quest"].tapWhenHittable()
        XCTAssertTrue(
            app.element("quest.finished").waitForExistence(timeout: 15),
            "the quest screen didn't show the finish")
    }
}

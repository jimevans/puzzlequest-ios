import Foundation
import Testing

@testable import PuzzleQuestKit

@Suite(
    "A player's puzzle screen, against a real server",
    .enabled(if: TestServer.url != nil, "set PQ_TEST_SERVER_URL (see scripts/start-test-server.sh)"),
    .serialized)
struct PuzzleContractTests {
    /// A started quest of `stops` stops for a new player, and its first stop.
    private func started(stops: Int = 1) async throws -> (
        api: APIClient, admin: APIClient, questName: String, puzzleName: String
    ) {
        let (player, api) = try await TestSite.newPlayer()
        let admin = try await TestSite.admin()
        let questName = try await TestSite.makeQuest(for: player, stops: stops, admin: admin)
        try await TestSite.start(questName, admin: admin)
        let quest = try #require(try await api.playerQuest(questName: questName))
        let stop = try #require(quest.entry.currentStop)
        return (api, admin, questName, stop.puzzleName)
    }

    @Test("A puzzle waiting to be found shows nothing of itself, and a wrong code is refused")
    func activation() async throws {
        let (api, admin, questName, puzzleName) = try await started()
        let waiting = try #require(
            try await api.playerPuzzle(questName: questName, puzzleName: puzzleName))
        #expect(waiting.status == .awaitingActivation)
        #expect(waiting.stopNumber == 1)
        #expect(waiting.displayName == "A puzzle")
        #expect(waiting.content == nil)
        #expect(waiting.nextHint == nil)

        do {
            try await api.activatePuzzle(
                questName: questName, puzzleName: puzzleName, code: "not-the-code",
                connectionId: nil)
            Issue.record("a wrong code was accepted")
        } catch {
            #expect(PuzzleActionError(error) == .wrongCode)
        }

        // Any letter case.
        let code = try await TestSite.activationCode(questName, puzzleName: puzzleName, admin: admin)
        try await api.activatePuzzle(
            questName: questName, puzzleName: puzzleName, code: code.lowercased(),
            connectionId: nil)
        let puzzle = try #require(
            try await api.playerPuzzle(questName: questName, puzzleName: puzzleName))
        #expect(puzzle.status == .inProgress)
        #expect(puzzle.content == .text("What has *keys*?"))
        #expect(puzzle.nextHint == NextHint(penaltySeconds: 60, givesSolutionAway: false))
    }

    @Test("Hints add their penalties; a wrong guess is refused; the right one solves it")
    func solving() async throws {
        let (api, admin, questName, puzzleName) = try await started(stops: 2)
        let code = try await TestSite.activationCode(questName, puzzleName: puzzleName, admin: admin)
        try await api.activatePuzzle(
            questName: questName, puzzleName: puzzleName, code: code, connectionId: nil)

        try await api.revealHint(questName: questName, puzzleName: puzzleName, connectionId: nil)
        var puzzle = try #require(
            try await api.playerPuzzle(questName: questName, puzzleName: puzzleName))
        #expect(puzzle.hints == [RevealedHint(text: "It makes music", penaltySeconds: 60)])
        #expect(puzzle.nextHint == NextHint(penaltySeconds: 300, givesSolutionAway: true))
        #expect(puzzle.clock.penaltyMs == 60_000)

        do {
            try await api.attemptSolution(
                questName: questName, puzzleName: puzzleName, guess: "an organ", connectionId: nil)
            Issue.record("a wrong guess was accepted")
        } catch {
            #expect(PuzzleActionError(error) == .wrongAnswer)
        }

        // Letter case and punctuation don't matter.
        try await api.attemptSolution(
            questName: questName, puzzleName: puzzleName, guess: "A Piano!", connectionId: nil)
        puzzle = try #require(
            try await api.playerPuzzle(questName: questName, puzzleName: puzzleName))
        #expect(puzzle.status == .completed)
        #expect(puzzle.solutionText == "A piano")
        #expect(puzzle.nextHint == nil)
        #expect(!puzzle.questFinished)
        let next = try #require(puzzle.next)
        #expect(next.displayName == "Another puzzle")

        let following = try #require(
            try await api.playerPuzzle(questName: questName, puzzleName: next.puzzleName))
        #expect(following.stopNumber == 2)
        #expect(following.status == .awaitingActivation)
    }

    @Test("While the quest is paused, actions are refused as paused")
    func paused() async throws {
        let (api, admin, questName, puzzleName) = try await started()
        let output = try await admin.client.pauseQuest(path: .init(questName: questName))
        guard case .ok = output else {
            throw APIError.unexpectedResponse("pauseQuest: \(output)")
        }
        let puzzle = try #require(
            try await api.playerPuzzle(questName: questName, puzzleName: puzzleName))
        #expect(puzzle.paused)
        let code = try await TestSite.activationCode(questName, puzzleName: puzzleName, admin: admin)
        do {
            try await api.activatePuzzle(
                questName: questName, puzzleName: puzzleName, code: code, connectionId: nil)
            Issue.record("activating while paused was accepted")
        } catch {
            #expect(PuzzleActionError(error) == .paused)
        }
    }

    @Test("A stop not yet reached, or after a reset, isn't available")
    func notAvailable() async throws {
        let (api, admin, questName, puzzleName) = try await started()
        #expect(
            try await api.playerPuzzle(questName: questName, puzzleName: "no-such-puzzle") == nil)
        try await TestSite.reset(questName, admin: admin)
        #expect(try await api.playerPuzzle(questName: questName, puzzleName: puzzleName) == nil)
    }
}

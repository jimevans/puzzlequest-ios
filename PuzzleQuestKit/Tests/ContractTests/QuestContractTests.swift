import Foundation
import Testing

@testable import PuzzleQuestKit

@Suite(
    "A player's quest screen, against a real server",
    .enabled(if: TestServer.url != nil, "set PQ_TEST_SERVER_URL (see scripts/start-test-server.sh)"),
    .serialized)
struct QuestContractTests {
    @Test("A quest isn't available until it starts; then it has one stop, waiting to be found")
    func started() async throws {
        let (player, api) = try await TestSite.newPlayer()
        let admin = try await TestSite.admin()
        let questName = try await TestSite.makeQuest(for: player, admin: admin)
        #expect(try await api.playerQuest(questName: questName) == nil)

        try await TestSite.start(questName, admin: admin)
        let quest = try #require(try await api.playerQuest(questName: questName))
        #expect(quest.questName == questName)
        #expect(quest.displayName == "Quest \(questName)")
        #expect(!quest.entry.isTeam)
        #expect(quest.entry.status == .inProgress)
        #expect(!quest.entry.paused)
        #expect(quest.entry.clock.isCounting)
        let stop = try #require(quest.entry.currentStop)
        #expect(quest.entry.stops.count == 1)
        #expect(stop.number == 1)
        #expect(stop.displayName == "A puzzle")
        #expect(stop.status == .awaitingActivation)
        #expect(stop.solutionText == nil)
        #expect(quest.entry.finishedStops.isEmpty)
    }

    @Test("Solving the last stop finishes the quest, with the solution shown")
    func finishing() async throws {
        let (player, api) = try await TestSite.newPlayer()
        let admin = try await TestSite.admin()
        let questName = try await TestSite.makeQuest(for: player, admin: admin)
        try await TestSite.start(questName, admin: admin)

        try await TestSite.solveCurrentStop(questName, player: api, admin: admin)
        let quest = try #require(try await api.playerQuest(questName: questName))
        #expect(quest.entry.isFinished)
        #expect(!quest.entry.clock.isCounting)
        #expect(quest.entry.currentStop == nil)
        let stop = try #require(quest.entry.finishedStops.first)
        #expect(stop.status == .completed)
        #expect(stop.solutionText == "A piano")
        #expect(stop.endTime != nil)
        #expect(stop.clock != nil)
    }

    @Test("In a race, a finished player sees the standings, provisional until all finish")
    func standings() async throws {
        let (first, firstAPI) = try await TestSite.newPlayer()
        let (second, secondAPI) = try await TestSite.newPlayer()
        let admin = try await TestSite.admin()
        let questName = try await TestSite.makeQuest(for: [first, second], admin: admin)
        try await TestSite.start(questName, admin: admin)

        try await TestSite.solveCurrentStop(questName, player: firstAPI, admin: admin)
        let own = try #require(try await firstAPI.playerQuest(questName: questName))
        let standings = try await firstAPI.standings(questName: questName)
        #expect(standings.provisional)
        #expect(!standings.rivalsHidden)
        #expect(standings.entries.count == 2)
        #expect(standings.entries.first?.id == own.entry.id)
        #expect(standings.entries.first?.rank == 1)
        #expect(standings.entries.last?.rank == nil)

        try await TestSite.solveCurrentStop(questName, player: secondAPI, admin: admin)
        let final = try await firstAPI.standings(questName: questName)
        #expect(final.isFinal)
        #expect(final.entries.map(\.rank) == [1, 2])
    }

    @Test("A challenge from the puzzle master shows; a wrong answer is refused, a right one shows the confirmation")
    func challenge() async throws {
        let (player, api) = try await TestSite.newPlayer()
        let admin = try await TestSite.admin()
        let questName = try await TestSite.makeQuest(for: player, admin: admin)
        try await TestSite.start(questName, admin: admin)
        try await TestSite.registerPhone(api)
        try await TestSite.sendChallenge(questName, to: player, admin: admin)

        let quest = try #require(try await api.playerQuest(questName: questName))
        #expect(quest.entry.messages.map(\.text) == ["What lights the harbour?"])
        #expect(quest.entry.messages.first?.isChallenge == true)
        let challenge = try #require(quest.entry.waitingChallenge)
        #expect(challenge.message == "What lights the harbour?")

        do {
            _ = try await api.answerChallenge(questName: questName, answer: "an organ")
            Issue.record("a wrong answer was accepted")
        } catch {
            #expect(ChallengeAnswerError(error) == .wrongAnswer)
        }
        // Keywords, as puzzle answers: any letter case, with other words.
        let answered = try await api.answerChallenge(
            questName: questName, answer: "It's the LIGHTHOUSE!")
        #expect(answered.confirmation == "Show this to the bartender")

        let after = try #require(try await api.playerQuest(questName: questName))
        let answer = try #require(after.entry.challenge?.answer)
        #expect(answer.confirmation == "Show this to the bartender")
        #expect(!answer.byText)
        do {
            _ = try await api.answerChallenge(questName: questName, answer: "lighthouse")
            Issue.record("an answered challenge was answered again")
        } catch {
            #expect(ChallengeAnswerError(error) == .changed)
        }
    }

    @Test("A quest reset by the puzzle master isn't available to its player")
    func reset() async throws {
        let (player, api) = try await TestSite.newPlayer()
        let admin = try await TestSite.admin()
        let questName = try await TestSite.makeQuest(for: player, admin: admin)
        try await TestSite.start(questName, admin: admin)
        try await TestSite.reset(questName, admin: admin)
        #expect(try await api.playerQuest(questName: questName) == nil)
    }

    @Test("Following the quest hears of the player's own progress")
    func liveUpdates() async throws {
        let (player, api) = try await TestSite.newPlayer()
        let admin = try await TestSite.admin()
        let questName = try await TestSite.makeQuest(for: player, admin: admin)
        try await TestSite.start(questName, admin: admin)

        let events = Events()
        let follower = LiveUpdateFollower(
            url: api.liveUpdatesURL, channel: .quest(questName: questName),
            ticket: { try await api.questLiveTicket(questName: questName) })
        let following = Task { await follower.run { await events.record($0) } }
        defer { following.cancel() }

        try await events.waitFor {
            if case .connected = $0 { true } else { false }
        }
        try await TestSite.solveCurrentStop(questName, player: api, admin: admin)
        try await events.waitFor {
            if case .update(.questChanged(_, questName, _)) = $0 { true } else { false }
        }
    }
}

import Foundation
import Testing

@testable import PuzzleQuestKit

/// A clock as the API sends one, stopped unless running.
func clockJSON(
    elapsedMs: Int = 0, penaltyMs: Int = 0, running: Bool = false, started: Bool = true,
    puzzleName: String? = nil
) -> String {
    let start = started ? #""2026-11-11T16:00:00.000Z""# : "null"
    let clockStart = running ? #""2026-11-11T16:00:00.000Z""# : "null"
    let name = puzzleName.map { #""puzzleName":"\#($0)","# } ?? ""
    return #"{\#(name)"startTime":\#(start),"endTime":null,"running":\#(running),"clockStart":\#(clockStart),"elapsedMs":\#(elapsedMs),"penaltyMs":\#(penaltyMs),"totalMs":\#(elapsedMs + penaltyMs)}"#
}

/// A stop as the API sends one to its player.
func stopJSON(_ name: String, status: String = "inProgress", solution: String? = nil) -> String {
    let description =
        switch status {
        case "awaitingActivation": "Find the puzzle"
        case "completed": "Solved"
        default: "In progress"
        }
    let solutionField = solution.map { #","solutionText":"\#($0)""# } ?? ""
    return #"{"puzzleName":"\#(name)","displayName":"The \#(name)","status":"\#(status)","statusDescription":"\#(description)","hintsRevealed":0,"activationTime":null,"startTime":"2026-11-11T16:00:00.000Z","endTime":null,"skipped":false,"hints":[]\#(solutionField)}"#
}

/// A message from the puzzle master, as the API sends it.
func messageJSON(_ text: String, at minute: Int = 5, challenge: Bool = false) -> String {
    #"{"text":"\#(text)","sentAt":"2026-11-11T16:\#(String(format: "%02d", minute)):00.000Z","challenge":\#(challenge)}"#
}

/// The entry's challenge as the API sends it to a player: the confirmation
/// only once it's answered.
func challengeJSON(
    _ message: String = "What lights the harbour?", answeredVia: String? = nil
) -> String {
    let answered =
        answeredVia.map {
            #""answeredAt":"2026-11-11T16:20:00.000Z","answeredVia":"\#($0)","confirmation":"Show this to the bartender""#
        } ?? #""answeredAt":null,"answeredVia":null"#
    return #"{"challengeId":"c1","message":"\#(message)","sentAt":"2026-11-11T16:10:00.000Z",\#(answered)}"#
}

/// A player's quest as the API sends it, with their entry's stops.
func playerQuestJSON(
    _ stops: [String], status: String = "inProgress", paused: Bool = false,
    clocks: [String] = [], kind: String = "player", entryId: String = "e1",
    messages: [String] = [], challenge: String = "null"
) -> String {
    #"""
    {"questName":"harbor","displayName":"Harbor walk","entries":[{"id":"\#(entryId)",
     "entrant":{"kind":"\#(kind)","name":"pat","displayName":"Pat"},
     "messages":[\#(messages.joined(separator: ","))],"challenge":\#(challenge),
     "status":"\#(status)","statusDescription":"\#(status == "completed" ? "Finished" : "In progress")",
     "paused":\#(paused),"puzzles":[\#(stops.joined(separator: ","))],
     "progress":{"startTime":"2026-11-11T16:00:00.000Z","endTime":null,"running":\#(!paused && status != "completed"),
      "clockStart":\#(!paused && status != "completed" ? #""2026-11-11T16:00:00.000Z""# : "null"),
      "elapsedMs":600000,"penaltyMs":60000,"totalMs":660000,"puzzles":[\#(clocks.joined(separator: ","))]}}]}
    """#
}

/// One entry in the standings, as the spectator view sends it.
func standingJSON(_ id: String, name: String?, rank: Int?, status: String = "completed") -> String {
    let displayName = name.map { #""\#($0)""# } ?? "null"
    return #"{"id":"\#(id)","entrant":{"kind":"team","displayName":\#(displayName)},"status":"\#(status)","statusDescription":"\#(status == "completed" ? "Finished" : "In progress")","paused":false,"rank":\#(rank.map(String.init) ?? "null"),"progress":\#(clockJSON(elapsedMs: 1000).dropLast()),"puzzles":[]},"puzzles":[]}"#
}

func standingsJSON(_ entries: [String], provisional: Bool) -> String {
    #"{"questName":"harbor","displayName":"Harbor walk","racing":\#(provisional),"stopsHidden":false,"rivalsHidden":false,"provisional":\#(provisional),"entries":[\#(entries.joined(separator: ","))]}"#
}

@Suite("Reading a player's quest")
struct PlayerQuestTests {
    @Test("Stops are numbered as reached, with their clocks; the current one is the unsolved one")
    func stops() async throws {
        let transport = FakeTransport { _ in
            json(
                200,
                playerQuestJSON(
                    [
                        stopJSON("quay", status: "completed", solution: "ANCHOR"),
                        stopJSON("customs", status: "completed", solution: "LEDGER"),
                        stopJSON("lighthouse", status: "awaitingActivation"),
                    ],
                    clocks: [clockJSON(elapsedMs: 5000, penaltyMs: 1000, puzzleName: "quay")],
                    kind: "team"))
        }
        let quest = try #require(try await api(transport).playerQuest(questName: "harbor"))
        #expect(quest.displayName == "Harbor walk")
        #expect(quest.entry.isTeam)
        #expect(quest.entry.clock.penaltyMs == 60_000)
        #expect(quest.entry.stops.map(\.number) == [1, 2, 3])
        #expect(quest.entry.currentStop?.puzzleName == "lighthouse")
        #expect(quest.entry.currentStop?.status == .awaitingActivation)
        #expect(quest.entry.finishedStops.map(\.puzzleName) == ["customs", "quay"])
        #expect(quest.entry.stops[0].solutionText == "ANCHOR")
        #expect(quest.entry.stops[0].clock?.totalMs == 6000)
        #expect(quest.entry.stops[1].clock == nil)
        #expect(transport.requests.map(\.request.path) == ["/quests/harbor"])
    }

    @Test("The puzzle master's messages and challenge are read; the confirmation only once answered")
    func messagesAndChallenge() async throws {
        let waiting = FakeTransport { _ in
            json(
                200,
                playerQuestJSON(
                    [stopJSON("quay")], kind: "team",
                    messages: [
                        messageJSON("Welcome!", at: 1),
                        messageJSON("What lights the harbour?", at: 10, challenge: true),
                    ],
                    challenge: challengeJSON()))
        }
        let quest = try #require(try await api(waiting).playerQuest(questName: "harbor"))
        #expect(quest.entry.entrantName == "Pat")
        #expect(quest.entry.messages.map(\.text) == ["Welcome!", "What lights the harbour?"])
        #expect(quest.entry.messages.map(\.isChallenge) == [false, true])
        let challenge = try #require(quest.entry.challenge)
        #expect(challenge.message == "What lights the harbour?")
        #expect(challenge.answer == nil)
        #expect(quest.entry.waitingChallenge == challenge)

        let answered = FakeTransport { _ in
            json(200, playerQuestJSON([stopJSON("quay")], challenge: challengeJSON(answeredVia: "sms")))
        }
        let after = try #require(try await api(answered).playerQuest(questName: "harbor"))
        let answer = try #require(after.entry.challenge?.answer)
        #expect(answer.confirmation == "Show this to the bartender")
        #expect(answer.byText)
        #expect(after.entry.waitingChallenge == nil)
    }

    @Test("A finished quest has no current stop")
    func finished() async throws {
        let transport = FakeTransport { _ in
            json(200, playerQuestJSON([stopJSON("quay", status: "completed")], status: "completed"))
        }
        let quest = try #require(try await api(transport).playerQuest(questName: "harbor"))
        #expect(quest.entry.isFinished)
        #expect(quest.entry.currentStop == nil)
    }

    @Test("A quest that isn't found, or has no entry of the player's, isn't available")
    func notAvailable() async throws {
        let missing = FakeTransport { _ in problem(404, "about:blank") }
        #expect(try await api(missing).playerQuest(questName: "harbor") == nil)

        let reset = FakeTransport { _ in
            json(200, #"{"questName":"harbor","displayName":"Harbor walk","entries":[]}"#)
        }
        #expect(try await api(reset).playerQuest(questName: "harbor") == nil)
    }

    @Test("Other refusals are errors")
    func otherErrors() async throws {
        let transport = FakeTransport { _ in problem(500, Problem.Types.unexpected) }
        await #expect(throws: APIError.self) {
            try await api(transport).playerQuest(questName: "harbor")
        }
    }

    @Test("Standings keep the order sent, and a deleted team has no name")
    func standings() async throws {
        let transport = FakeTransport { _ in
            json(
                200,
                standingsJSON(
                    [standingJSON("e2", name: "Reds", rank: 1), standingJSON("e3", name: nil, rank: nil, status: "inProgress")],
                    provisional: true))
        }
        let standings = try await api(transport).standings(questName: "harbor")
        #expect(standings.provisional)
        #expect(!standings.isFinal)
        #expect(standings.entries.map(\.id) == ["e2", "e3"])
        #expect(standings.entries[0].rank == 1)
        #expect(standings.entries[1].displayName == nil)
        #expect(standings.entries[1].rank == nil)
    }
}

@Suite("What's announced as a quest changes")
struct QuestChangeTests {
    func quest(_ stops: [Stop], paused: Bool = false, finished: Bool = false) -> PlayerQuest {
        PlayerQuest(
            questName: "harbor", displayName: "Harbor walk",
            entry: QuestEntryProgress(
                id: "e1", isTeam: false, status: finished ? .completed : .inProgress,
                statusDescription: "", paused: paused, startTime: nil, endTime: nil,
                clock: QuestClock(
                    running: false, clockStart: nil, elapsedMs: 0, penaltyMs: 0, totalMs: 0),
                stops: stops))
    }

    func stop(_ number: Int, _ name: String, _ status: StopStatus) -> Stop {
        Stop(
            number: number, puzzleName: name, displayName: name, status: status,
            statusDescription: "")
    }

    @Test("Pausing, resuming, solving, reaching a stop, and finishing are announced, in that order")
    func changes() {
        let before = quest([stop(1, "Quay", .inProgress)])
        #expect(QuestChange.between(before, before) == [])
        #expect(
            QuestChange.between(before, quest([stop(1, "Quay", .inProgress)], paused: true))
                == [.paused])
        #expect(
            QuestChange.between(
                quest([stop(1, "Quay", .inProgress)], paused: true),
                quest([stop(1, "Quay", .inProgress)])) == [.resumed])
        #expect(
            QuestChange.between(
                before,
                quest([stop(1, "Quay", .completed), stop(2, "Customs", .awaitingActivation)]))
                == [.stopSolved(displayName: "Quay"), .stopReached(number: 2, displayName: "Customs")])
        #expect(
            QuestChange.between(before, quest([stop(1, "Quay", .completed)], finished: true))
                == [.stopSolved(displayName: "Quay"), .finished])
    }

    @Test("A new message, and the challenge being answered, are announced")
    func messagesAndChallenge() {
        let sent = Date(timeIntervalSince1970: 1000)
        var before = quest([stop(1, "Quay", .inProgress)])
        before.entry.messages = [PuzzleMasterMessage(text: "Welcome!", sentAt: sent)]
        before.entry.challenge = Challenge(challengeId: "c1", message: "Riddle?", sentAt: sent)
        var after = before
        after.entry.messages.append(
            PuzzleMasterMessage(text: "Hurry!", sentAt: sent.addingTimeInterval(60)))
        after.entry.challenge?.answer = ChallengeAnswer(answeredAt: sent, confirmation: "Yes")
        #expect(
            QuestChange.between(before, after)
                == [.messageReceived(text: "Hurry!", isChallenge: false), .challengeAnswered])

        // A new challenge arriving already answered isn't announced as answered.
        var replaced = after
        replaced.entry.challenge = Challenge(
            challengeId: "c2", message: "Another?", sentAt: sent.addingTimeInterval(120),
            answer: ChallengeAnswer(answeredAt: sent, confirmation: "Yes"))
        #expect(QuestChange.between(before, replaced).contains(.challengeAnswered) == false)
    }

    func standing(_ id: String, _ rank: Int?) -> Standing {
        Standing(
            id: id, displayName: id, isTeam: true, status: rank == nil ? .inProgress : .completed,
            statusDescription: "", paused: false, rank: rank, started: true,
            clock: QuestClock(running: false, clockStart: nil, elapsedMs: 0, penaltyMs: 0, totalMs: 0))
    }

    @Test("Rivals finishing and the final result are announced, but not the player's own finish")
    func standings() {
        let before = Standings(
            provisional: true, rivalsHidden: false,
            entries: [standing("own", 1), standing("reds", nil), standing("blues", nil)])
        let middle = Standings(
            provisional: true, rivalsHidden: false,
            entries: [standing("own", 1), standing("reds", 2), standing("blues", nil)])
        let after = Standings(
            provisional: false, rivalsHidden: false,
            entries: [standing("blues", 1), standing("own", 2), standing("reds", 3)])
        #expect(QuestChange.between(before, before, ownEntryId: "own") == [])
        #expect(
            QuestChange.between(before, middle, ownEntryId: "own")
                == [.rivalFinished(standing("reds", 2), rank: 2)])
        #expect(
            QuestChange.between(middle, after, ownEntryId: "own")
                == [.rivalFinished(standing("blues", 1), rank: 1), .standingsFinal(winners: [standing("blues", 1)])])
    }
}

/// The API as the quest screen uses it: each answer for the quest in turn
/// (repeating the last), standings likewise, and live tickets.
final class QuestServer: Sendable {
    let transport: FakeTransport

    init(
        quests: [String], standings: [String] = [], answers: [HTTPAnswer] = [],
        fails: Bool = false
    ) {
        let quests = Shared(quests)
        let standings = Shared(standings)
        let answers = Shared(answers)
        transport = FakeTransport { operation in
            switch operation {
            case "answerChallenge":
                return answers.withLock { $0.removeFirst() }
            case "getQuest":
                if fails { throw URLError(.notConnectedToInternet) }
                let next = quests.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
                return next == "404" ? problem(404, "about:blank") : json(200, next)
            case "getSpectatorQuest":
                return json(200, standings.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] })
            case "createLiveTicket":
                return json(201, #"{"ticket":"ticket","expiresAt":"2026-11-11T16:00:00.000Z"}"#)
            default:
                return json(500, "{}")
            }
        }
    }

    func count(_ operation: String) -> Int {
        transport.requests.filter { $0.operationID == operation }.count
    }
}

@MainActor
@Suite("The quest screen's model")
struct QuestModelTests {
    let connector = FakeLiveSocketConnector()

    private func model(
        _ server: QuestServer, seen: any MessagesSeen = InMemoryMessagesSeen()
    ) -> QuestModel {
        QuestModel(
            questName: "harbor", api: api(server.transport, tokens: InMemoryTokenStore(token: "t")),
            connector: connector, messagesSeen: seen, configure: { $0.wait = { _ in } })
    }

    @Test("New messages are shown once on this phone, newest first, and put away when dismissed")
    func messagesShownOnce() async {
        let messages = [messageJSON("Welcome!", at: 1), messageJSON("Hurry!", at: 2)]
        let server = QuestServer(quests: [
            playerQuestJSON([stopJSON("quay")]),
            playerQuestJSON([stopJSON("quay")], messages: messages),
            playerQuestJSON([stopJSON("quay")], messages: messages),
        ])
        let seen = InMemoryMessagesSeen()
        let quest = model(server, seen: seen)
        await quest.load()
        #expect(quest.messageSheet == nil)

        await quest.load()
        #expect(quest.messageSheet?.messages.map(\.text) == ["Hurry!", "Welcome!"])
        #expect(quest.messageSheet?.showsChallenge == false)
        quest.dismissMessages()
        #expect(quest.messageSheet == nil)

        await quest.load()
        #expect(quest.messageSheet == nil)
        // Nor on opening the quest again.
        let again = model(QuestServer(quests: [playerQuestJSON([stopJSON("quay")], messages: messages)]), seen: seen)
        await again.load()
        #expect(again.messageSheet == nil)
    }

    @Test("A message arriving while others are shown joins them")
    func messageJoinsTheSheet() async {
        let server = QuestServer(quests: [
            playerQuestJSON([stopJSON("quay")], messages: [messageJSON("Welcome!", at: 1)]),
            playerQuestJSON(
                [stopJSON("quay")], messages: [messageJSON("Welcome!", at: 1), messageJSON("Hurry!", at: 2)]),
        ])
        let quest = model(server)
        await quest.load()
        await quest.load()
        #expect(quest.messageSheet?.messages.map(\.text) == ["Hurry!", "Welcome!"])
    }

    @Test("A new challenge is shown to answer; once put away, it can be reopened, answered or not")
    func challengeSheet() async {
        let waiting = playerQuestJSON(
            [stopJSON("quay")], messages: [messageJSON("Riddle?", at: 10, challenge: true)],
            challenge: challengeJSON("Riddle?"))
        let answered = playerQuestJSON(
            [stopJSON("quay")], messages: [messageJSON("Riddle?", at: 10, challenge: true)],
            challenge: challengeJSON("Riddle?", answeredVia: "app"))
        let server = QuestServer(
            quests: [waiting, answered],
            answers: [json(200, #"{"confirmation":"Show this to the bartender","answeredAt":"2026-11-11T16:20:00.000Z"}"#)])
        let quest = model(server)
        await quest.load()
        #expect(quest.messageSheet?.showsChallenge == true)

        // Answered in the sheet, which stays, showing the confirmation.
        #expect(await quest.answerChallenge("lighthouse"))
        #expect(quest.messageSheet?.showsChallenge == true)
        #expect(quest.quest?.entry.challenge?.answer != nil)

        quest.dismissMessages()
        #expect(quest.messageSheet == nil)
        quest.showChallenge()
        #expect(quest.messageSheet == MessageSheet(messages: [], showsChallenge: true))
        quest.dismissMessages()
    }

    @Test("Nothing reopens when there's no challenge")
    func noChallengeToShow() async {
        let quest = model(QuestServer(quests: [playerQuestJSON([stopJSON("quay")])]))
        await quest.load()
        quest.showChallenge()
        #expect(quest.messageSheet == nil)
    }

    @Test("It loads the quest; a failed first fetch is reported; a failed refresh keeps what's shown")
    func loads() async {
        let server = QuestServer(quests: [playerQuestJSON([stopJSON("quay")]), "not JSON"])
        let quest = model(server)
        #expect(quest.quest == nil)
        await quest.load()
        #expect(quest.quest?.entry.currentStop?.puzzleName == "quay")
        #expect(!quest.loadFailed)

        await quest.load()
        #expect(quest.loadFailed)
        #expect(quest.quest?.entry.currentStop?.puzzleName == "quay")

        let offline = model(QuestServer(quests: [""], fails: true))
        await offline.load()
        #expect(offline.loadFailed)
        #expect(offline.quest == nil)
        #expect(!offline.notAvailable)
    }

    @Test("A quest reset while on screen becomes not available")
    func reset() async {
        let quest = model(QuestServer(quests: [playerQuestJSON([stopJSON("quay")]), "404"]))
        await quest.load()
        await quest.load()
        #expect(quest.notAvailable)
        #expect(quest.quest == nil)
        #expect(!quest.loadFailed)
    }

    @Test("Live updates about the quest fetch it again, and what changed is reported once")
    func followsLiveUpdates() async throws {
        let server = QuestServer(quests: [
            playerQuestJSON([stopJSON("quay")]),
            // On connecting: nothing new.
            playerQuestJSON([stopJSON("quay")]),
            // Solved, and on to the next.
            playerQuestJSON([
                stopJSON("quay", status: "completed", solution: "ANCHOR"),
                stopJSON("customs", status: "awaitingActivation"),
            ]),
        ])
        let quest = model(server)
        await quest.load()
        let following = Task { await quest.followLiveUpdates() }
        defer { following.cancel() }

        let socket = try await connector.socket(0)
        #expect(try JSONDecoder().decode([String: String].self, from: Data(socket.sent[0].utf8))["questName"] == "harbor")
        socket.deliver(#"{"message":"connection","connectionId":"c1"}"#)
        try await eventually("live") { quest.isLive }
        #expect(quest.changeCount == 0)

        // About another quest: ignored.
        socket.deliver(#"{"message":"questUpdated","questName":"other","entryId":"e9"}"#)
        socket.deliver(
            #"{"message":"puzzleSolved","questName":"harbor","entryId":"e1","puzzleName":"quay","solutionText":"ANCHOR","endTime":"2026-11-11T16:10:00.000Z","questComplete":false}"#)
        try await eventually("solved") { quest.changeCount == 1 }
        #expect(server.count("getQuest") == 3)
        #expect(
            quest.changes == [
                .stopSolved(displayName: "The quay"), .stopReached(number: 2, displayName: "The customs"),
            ])
        // Not finished, so no standings asked for.
        #expect(server.count("getSpectatorQuest") == 0)
    }

    @Test("A wrong answer to the challenge is explained; a right one shows the confirmation")
    func answersTheChallenge() async {
        let waiting = playerQuestJSON([stopJSON("quay")], challenge: challengeJSON())
        let server = QuestServer(
            quests: [waiting, waiting, playerQuestJSON([stopJSON("quay")], challenge: challengeJSON(answeredVia: "app"))],
            answers: [
                problem(422, Problem.Types.wrongAnswer),
                json(200, #"{"confirmation":"Show this to the bartender","answeredAt":"2026-11-11T16:20:00.000Z"}"#),
            ])
        let quest = model(server)
        await quest.load()

        #expect(await quest.answerChallenge("an organ") == false)
        #expect(quest.challengeError == .wrongAnswer)
        #expect(!quest.answeringChallenge)

        #expect(await quest.answerChallenge("the lighthouse"))
        #expect(quest.challengeError == nil)
        #expect(quest.quest?.entry.challenge?.answer?.confirmation == "Show this to the bartender")
        // The quest is fetched again after each answer.
        #expect(server.count("getQuest") == 3)
        let sent = server.transport.requests.filter { $0.operationID == "answerChallenge" }
        #expect(sent.map(\.request.path) == ["/quests/harbor/challenge/answers", "/quests/harbor/challenge/answers"])
        #expect(sent.last?.body?.contains("the lighthouse") == true)
    }

    @Test("A challenge a teammate answered first is explained, and so are other refusals")
    func challengeRefusals() async {
        let cases: [(HTTPAnswer, ChallengeAnswerError)] = [
            (problem(409, Problem.Types.wrongState), .changed),
            (problem(403, "/problems/forbidden"), .changed),
            (problem(429, Problem.Types.tooManyRequests), .tooManyAttempts),
            (problem(500, Problem.Types.unexpected), .unexpected),
        ]
        for (answer, expected) in cases {
            let quest = model(QuestServer(quests: [playerQuestJSON([stopJSON("quay")])], answers: [answer]))
            #expect(await quest.answerChallenge("x") == false)
            #expect(quest.challengeError == expected)
            quest.clearChallengeError()
            #expect(quest.challengeError == nil)
        }
    }

    @Test("The puzzle master's messages and answered challenges arrive as live updates")
    func messagesArriveLive() async throws {
        let server = QuestServer(quests: [
            playerQuestJSON([stopJSON("quay")]),
            playerQuestJSON([stopJSON("quay")]),
            playerQuestJSON(
                [stopJSON("quay")], messages: [messageJSON("Riddle?", at: 10, challenge: true)],
                challenge: challengeJSON("Riddle?")),
            playerQuestJSON(
                [stopJSON("quay")], messages: [messageJSON("Riddle?", at: 10, challenge: true)],
                challenge: challengeJSON("Riddle?", answeredVia: "sms")),
        ])
        let quest = model(server)
        await quest.load()
        let following = Task { await quest.followLiveUpdates() }
        defer { following.cancel() }
        let socket = try await connector.socket(0)
        socket.deliver(#"{"message":"connection","connectionId":"c1"}"#)
        try await eventually("live") { quest.isLive }

        socket.deliver(#"{"message":"messageSent","questName":"harbor","entryId":"e1"}"#)
        try await eventually("message") { quest.changeCount == 1 }
        #expect(quest.changes == [.messageReceived(text: "Riddle?", isChallenge: true)])

        socket.deliver(#"{"message":"challengeAnswered","questName":"harbor","entryId":"e1"}"#)
        try await eventually("answered") { quest.changeCount == 2 }
        #expect(quest.changes == [.challengeAnswered])
        #expect(quest.quest?.entry.challenge?.answer?.byText == true)
    }

    @Test("Once finished, a race's standings are shown, and rivals finishing are announced")
    func standings() async throws {
        let finished = playerQuestJSON(
            [stopJSON("quay", status: "completed")], status: "completed")
        let server = QuestServer(
            quests: [finished],
            standings: [
                standingsJSON(
                    [standingJSON("e1", name: "Pat", rank: 1), standingJSON("e2", name: "Reds", rank: nil, status: "inProgress")],
                    provisional: true),
                standingsJSON(
                    [standingJSON("e1", name: "Pat", rank: 1), standingJSON("e2", name: "Reds", rank: 2)],
                    provisional: false),
            ])
        let quest = model(server)
        await quest.load()
        #expect(quest.standings?.provisional == true)
        #expect(quest.changeCount == 0)

        await quest.load()
        #expect(quest.standings?.isFinal == true)
        #expect(quest.changeCount == 1)
        #expect(quest.changes.count == 2)
        guard case .rivalFinished(let rival, rank: 2) = quest.changes.first else {
            Issue.record("expected the Reds' finish, got \(quest.changes)")
            return
        }
        #expect(rival.displayName == "Reds")
    }

    @Test("A quest played alone has no standings")
    func soloHasNoStandings() async {
        let server = QuestServer(
            quests: [playerQuestJSON([stopJSON("quay", status: "completed")], status: "completed")],
            standings: [standingsJSON([standingJSON("e1", name: "Pat", rank: 1)], provisional: false)])
        let quest = model(server)
        await quest.load()
        #expect(quest.quest?.entry.isFinished == true)
        #expect(quest.standings == nil)
    }
}

@Suite("Remembering which messages were shown")
struct MessagesSeenTests {
    @Test("UserDefaults keeps them per entry, across instances")
    func userDefaults() throws {
        let suite = "PuzzleQuestKitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let seen = UserDefaultsMessagesSeen(defaults: defaults)
        #expect(seen.seen(entryId: "e1").isEmpty)
        seen.markSeen(["a", "b"], entryId: "e1")
        seen.markSeen(["c"], entryId: "e1")
        #expect(UserDefaultsMessagesSeen(defaults: defaults).seen(entryId: "e1") == ["a", "b", "c"])
        #expect(seen.seen(entryId: "e2").isEmpty)
    }
}

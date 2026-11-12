import Foundation
import Testing

@testable import PuzzleQuestKit

/// A puzzle as the API sends it to its player.
func playerPuzzleJSON(
    _ name: String = "quay", status: String = "inProgress", type: String? = "text",
    text: String? = "What has keys?", hints: [(String, Int)] = [],
    nextHint: (penalty: Int, warning: Bool)? = nil, solution: String? = nil,
    skipped: Bool = false, next: String? = nil, paused: Bool = false,
    questStatus: String = "inProgress"
) -> String {
    let activated = status != "awaitingActivation"
    let typeField = activated ? type.map { #""\#($0)""# } ?? "null" : "null"
    let textField = activated ? text.map { #""\#($0)""# } ?? "null" : "null"
    let hintsField = hints.map { #"{"text":"\#($0.0)","timePenaltySeconds":\#($0.1)}"# }
        .joined(separator: ",")
    let nextHintField =
        nextHint.map { #"{"timePenaltySeconds":\#($0.penalty),"solutionWarning":\#($0.warning)}"# }
        ?? "null"
    let solutionField = solution.map { #""\#($0)""# } ?? "null"
    let nextField = next.map { #"{"puzzleName":"\#($0)","displayName":"The \#($0)"}"# } ?? "null"
    let progress = clockJSON(elapsedMs: 600_000, penaltyMs: 60_000).dropLast() + #","puzzles":[]}"#
    return #"""
        {"quest":{"questName":"harbor","displayName":"Harbor walk","status":"\#(questStatus)",
          "statusDescription":"In progress","paused":\#(paused),"progress":\#(progress)},
         "puzzle":{"puzzleName":"\#(name)","displayName":"The \#(name)","status":"\#(status)",
          "statusDescription":"In progress","skipped":\#(skipped),"stopNumber":2,
          "type":\#(typeField),"text":\#(textField),"hints":[\#(hintsField)],
          "nextHint":\#(nextHintField),"solutionText":\#(solutionField)},
         "next":\#(nextField)}
        """#
}

/// Answers the puzzle screen's calls: each fetch of the puzzle with the next
/// of `puzzles` (the last one over and over), and each action as told.
final class PuzzleServer: Sendable {
    let transport: FakeTransport

    /// - Parameters:
    ///   - puzzles: each fetch's answer: JSON, or "404".
    ///   - actions: for each operation, its answers in turn: "ok", a problem
    ///     type, or "offline".
    init(puzzles: [String], actions: [String: [String]] = [:]) {
        let puzzles = Shared(puzzles)
        let actionAnswers = Shared(actions)
        transport = FakeTransport { operation in
            switch operation {
            case "getPlayerPuzzle":
                let next = puzzles.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
                return next == "404" ? problem(404, "/problems/not-found") : json(200, next)
            case "createLiveTicket":
                return json(201, #"{"ticket":"ticket","expiresAt":"2026-11-11T16:00:00.000Z"}"#)
            case "activatePuzzle", "attemptSolution", "revealHint":
                let answer = actionAnswers.withLock { answers in
                    answers[operation].map { $0.count > 1 ? answers[operation]!.removeFirst() : $0[0] }
                        ?? "ok"
                }
                switch answer {
                case "ok":
                    return switch operation {
                    case "activatePuzzle":
                        json(200, #"{"activationTime":"2026-11-11T16:05:00.000Z"}"#)
                    case "attemptSolution":
                        json(200, #"{"solutionText":"A piano","nextPuzzle":null,"questComplete":false}"#)
                    default:
                        json(200, #"{"text":"Look up","timePenaltySeconds":60,"nextHint":null}"#)
                    }
                case "offline":
                    throw URLError(.notConnectedToInternet)
                default:
                    let status =
                        switch answer {
                        case "/problems/wrong-answer", "/problems/wrong-activation-code": 422
                        case "/problems/too-many-requests": 429
                        default: 409
                        }
                    return problem(status, answer)
                }
            default:
                return json(500, "{}")
            }
        }
    }

    func count(_ operation: String) -> Int {
        transport.requests.filter { $0.operationID == operation }.count
    }

    /// What was sent to an operation, as JSON fields.
    func sent(_ operation: String) -> [[String: String]] {
        transport.requests.filter { $0.operationID == operation }.compactMap { request in
            request.body.flatMap {
                try? JSONDecoder().decode([String: String].self, from: Data($0.utf8))
            }
        }
    }
}

@Suite("Reading a player's puzzle")
struct PlayerPuzzleTests {
    @Test("A puzzle being solved, with its text, hints, and what the next hint costs")
    func inProgress() async throws {
        let server = PuzzleServer(puzzles: [
            playerPuzzleJSON(hints: [("Look up", 60)], nextHint: (300, true))
        ])
        let puzzle = try #require(
            try await api(server.transport).playerPuzzle(questName: "harbor", puzzleName: "quay"))
        #expect(puzzle.questDisplayName == "Harbor walk")
        #expect(puzzle.stopNumber == 2)
        #expect(puzzle.status == .inProgress)
        #expect(puzzle.content == .text("What has keys?"))
        #expect(puzzle.hints == [RevealedHint(text: "Look up", penaltySeconds: 60)])
        #expect(puzzle.nextHint == NextHint(penaltySeconds: 300, givesSolutionAway: true))
        #expect(puzzle.clock.totalMs == 660_000)
        #expect(!puzzle.questFinished)
    }

    @Test("Before it's activated it shows nothing of the puzzle")
    func awaitingActivation() async throws {
        let server = PuzzleServer(puzzles: [playerPuzzleJSON(status: "awaitingActivation")])
        let puzzle = try #require(
            try await api(server.transport).playerPuzzle(questName: "harbor", puzzleName: "quay"))
        #expect(puzzle.status == .awaitingActivation)
        #expect(puzzle.content == nil)
    }

    @Test("Media is on the site, at the path the puzzle names")
    func media() async throws {
        let server = PuzzleServer(puzzles: [
            playerPuzzleJSON(type: "image", text: "/puzzleData/map.png")
        ])
        let puzzle = try await api(server.transport).playerPuzzle(
            questName: "harbor", puzzleName: "quay")
        #expect(puzzle?.content == .image(URL(string: "https://example.com/puzzleData/map.png")!))
    }

    @Test("A puzzle the player can't see is nil: not reached, or the quest was reset")
    func notFound() async throws {
        let server = PuzzleServer(puzzles: ["404"])
        let puzzle = try await api(server.transport).playerPuzzle(
            questName: "harbor", puzzleName: "quay")
        #expect(puzzle == nil)
    }

    @Test("Changes are what a player would see happen")
    func changes() async throws {
        func read(_ json: String) async throws -> PlayerPuzzle {
            try #require(
                try await api(PuzzleServer(puzzles: [json]).transport).playerPuzzle(
                    questName: "harbor", puzzleName: "quay"))
        }
        let waiting = try await read(playerPuzzleJSON(status: "awaitingActivation"))
        let started = try await read(playerPuzzleJSON())
        let hinted = try await read(playerPuzzleJSON(hints: [("Look up", 60)], paused: true))
        let solved = try await read(
            playerPuzzleJSON(
                status: "completed", hints: [("Look up", 60)], solution: "A piano",
                questStatus: "completed"))
        let skipped = try await read(playerPuzzleJSON(status: "completed", skipped: true))
        #expect(PuzzleChange.between(waiting, started) == [.started])
        #expect(PuzzleChange.between(started, hinted) == [.paused, .hintRevealed("Look up")])
        #expect(PuzzleChange.between(hinted, solved) == [.resumed, .solved(solution: "A piano"), .questFinished])
        #expect(PuzzleChange.between(started, skipped) == [.skipped])
        #expect(PuzzleChange.between(started, started).isEmpty)
    }

    @Test("Refusals are told apart by their problem types")
    func actionErrors() {
        func error(_ type: String, _ status: Int = 409) -> PuzzleActionError {
            PuzzleActionError(.problem(Problem(type: type, status: status, title: "")))
        }
        #expect(error("/problems/wrong-answer", 422) == .wrongAnswer)
        #expect(error("/problems/wrong-activation-code", 422) == .wrongCode)
        #expect(error("/problems/quest-paused") == .paused)
        #expect(error("/problems/too-many-requests", 429) == .tooManyAttempts)
        #expect(error("/problems/no-more-hints") == .noMoreHints)
        #expect(error("/problems/wrong-state") == .changed)
        #expect(error("/problems/not-found", 404) == .changed)
        #expect(error("/problems/try-again") == .tryAgain)
        #expect(error("/problems/something-new") == .unexpected)
        #expect(PuzzleActionError(.unreachable) == .unreachable)
    }
}

@MainActor
@Suite("The puzzle screen's model")
struct PuzzleModelTests {
    let connector = FakeLiveSocketConnector()

    private func model(_ server: PuzzleServer) -> PuzzleModel {
        let model = PuzzleModel(
            questName: "harbor", puzzleName: "quay",
            api: api(server.transport, tokens: InMemoryTokenStore(token: "t")),
            connector: connector, configure: { $0.wait = { _ in } })
        model.retryAfterNoAnswer = .zero
        return model
    }

    @Test("Activating sends the code, then fetches the puzzle again, and what changed is reported")
    func activates() async {
        let server = PuzzleServer(puzzles: [
            playerPuzzleJSON(status: "awaitingActivation"), playerPuzzleJSON(),
        ])
        let puzzle = model(server)
        await puzzle.load()
        #expect(puzzle.puzzle?.status == .awaitingActivation)

        await puzzle.activate(code: "abc123")
        #expect(server.sent("activatePuzzle").first?["activationCode"] == "abc123")
        #expect(puzzle.puzzle?.status == .inProgress)
        #expect(puzzle.pending == nil)
        #expect(puzzle.actionError == nil)
        #expect(puzzle.changes == [.started])
    }

    @Test("A wrong code or answer says so, and the puzzle is fetched again anyway")
    func wrong() async {
        let server = PuzzleServer(
            puzzles: [playerPuzzleJSON()],
            actions: ["attemptSolution": ["/problems/wrong-answer", "ok"]])
        let puzzle = model(server)
        await puzzle.load()
        #expect(await puzzle.solve(guess: "organ") == false)
        #expect(puzzle.actionError == .wrongAnswer)
        #expect(server.count("getPlayerPuzzle") == 2)

        // The next try starts afresh.
        #expect(await puzzle.solve(guess: "piano") == true)
        #expect(puzzle.actionError == nil)
    }

    @Test("A code left in front of the camera is sent once, or again if the server didn't answer")
    func scanning() async {
        let server = PuzzleServer(
            puzzles: [playerPuzzleJSON(status: "awaitingActivation")],
            actions: ["activatePuzzle": ["/problems/wrong-activation-code", "offline", "offline"]])
        let puzzle = model(server)
        await puzzle.load()

        await puzzle.scanned(code: "WRONG")
        await puzzle.scanned(code: "WRONG")
        #expect(server.count("activatePuzzle") == 1)
        #expect(puzzle.actionError == .wrongCode)

        // Another code is sent; with no answer, it may be sent again.
        await puzzle.scanned(code: "RIGHT")
        #expect(puzzle.actionError == .unreachable)
        await puzzle.scanned(code: "RIGHT")
        #expect(server.count("activatePuzzle") == 3)
    }

    @Test("Revealing a hint asks the server, and the hint is reported")
    func hint() async {
        let server = PuzzleServer(puzzles: [
            playerPuzzleJSON(nextHint: (60, false)),
            playerPuzzleJSON(hints: [("Look up", 60)]),
        ])
        let puzzle = model(server)
        await puzzle.load()
        await puzzle.revealHint()
        #expect(server.count("revealHint") == 1)
        #expect(puzzle.puzzle?.hints.count == 1)
        #expect(puzzle.changes == [.hintRevealed("Look up")])
    }

    @Test("Actions name the live-update connection, so their updates aren't sent back")
    func connectionId() async throws {
        let server = PuzzleServer(puzzles: [playerPuzzleJSON(status: "awaitingActivation")])
        let puzzle = model(server)
        await puzzle.load()
        let following = Task { await puzzle.followLiveUpdates() }
        defer { following.cancel() }
        let socket = try await connector.socket(0)
        socket.deliver(#"{"message":"connection","connectionId":"c1"}"#)
        try await eventually("live") { puzzle.isLive }

        await puzzle.activate(code: "abc123")
        #expect(server.sent("activatePuzzle").first?["connectionId"] == "c1")
    }

    @Test("Live updates about the quest fetch the puzzle again")
    func followsLiveUpdates() async throws {
        let server = PuzzleServer(puzzles: [
            playerPuzzleJSON(), playerPuzzleJSON(),
            playerPuzzleJSON(status: "completed", solution: "A piano", next: "customs"),
        ])
        let puzzle = model(server)
        await puzzle.load()
        let following = Task { await puzzle.followLiveUpdates() }
        defer { following.cancel() }
        let socket = try await connector.socket(0)
        socket.deliver(#"{"message":"connection","connectionId":"c1"}"#)
        try await eventually("live") { puzzle.isLive }

        socket.deliver(
            #"{"message":"puzzleSolved","questName":"harbor","entryId":"e1","puzzleName":"quay","solutionText":"A piano","endTime":"2026-11-11T16:10:00.000Z","questComplete":false}"#)
        try await eventually("solved") { puzzle.changeCount == 1 }
        #expect(puzzle.changes == [.solved(solution: "A piano")])
        #expect(puzzle.puzzle?.next?.puzzleName == "customs")
    }

    @Test("Going to the next stop shows its puzzle, without the last one's message")
    func nextStop() async {
        let server = PuzzleServer(
            puzzles: [
                playerPuzzleJSON(),
                playerPuzzleJSON(status: "completed", solution: "A piano", next: "customs"),
                playerPuzzleJSON("customs", status: "awaitingActivation"),
            ],
            actions: ["attemptSolution": ["/problems/wrong-state"]])
        let puzzle = model(server)
        await puzzle.load()
        // A teammate solved it first.
        await puzzle.solve(guess: "piano")
        #expect(puzzle.actionError == .changed)
        #expect(puzzle.puzzle?.status == .completed)

        await puzzle.goToNextStop()
        #expect(puzzle.puzzleName == "customs")
        #expect(puzzle.puzzle?.puzzleName == "customs")
        #expect(puzzle.actionError == nil)
        // A new puzzle: nothing changed on screen to announce.
        #expect(puzzle.changeCount == 1)
    }

    @Test("A puzzle reset while on screen becomes not available")
    func reset() async {
        let puzzle = model(PuzzleServer(puzzles: [playerPuzzleJSON(), "404"]))
        await puzzle.load()
        await puzzle.load()
        #expect(puzzle.notAvailable)
        #expect(puzzle.puzzle == nil)
    }
}

@Suite("Reading a text puzzle's Markdown")
struct PuzzleMarkdownTests {
    let server = URL(string: "https://example.com")!

    private func blocks(_ markdown: String) -> [MarkdownBlock] {
        MarkdownBlock.blocks(from: markdown, server: server)
    }

    @Test("Headings, paragraphs, and emphasis")
    func text() throws {
        let read = blocks("# The quay\n\nFind the *red* **door**,\nthen `knock`.")
        #expect(read.count == 2)
        #expect(read[0] == .heading(level: 1, AttributedString("The quay")))
        guard case .paragraph(let paragraph) = read[1] else {
            Issue.record("expected a paragraph, got \(read[1])")
            return
        }
        // A line break within a paragraph is a space, as on the web.
        #expect(String(paragraph.characters) == "Find the red door, then knock.")
        let red = try #require(paragraph.range(of: "red"))
        #expect(paragraph[red].inlinePresentationIntent == .emphasized)
        let door = try #require(paragraph.range(of: "door"))
        #expect(paragraph[door].inlinePresentationIntent == .stronglyEmphasized)
        let knock = try #require(paragraph.range(of: "knock"))
        #expect(paragraph[knock].inlinePresentationIntent == .code)
    }

    @Test("Lists, quotes, code, and rules")
    func structure() {
        let read = blocks("3. one\n4. two\n\n- [x] done\n\n> said\n\n```\nlet x\n```\n\n---")
        #expect(
            read == [
                .list(
                    ordered: true, start: 3,
                    items: [[.paragraph(AttributedString("one"))], [.paragraph(AttributedString("two"))]]),
                .list(ordered: false, start: 1, items: [[.paragraph(AttributedString("☑ done"))]]),
                .quote([.paragraph(AttributedString("said"))]),
                .code("let x"),
                .rule,
            ])
    }

    @Test("Tables, with their columns' alignment")
    func table() {
        let read = blocks("| Clue | Answer |\n|:--|--:|\n| A | 1 |")
        #expect(
            read == [
                .table(
                    MarkdownTable(
                        alignments: [.leading, .trailing],
                        header: [AttributedString("Clue"), AttributedString("Answer")],
                        rows: [[AttributedString("A"), AttributedString("1")]]))
            ])
    }

    @Test("Links and pictures are on the site unless they say otherwise; scripts aren't links")
    func addresses() throws {
        let read = blocks(
            "![A map](/puzzleData/map.png)\n\nSee [the site](https://example.org) or [this](javascript:alert(1)).")
        #expect(
            read.first
                == .images([
                    MarkdownImage(url: URL(string: "https://example.com/puzzleData/map.png")!, alt: "A map")
                ]))
        guard case .paragraph(let paragraph) = read.last else {
            Issue.record("expected a paragraph, got \(String(describing: read.last))")
            return
        }
        let site = try #require(paragraph.range(of: "the site"))
        #expect(paragraph[site].link == URL(string: "https://example.org"))
        let script = try #require(paragraph.range(of: "this"))
        #expect(paragraph[script].link == nil)
    }

    @Test("HTML shows as plain text")
    func html() {
        let read = blocks("<script>alert(1)</script>\n\nA <b>bold</b> claim")
        #expect(
            read == [
                .paragraph(AttributedString("<script>alert(1)</script>")),
                .paragraph(AttributedString("A <b>bold</b> claim")),
            ])
    }
}

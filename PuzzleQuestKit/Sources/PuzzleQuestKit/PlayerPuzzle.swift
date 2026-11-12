import Foundation
import PuzzleQuestAPI

/// A stop's puzzle as its players see it: waiting to be found and activated,
/// being solved, or solved. Like the quest, it never says how many stops
/// there are.
public struct PlayerPuzzle: Equatable, Sendable {
    public var questName: String
    public var questDisplayName: String
    /// The player's entry in the quest: whether it has finished, and its
    /// clock, with hint penalties.
    public var questStatus: QuestStatus
    /// True while the puzzle master has paused the quest: its clocks stop,
    /// and the players can't activate, guess, or reveal hints.
    public var paused: Bool
    public var clock: QuestClock

    public var puzzleName: String
    public var displayName: String
    public var status: StopStatus
    /// Which stop it is, from 1.
    public var stopNumber: Int
    /// True if the puzzle master skipped it for the players.
    public var skipped: Bool
    /// What it asks; nil until it's activated.
    public var content: PuzzleContent?
    /// The hints revealed so far, in order.
    public var hints: [RevealedHint]
    /// What the next hint would cost; nil if it isn't being solved, or has no
    /// more hints.
    public var nextHint: NextHint?
    /// The solution, once solved.
    public var solutionText: String?
    /// The stop after this one, once the players have reached it.
    public var next: NextStop?

    public init(
        questName: String, questDisplayName: String, questStatus: QuestStatus, paused: Bool,
        clock: QuestClock, puzzleName: String, displayName: String, status: StopStatus,
        stopNumber: Int, skipped: Bool = false, content: PuzzleContent? = nil,
        hints: [RevealedHint] = [], nextHint: NextHint? = nil, solutionText: String? = nil,
        next: NextStop? = nil
    ) {
        self.questName = questName
        self.questDisplayName = questDisplayName
        self.questStatus = questStatus
        self.paused = paused
        self.clock = clock
        self.puzzleName = puzzleName
        self.displayName = displayName
        self.status = status
        self.stopNumber = stopNumber
        self.skipped = skipped
        self.content = content
        self.hints = hints
        self.nextHint = nextHint
        self.solutionText = solutionText
        self.next = next
    }

    public var questFinished: Bool { questStatus == .completed }
}

/// What a puzzle shows.
public enum PuzzleContent: Equatable, Sendable {
    /// Text, as Markdown.
    case text(String)
    /// A picture, a recording, or a film, at its address on the server.
    case image(URL)
    case audio(URL)
    case video(URL)
}

public struct RevealedHint: Equatable, Sendable {
    public var text: String
    /// Seconds it added to the players' time.
    public var penaltySeconds: Int

    public init(text: String, penaltySeconds: Int) {
        self.text = text
        self.penaltySeconds = penaltySeconds
    }
}

/// What revealing a puzzle's next hint would cost.
public struct NextHint: Equatable, Sendable {
    /// Seconds it would add to the players' time.
    public var penaltySeconds: Int
    /// True if it gives the solution away, so the player is asked first.
    public var givesSolutionAway: Bool

    public init(penaltySeconds: Int, givesSolutionAway: Bool) {
        self.penaltySeconds = penaltySeconds
        self.givesSolutionAway = givesSolutionAway
    }
}

/// The stop after one just solved.
public struct NextStop: Equatable, Sendable {
    public var puzzleName: String
    public var displayName: String

    public init(puzzleName: String, displayName: String) {
        self.puzzleName = puzzleName
        self.displayName = displayName
    }
}

/// Something about a puzzle that changed while it was on screen, for telling
/// VoiceOver users what a sighted player sees happen, as the web app does.
public enum PuzzleChange: Equatable, Sendable {
    case paused
    case resumed
    /// Activated: what it asks is showing.
    case started
    case solved(solution: String?)
    case skipped
    case hintRevealed(String)
    case questFinished

    /// What changed between two views of a puzzle, in the order a player
    /// would read them.
    static func between(_ before: PlayerPuzzle, _ after: PlayerPuzzle) -> [PuzzleChange] {
        var changes: [PuzzleChange] = []
        if before.paused != after.paused {
            changes.append(after.paused ? .paused : .resumed)
        }
        if before.status == .awaitingActivation && after.status != .awaitingActivation {
            changes.append(.started)
        }
        if before.status != .completed && after.status == .completed {
            changes.append(after.skipped ? .skipped : .solved(solution: after.solutionText))
        }
        for hint in after.hints.dropFirst(before.hints.count) {
            changes.append(.hintRevealed(hint.text))
        }
        if after.questFinished && !before.questFinished {
            changes.append(.questFinished)
        }
        return changes
    }
}

// MARK: From the API's schemas

extension PlayerPuzzle {
    /// - Parameter server: the site, which media paths are on.
    init(_ view: Components.Schemas.PlayerPuzzle, server: URL) {
        let puzzle = view.puzzle
        self.init(
            questName: view.quest.questName,
            questDisplayName: view.quest.displayName,
            questStatus: QuestStatus(view.quest.status),
            paused: view.quest.paused,
            clock: QuestClock(view.quest.progress),
            puzzleName: puzzle.puzzleName,
            displayName: puzzle.displayName,
            status: StopStatus(puzzle.status),
            stopNumber: puzzle.stopNumber,
            skipped: puzzle.skipped,
            content: PuzzleContent(type: puzzle._type, text: puzzle.text, server: server),
            hints: puzzle.hints.map {
                RevealedHint(text: $0.text, penaltySeconds: $0.timePenaltySeconds)
            },
            nextHint: puzzle.nextHint.map(NextHint.init),
            solutionText: puzzle.solutionText,
            next: view.next.map { NextStop(puzzleName: $0.puzzleName, displayName: $0.displayName) })
    }
}

extension PuzzleContent {
    /// What a puzzle shows, or nil before it's activated, or if it's of a kind
    /// this version of the app doesn't know (version 1 may add kinds).
    init?(type: Components.Schemas.PuzzleType?, text: String?, server: URL) {
        guard let type = type?.value1, let text else { return nil }
        if type == .text {
            self = .text(text)
            return
        }
        // A path on the site, such as /puzzleData/…; resolved against it.
        guard let url = URL(string: text, relativeTo: server)?.absoluteURL else { return nil }
        switch type {
        case .image: self = .image(url)
        case .audio: self = .audio(url)
        case .video: self = .video(url)
        case .text: self = .text(text)
        }
    }
}

extension NextHint {
    init(_ hint: Components.Schemas.NextHint) {
        self.init(
            penaltySeconds: hint.timePenaltySeconds, givesSolutionAway: hint.solutionWarning)
    }
}

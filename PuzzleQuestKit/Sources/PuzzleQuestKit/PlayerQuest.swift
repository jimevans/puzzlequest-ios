import Foundation
import PuzzleQuestAPI

/// A quest as its player sees it: their own entry, and the stops it has
/// reached. Players never learn how many stops a quest has, so nothing here
/// says, and the stops are only those reached so far.
public struct PlayerQuest: Equatable, Sendable {
    public var questName: String
    public var displayName: String
    public var entry: QuestEntryProgress

    public init(questName: String, displayName: String, entry: QuestEntryProgress) {
        self.questName = questName
        self.displayName = displayName
        self.entry = entry
    }
}

/// Where a player's entry (theirs alone, or their team's) has got to.
public struct QuestEntryProgress: Equatable, Sendable {
    public var id: String
    /// Whether a team plays it, rather than one player.
    public var isTeam: Bool
    public var status: QuestStatus
    /// The status in the server's English words, for display.
    public var statusDescription: String
    /// True while the puzzle master has paused it; its clocks stop.
    public var paused: Bool
    public var startTime: Date?
    public var endTime: Date?
    /// The time on the whole quest, with hint penalties.
    public var clock: QuestClock
    /// The stops reached, in the order they were reached.
    public var stops: [Stop]
    /// The team's or player's display name; nil if it has been deleted.
    public var entrantName: String?
    /// What the puzzle master has sent the entry's players, oldest first.
    public var messages: [PuzzleMasterMessage]
    /// The challenge the puzzle master last sent, answered or not.
    public var challenge: Challenge?

    public init(
        id: String, isTeam: Bool, status: QuestStatus, statusDescription: String, paused: Bool,
        startTime: Date?, endTime: Date?, clock: QuestClock, stops: [Stop],
        entrantName: String? = nil, messages: [PuzzleMasterMessage] = [],
        challenge: Challenge? = nil
    ) {
        self.id = id
        self.isTeam = isTeam
        self.status = status
        self.statusDescription = statusDescription
        self.paused = paused
        self.startTime = startTime
        self.endTime = endTime
        self.clock = clock
        self.stops = stops
        self.entrantName = entrantName
        self.messages = messages
        self.challenge = challenge
    }

    /// The challenge waiting for the players to answer it, if any.
    public var waitingChallenge: Challenge? {
        challenge?.answer == nil ? challenge : nil
    }

    public var isFinished: Bool { status == .completed }

    /// The stop being played: reached, and not yet solved or skipped.
    public var currentStop: Stop? {
        stops.last { $0.status != .completed }
    }

    /// The stops solved (or skipped), the latest first.
    public var finishedStops: [Stop] {
        stops.filter { $0.status == .completed }.reversed()
    }
}

/// A stop the entry has reached: its puzzle, and how it went.
public struct Stop: Equatable, Identifiable, Sendable {
    /// Which stop it is, from 1, in the order reached.
    public var number: Int
    public var puzzleName: String
    public var displayName: String
    public var status: StopStatus
    /// The status in the server's English words, for display.
    public var statusDescription: String
    /// True if the puzzle master skipped it for the players.
    public var skipped: Bool
    /// When the stop was reached.
    public var startTime: Date?
    /// When the players found the puzzle and activated it.
    public var activationTime: Date?
    /// When it was solved or skipped.
    public var endTime: Date?
    /// The solution, once solved.
    public var solutionText: String?
    /// The time on this stop, with its hint penalties.
    public var clock: QuestClock?

    public var id: String { puzzleName }

    public init(
        number: Int, puzzleName: String, displayName: String, status: StopStatus,
        statusDescription: String, skipped: Bool = false, startTime: Date? = nil,
        activationTime: Date? = nil, endTime: Date? = nil, solutionText: String? = nil,
        clock: QuestClock? = nil
    ) {
        self.number = number
        self.puzzleName = puzzleName
        self.displayName = displayName
        self.status = status
        self.statusDescription = statusDescription
        self.skipped = skipped
        self.startTime = startTime
        self.activationTime = activationTime
        self.endTime = endTime
        self.solutionText = solutionText
        self.clock = clock
    }
}

/// A message the puzzle master sent the entry's players.
public struct PuzzleMasterMessage: Equatable, Identifiable, Sendable {
    public var text: String
    public var sentAt: Date
    /// True if it set a challenge for the players to answer.
    public var isChallenge: Bool

    /// Messages have no ID of their own; none is sent twice at one moment.
    public var id: String { "\(sentAt.timeIntervalSince1970) \(text)" }

    public init(text: String, sentAt: Date, isChallenge: Bool = false) {
        self.text = text
        self.sentAt = sentAt
        self.isChallenge = isChallenge
    }
}

/// A challenge from the puzzle master: a small puzzle the players answer, in
/// the app or by text. A right answer shows the confirmation, which they show
/// the venue's staff to be given what comes next.
public struct Challenge: Equatable, Sendable {
    public var challengeId: String
    public var message: String
    public var sentAt: Date
    /// The right answer, once a player has given it; nil while it waits.
    public var answer: ChallengeAnswer?

    /// Tells this sending apart from another of the same kept challenge,
    /// which the puzzle master may send again.
    public var id: String { "\(challengeId) \(sentAt.timeIntervalSince1970)" }

    /// Whether a message is the one that set this challenge.
    public func isSet(by message: PuzzleMasterMessage) -> Bool {
        message.isChallenge && message.sentAt == sentAt
    }

    public init(challengeId: String, message: String, sentAt: Date, answer: ChallengeAnswer? = nil) {
        self.challengeId = challengeId
        self.message = message
        self.sentAt = sentAt
        self.answer = answer
    }
}

/// How a challenge was answered.
public struct ChallengeAnswer: Equatable, Sendable {
    public var answeredAt: Date
    /// What to show the venue's staff.
    public var confirmation: String
    /// True if a player answered by text message, not in the app.
    public var byText: Bool

    public init(answeredAt: Date, confirmation: String, byText: Bool = false) {
        self.answeredAt = answeredAt
        self.confirmation = confirmation
        self.byText = byText
    }
}

/// Where a stop stands. Version 1 may add statuses, shown as `.other`.
public enum StopStatus: Hashable, Sendable {
    case notReached
    /// Reached: the players are looking for the puzzle, to activate it.
    case awaitingActivation
    /// Activated: the players are solving it.
    case inProgress
    /// Solved, or skipped.
    case completed
    case other(String)
}

/// A race's standings, as a player may see them once their own entry has
/// finished.
public struct Standings: Equatable, Sendable {
    /// True until every entry has finished: a later finisher could still beat
    /// these times.
    public var provisional: Bool
    /// True while the player's own entry is still racing, so the others are
    /// hidden from them.
    public var rivalsHidden: Bool
    /// In leaderboard order.
    public var entries: [Standing]

    public init(provisional: Bool, rivalsHidden: Bool, entries: [Standing]) {
        self.provisional = provisional
        self.rivalsHidden = rivalsHidden
        self.entries = entries
    }

    /// Whether the ranks are settled: every entry has finished.
    public var isFinal: Bool { !provisional }
}

/// One entry in the standings.
public struct Standing: Equatable, Identifiable, Sendable {
    public var id: String
    /// The team's or player's display name; nil if it has been deleted.
    public var displayName: String?
    public var isTeam: Bool
    public var status: QuestStatus
    public var statusDescription: String
    public var paused: Bool
    /// Its place once it has finished; nil until then.
    public var rank: Int?
    /// Whether it has started, so has a time to show.
    public var started: Bool
    public var clock: QuestClock

    public init(
        id: String, displayName: String?, isTeam: Bool, status: QuestStatus,
        statusDescription: String, paused: Bool, rank: Int?, started: Bool, clock: QuestClock
    ) {
        self.id = id
        self.displayName = displayName
        self.isTeam = isTeam
        self.status = status
        self.statusDescription = statusDescription
        self.paused = paused
        self.rank = rank
        self.started = started
        self.clock = clock
    }
}

/// Something about a quest that changed while it was on screen, for telling
/// VoiceOver users what a sighted player sees happen. The clocks counting up
/// aren't changes.
public enum QuestChange: Equatable, Sendable {
    case paused
    case resumed
    case stopReached(number: Int, displayName: String)
    case stopSolved(displayName: String)
    case finished
    /// Another entry in the race finished, in that place.
    case rivalFinished(Standing, rank: Int)
    /// Every entry has finished: these won (more than one if tied).
    case standingsFinal(winners: [Standing])
    /// The puzzle master sent a message, or a challenge.
    case messageReceived(text: String, isChallenge: Bool)
    /// A player answered the challenge rightly.
    case challengeAnswered

    /// What changed between two views of a quest, in the order a player
    /// would read them.
    static func between(
        _ before: PlayerQuest, _ after: PlayerQuest
    ) -> [QuestChange] {
        var changes: [QuestChange] = []
        if before.entry.paused != after.entry.paused {
            changes.append(after.entry.paused ? .paused : .resumed)
        }
        for stop in after.entry.stops {
            let earlier = before.entry.stops.first { $0.puzzleName == stop.puzzleName }
            if earlier == nil {
                changes.append(.stopReached(number: stop.number, displayName: stop.displayName))
            } else if stop.status == .completed && earlier?.status != .completed {
                changes.append(.stopSolved(displayName: stop.displayName))
            }
        }
        if after.entry.isFinished && !before.entry.isFinished {
            changes.append(.finished)
        }
        let known = Set(before.entry.messages.map(\.id))
        for message in after.entry.messages where !known.contains(message.id) {
            changes.append(.messageReceived(text: message.text, isChallenge: message.isChallenge))
        }
        // The same challenge, waiting before and answered now.
        if let waiting = before.entry.challenge, waiting.answer == nil,
            let answered = after.entry.challenge, answered.answer != nil,
            answered.challengeId == waiting.challengeId, answered.sentAt == waiting.sentAt
        {
            changes.append(.challengeAnswered)
        }
        return changes
    }

    /// What changed in the standings, leaving out the player's own entry
    /// (whose finishing is announced as the quest's).
    static func between(
        _ before: Standings, _ after: Standings, ownEntryId: String
    ) -> [QuestChange] {
        var changes: [QuestChange] = []
        for entry in after.entries where entry.id != ownEntryId {
            guard let rank = entry.rank else { continue }
            if before.entries.first(where: { $0.id == entry.id })?.rank == nil {
                changes.append(.rivalFinished(entry, rank: rank))
            }
        }
        if after.isFinal && !before.isFinal {
            changes.append(
                .standingsFinal(
                    winners: after.entries.filter { $0.rank == 1 }))
        }
        return changes
    }
}

// MARK: From the API's schemas

extension PlayerQuest {
    /// The player's quest, or nil if it has no entry of theirs (as after the
    /// puzzle master resets it).
    init?(_ quest: Components.Schemas.Quest) {
        guard let entry = quest.entries.first else { return nil }
        self.init(
            questName: quest.questName, displayName: quest.displayName,
            entry: QuestEntryProgress(entry))
    }
}

extension QuestEntryProgress {
    init(_ entry: Components.Schemas.QuestEntry) {
        let clocks = Dictionary(
            entry.progress.puzzles.map { ($0.puzzleName, QuestClock($0)) },
            uniquingKeysWith: { first, _ in first })
        self.init(
            id: entry.id,
            isTeam: entry.entrant.kind.value1 == .team,
            status: QuestStatus(entry.status),
            statusDescription: entry.statusDescription,
            paused: entry.paused,
            startTime: entry.progress.startTime,
            endTime: entry.progress.endTime,
            clock: QuestClock(entry.progress),
            stops: entry.puzzles.enumerated().map { index, puzzle in
                Stop(
                    number: index + 1,
                    puzzleName: puzzle.puzzleName,
                    displayName: puzzle.displayName,
                    status: StopStatus(puzzle.status),
                    statusDescription: puzzle.statusDescription,
                    skipped: puzzle.skipped,
                    startTime: puzzle.startTime,
                    activationTime: puzzle.activationTime,
                    endTime: puzzle.endTime,
                    solutionText: puzzle.solutionText,
                    clock: clocks[puzzle.puzzleName])
            },
            entrantName: entry.entrant.displayName,
            messages: entry.messages.map {
                PuzzleMasterMessage(text: $0.text, sentAt: $0.sentAt, isChallenge: $0.challenge)
            },
            challenge: entry.challenge.map(Challenge.init))
    }
}

extension Challenge {
    init(_ challenge: Components.Schemas.EntryChallenge) {
        self.init(
            challengeId: challenge.challengeId, message: challenge.message,
            sentAt: challenge.sentAt,
            answer: challenge.answeredAt.map { answeredAt in
                ChallengeAnswer(
                    answeredAt: answeredAt,
                    // Players are shown it once it's answered.
                    confirmation: challenge.confirmation ?? "",
                    byText: challenge.answeredVia?.value1 == .sms)
            })
    }
}

extension Standings {
    init(_ quest: Components.Schemas.SpectatorQuest) {
        self.init(
            provisional: quest.provisional,
            rivalsHidden: quest.rivalsHidden,
            entries: quest.entries.map { entry in
                Standing(
                    id: entry.id,
                    displayName: entry.entrant.displayName,
                    isTeam: entry.entrant.kind.value1 == .team,
                    status: QuestStatus(entry.status),
                    statusDescription: entry.statusDescription,
                    paused: entry.paused,
                    rank: entry.rank,
                    started: entry.progress.startTime != nil,
                    clock: QuestClock(entry.progress))
            })
    }
}

extension StopStatus {
    init(_ status: Components.Schemas.StopStatus) {
        switch status.value1 {
        case .notReached: self = .notReached
        case .awaitingActivation: self = .awaitingActivation
        case .inProgress: self = .inProgress
        case .completed: self = .completed
        case nil: self = .other(status.value2 ?? "")
        }
    }
}

extension QuestClock {
    init(_ progress: Components.Schemas.Progress) {
        self.init(
            running: progress.running, clockStart: progress.clockStart,
            elapsedMs: progress.elapsedMs, penaltyMs: progress.penaltyMs,
            totalMs: progress.totalMs)
    }

    init(_ clock: Components.Schemas.PuzzleClock) {
        self.init(
            running: clock.running, clockStart: clock.clockStart, elapsedMs: clock.elapsedMs,
            penaltyMs: clock.penaltyMs, totalMs: clock.totalMs)
    }
}

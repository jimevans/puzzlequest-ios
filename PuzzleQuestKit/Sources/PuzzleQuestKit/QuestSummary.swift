import Foundation
import PuzzleQuestAPI

/// One of the quests a player plays, as their home screen lists it. It says
/// nothing about how many stops the quest has: players never learn that.
public struct QuestSummary: Equatable, Hashable, Identifiable, Sendable {
    public var questName: String
    public var displayName: String
    public var status: QuestStatus
    /// The status in the server's English words, for display.
    public var statusDescription: String
    /// True while the puzzle master has paused the player's entry; its clock
    /// stops, and its status stays in progress.
    public var paused: Bool
    /// The time spent on the quest.
    public var progress: QuestClock

    public var id: String { questName }

    public init(
        questName: String, displayName: String, status: QuestStatus,
        statusDescription: String, paused: Bool, progress: QuestClock
    ) {
        self.questName = questName
        self.displayName = displayName
        self.status = status
        self.statusDescription = statusDescription
        self.paused = paused
        self.progress = progress
    }
}

/// Where a quest stands. Version 1 may add statuses, which the app shows as
/// `.other` rather than failing.
public enum QuestStatus: Hashable, Sendable {
    case notStarted
    case inProgress
    case completed
    case other(String)
}

/// How long players have spent on a quest, as the API last reported it. While
/// it runs, the time is worked out from when it (in effect) started, so a
/// screen can count up without asking the server again.
public struct QuestClock: Hashable, Sendable {
    /// True while the clock runs: started, not stopped, and not paused.
    public var running: Bool
    /// While running, when the clock would have started had there been no
    /// pauses; nil while not running.
    public var clockStart: Date?
    /// Milliseconds on the clock as of the response, leaving out paused time.
    public var elapsedMs: Int
    /// The revealed hints' time penalties, in milliseconds.
    public var penaltyMs: Int
    /// Elapsed time plus penalties, as of the response: the score.
    public var totalMs: Int

    public init(running: Bool, clockStart: Date?, elapsedMs: Int, penaltyMs: Int, totalMs: Int) {
        self.running = running
        self.clockStart = clockStart
        self.elapsedMs = elapsedMs
        self.penaltyMs = penaltyMs
        self.totalMs = totalMs
    }

    /// Whether the time changes from moment to moment, so needs redrawing.
    public var isCounting: Bool { running && clockStart != nil }

    /// The time spent at a moment, not counting penalties, in milliseconds.
    public func elapsedMs(at now: Date) -> Int {
        guard running, let clockStart else { return elapsedMs }
        return Int((now.timeIntervalSince(clockStart) * 1000).rounded(.down))
    }

    /// The players' score at a moment: the time spent plus penalties, in
    /// milliseconds.
    public func totalMs(at now: Date) -> Int {
        guard isCounting else { return totalMs }
        return elapsedMs(at: now) + penaltyMs
    }

    /// A length of time as a clock shows it, such as 4:05 or 1:04:05. A
    /// negative time (a phone whose clock is behind the server's) shows as
    /// 0:00.
    public static func format(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        let minutes = seconds / 60
        let hours = minutes / 60
        let twoDigits = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return hours > 0
            ? "\(hours):\(twoDigits(minutes % 60)):\(twoDigits(seconds % 60))"
            : "\(minutes):\(twoDigits(seconds % 60))"
    }
}

extension QuestSummary {
    init(_ summary: Components.Schemas.QuestSummary) {
        self.init(
            questName: summary.questName,
            displayName: summary.displayName,
            status: QuestStatus(summary.status),
            statusDescription: summary.statusDescription,
            paused: summary.paused,
            progress: QuestClock(summary.progress))
    }
}

extension QuestStatus {
    init(_ status: Components.Schemas.QuestStatus) {
        switch status.value1 {
        case .notStarted: self = .notStarted
        case .inProgress: self = .inProgress
        case .completed: self = .completed
        case nil: self = .other(status.value2 ?? "")
        }
    }
}

extension QuestClock {
    init(_ clock: Components.Schemas.Clock) {
        self.init(
            running: clock.running,
            clockStart: clock.clockStart,
            elapsedMs: clock.elapsedMs,
            penaltyMs: clock.penaltyMs,
            totalMs: clock.totalMs)
    }
}

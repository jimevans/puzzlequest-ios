import Foundation
import Observation

/// A player's puzzle screen, as the web app's: the stop's puzzle, kept up to
/// date by the quest's live updates, and the player's actions on it:
/// activating it with its code, guessing, and revealing hints. "Go to the next
/// stop" moves the same screen on to the next puzzle.
@MainActor
@Observable
public final class PuzzleModel {
    public let questName: String
    /// The puzzle on screen; it changes on going to the next stop.
    public private(set) var puzzleName: String
    /// The puzzle, once fetched; nil until then, or once it isn't available.
    public private(set) var puzzle: PlayerPuzzle?
    /// True once the server says the player can't see the puzzle, as after
    /// the puzzle master resets the quest.
    public private(set) var notAvailable = false
    /// Whether the latest fetch failed. A screen showing the puzzle keeps it;
    /// one that hasn't explains, with a way to try again.
    public private(set) var loadFailed = false
    /// The action being sent, if any. It stays pending until the puzzle has
    /// been fetched again, so the old state can't be acted on meanwhile.
    public private(set) var pending: PuzzleAction?
    /// Why the latest action didn't succeed, until the next one.
    public private(set) var actionError: PuzzleActionError?
    /// What changed in the latest fetch that changed anything, for VoiceOver.
    public private(set) var changes: [PuzzleChange] = []
    /// Counts the fetches that changed something, so the screen can tell when
    /// `changes` is new, even if it's the same as before.
    public private(set) var changeCount = 0
    /// Whether live updates are connected and the puzzle fetched since.
    public private(set) var isLive = false
    /// Changes each time following should start again on a new connection;
    /// the screen restarts its following task when it does (`.task(id:)`).
    public private(set) var followGeneration = 0

    /// How long to wait before sending a scanned code again after the server
    /// didn't answer; tests make it shorter.
    package var retryAfterNoAnswer: Duration = .seconds(5)

    private let api: APIClient
    private let follower: LiveUpdateFollower
    /// The live-update connection, sent with the player's own actions so
    /// that their updates aren't sent back: the screen shows the result
    /// itself.
    private var connectionId: String?
    /// Fetches can overlap; only the latest one's answer is kept.
    private var latestFetch = 0
    /// The scanner reads a code many times a second, and wrong codes are
    /// limited, so a code left in view is sent once, or again only after the
    /// server didn't answer.
    private var lastScan: (code: String, tryAgainAt: ContinuousClock.Instant?)?

    public convenience init(questName: String, puzzleName: String, api: APIClient) {
        self.init(
            questName: questName, puzzleName: puzzleName, api: api,
            connector: URLSessionLiveSocketConnector())
    }

    package init(
        questName: String, puzzleName: String, api: APIClient, connector: any LiveSocketConnector,
        configure: (inout LiveUpdateFollower) -> Void = { _ in }
    ) {
        self.questName = questName
        self.puzzleName = puzzleName
        self.api = api
        var follower = LiveUpdateFollower(
            url: api.liveUpdatesURL, channel: .quest(questName: questName),
            connector: connector,
            ticket: { try await api.questLiveTicket(questName: questName) })
        configure(&follower)
        self.follower = follower
    }

    /// Fetches the puzzle, as when the screen appears or is pulled down.
    public func load() async {
        await fetch()
    }

    /// Keeps the puzzle up to date until the task is cancelled: fetches it
    /// again on every update about the quest, and each time the connection
    /// is made, since changes may have been missed.
    public func followLiveUpdates() async {
        defer {
            isLive = false
            connectionId = nil
        }
        await follower.run { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected(let id):
                connectionId = id
                await fetch()
                isLive = true
            case .update(.questChanged(_, let questName, _)) where questName == self.questName:
                await fetch()
            case .disconnected:
                isLive = false
                connectionId = nil
            case .update:
                break
            }
        }
    }

    /// Back in the foreground: follows again on a new connection, and fetches.
    public func returnedToForeground() async {
        isLive = false
        followGeneration += 1
        await fetch()
    }

    /// Moves on to the stop after this one, once it's solved.
    public func goToNextStop() async {
        guard let next = puzzle?.next else { return }
        puzzleName = next.puzzleName
        puzzle = nil
        notAvailable = false
        loadFailed = false
        actionError = nil
        lastScan = nil
        await fetch()
    }

    /// Activates the puzzle with the code the player typed.
    public func activate(code: String) async {
        await act(.activating) { [api, questName, puzzleName, connectionId] () throws(APIError) in
            try await api.activatePuzzle(
                questName: questName, puzzleName: puzzleName, code: code,
                connectionId: connectionId)
        }
    }

    /// Activates the puzzle with a code read from its QR code, unless it was
    /// just sent: the scanner sees a code many times a second.
    public func scanned(code: String) async {
        guard pending == nil else { return }
        if let lastScan, lastScan.code == code {
            guard let tryAgainAt = lastScan.tryAgainAt, ContinuousClock.now >= tryAgainAt else {
                return
            }
        }
        lastScan = (code, nil)
        await activate(code: code)
        if actionError == .unreachable {
            // The server never answered, so this says nothing about the code.
            lastScan = (code, ContinuousClock.now + retryAfterNoAnswer)
        }
    }

    /// Guesses the solution.
    /// - Returns: whether the guess was right.
    @discardableResult
    public func solve(guess: String) async -> Bool {
        await act(.solving) { [api, questName, puzzleName, connectionId] () throws(APIError) in
            try await api.attemptSolution(
                questName: questName, puzzleName: puzzleName, guess: guess,
                connectionId: connectionId)
        }
    }

    /// Reveals the next hint, adding its penalty to the players' time. The
    /// screen asks first if the hint gives the solution away.
    public func revealHint() async {
        await act(.revealingHint) { [api, questName, puzzleName, connectionId] () throws(APIError) in
            try await api.revealHint(
                questName: questName, puzzleName: puzzleName, connectionId: connectionId)
        }
    }

    /// Clears the message about the last action, as when the player starts
    /// another.
    public func clearActionError() {
        actionError = nil
    }

    /// Sends one of the player's actions. However it turns out, the puzzle is
    /// fetched again, since a refusal often means it has changed (a teammate
    /// solved it, or the quest was paused), and the action stays pending
    /// until that's back.
    @discardableResult
    private func act(
        _ action: PuzzleAction, _ send: () async throws(APIError) -> Void
    ) async -> Bool {
        guard pending == nil else { return false }
        pending = action
        actionError = nil
        defer { pending = nil }
        var succeeded = true
        do throws(APIError) {
            try await send()
        } catch {
            succeeded = false
            actionError = PuzzleActionError(error)
        }
        await fetch()
        return succeeded
    }

    private func fetch() async {
        latestFetch += 1
        let fetch = latestFetch
        let puzzleName = puzzleName
        do throws(APIError) {
            let fetched = try await api.playerPuzzle(questName: questName, puzzleName: puzzleName)
            guard fetch == latestFetch, puzzleName == self.puzzleName else { return }
            loadFailed = false
            guard let fetched else {
                puzzle = nil
                notAvailable = true
                return
            }
            if let puzzle {
                let changed = PuzzleChange.between(puzzle, fetched)
                if !changed.isEmpty {
                    changes = changed
                    changeCount += 1
                }
            }
            notAvailable = false
            puzzle = fetched
        } catch {
            guard fetch == latestFetch, puzzleName == self.puzzleName else { return }
            loadFailed = true
        }
    }
}

/// One of the player's actions on a puzzle.
public enum PuzzleAction: Equatable, Sendable {
    case activating
    case solving
    case revealingHint
}

/// Why a player's action on a puzzle didn't succeed.
public enum PuzzleActionError: Equatable, Sendable {
    case wrongCode
    case wrongAnswer
    /// The puzzle master has paused the quest.
    case paused
    /// Too many tries in a short time.
    case tooManyAttempts
    case noMoreHints
    /// The puzzle changed meanwhile, as when a teammate solved it; the
    /// screen now shows where it stands.
    case changed
    /// Someone else acted at the same moment; trying again should work.
    case tryAgain
    case unreachable
    case unexpected

    init(_ error: APIError) {
        switch error {
        case .problem(let problem):
            switch problem.type {
            case Problem.Types.wrongActivationCode: self = .wrongCode
            case Problem.Types.wrongAnswer: self = .wrongAnswer
            case Problem.Types.questPaused: self = .paused
            case Problem.Types.tooManyRequests: self = .tooManyAttempts
            case Problem.Types.noMoreHints: self = .noMoreHints
            case Problem.Types.wrongState: self = .changed
            case Problem.Types.tryAgain: self = .tryAgain
            default: self = problem.status == 404 ? .changed : .unexpected
            }
        case .unreachable:
            self = .unreachable
        case .unexpectedResponse:
            self = .unexpected
        }
    }
}

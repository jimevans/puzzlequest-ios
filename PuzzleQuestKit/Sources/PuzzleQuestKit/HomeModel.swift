import Foundation
import Observation

/// A player's home screen: the quests they play, kept up to date by live
/// updates, and a reminder to verify their email address.
@MainActor
@Observable
public final class HomeModel {
    /// The quests, once fetched; nil until the first fetch succeeds.
    public private(set) var quests: [QuestSummary]?
    /// Whether the latest fetch failed. A screen that has quests keeps showing
    /// them; one that hasn't explains, with a way to try again.
    public private(set) var loadFailed = false
    /// How many times a live update has changed the list, so the screen can
    /// tell VoiceOver users. A clock counting up isn't a change.
    public private(set) var liveChanges = 0
    /// Whether live updates are connected and the list has been fetched since
    /// connecting, so from here on a change arrives as an update.
    public private(set) var isLive = false
    /// Changes each time following should start again on a new connection,
    /// as on coming back to the foreground; the screen restarts its
    /// following task when it does (`.task(id:)`).
    public private(set) var followGeneration = 0

    public let emailReminder: EmailReminderModel

    private let api: APIClient
    private let userName: String
    private let follower: LiveUpdateFollower
    /// Fetches can overlap (pull to refresh while a live update arrives); only
    /// the latest one's answer is kept.
    private var latestFetch = 0

    public convenience init(user: SignedInUser, api: APIClient) {
        self.init(user: user, api: api, connector: URLSessionLiveSocketConnector())
    }

    package init(
        user: SignedInUser, api: APIClient, connector: any LiveSocketConnector,
        configure: (inout LiveUpdateFollower) -> Void = { _ in }
    ) {
        self.api = api
        userName = user.userName
        emailReminder = EmailReminderModel(userName: user.userName, api: api)
        let userName = user.userName
        var follower = LiveUpdateFollower(
            url: api.liveUpdatesURL, channel: .userQuests(userName: userName),
            connector: connector,
            ticket: { try await api.userLiveTicket(userName: userName) })
        configure(&follower)
        self.follower = follower
    }

    /// Fetches the quests, as when the screen appears or is pulled down.
    public func load() async {
        await fetch(live: false)
    }

    /// Keeps the list up to date until the task is cancelled (the screen goes
    /// away): fetches it again whenever the server says it has changed, and
    /// each time the connection is made, since changes may have been missed.
    public func followLiveUpdates() async {
        defer { isLive = false }
        await follower.run { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected:
                await fetch(live: true)
                // Only now: the fetch has caught up with anything missed.
                isLive = true
            case .update(.questsChanged):
                await fetch(live: true)
            case .disconnected:
                isLive = false
            case .update:
                break
            }
        }
    }

    /// Back in the foreground, where the connection has probably been dropped
    /// and changes missed: follows again on a new connection, and fetches.
    public func returnedToForeground() async {
        isLive = false
        followGeneration += 1
        await fetch(live: false)
    }

    private func fetch(live: Bool) async {
        latestFetch += 1
        let fetch = latestFetch
        do throws(APIError) {
            let fetched = try await api.userQuests(userName: userName)
            guard fetch == latestFetch else { return }
            if live, let quests, Self.listing(quests) != Self.listing(fetched) {
                liveChanges += 1
            }
            quests = fetched
            loadFailed = false
        } catch {
            guard fetch == latestFetch else { return }
            loadFailed = true
        }
    }

    /// What the list says about each quest, leaving out its clock, whose
    /// figures change with every fetch while it runs.
    private static func listing(_ quests: [QuestSummary]) -> [QuestSummary] {
        quests.map {
            var quest = $0
            quest.progress = QuestClock(
                running: false, clockStart: nil, elapsedMs: 0, penaltyMs: 0, totalMs: 0)
            return quest
        }
    }
}

/// The reminder to verify an email address, with a way to have the email sent
/// again.
@MainActor
@Observable
public final class EmailReminderModel {
    public enum State: Equatable, Sendable {
        case ready
        case sending
        /// Sent; it isn't offered again.
        case sent
        /// It couldn't be sent; it can be tried again.
        case failed(EmailReminderFailure)
    }

    public private(set) var state = State.ready

    private let userName: String
    private let api: APIClient

    init(userName: String, api: APIClient) {
        self.userName = userName
        self.api = api
    }

    public var canSend: Bool {
        state != .sending && state != .sent
    }

    public func send() async {
        guard canSend else { return }
        state = .sending
        do throws(APIError) {
            try await api.sendVerificationEmail(userName: userName)
            state = .sent
        } catch {
            state = .failed(EmailReminderFailure(error))
        }
    }
}

/// Why the verification email couldn't be sent again.
public enum EmailReminderFailure: Equatable, Sendable {
    /// It has been sent several times lately; wait before asking again.
    case tooManyRequests
    /// The server couldn't be reached.
    case unreachable
    /// Anything else, such as a fault on the server.
    case unexpected

    public init(_ error: APIError) {
        switch error {
        case .problem(let problem) where problem.type == Problem.Types.tooManyRequests:
            self = .tooManyRequests
        case .unreachable:
            self = .unreachable
        default:
            self = .unexpected
        }
    }
}

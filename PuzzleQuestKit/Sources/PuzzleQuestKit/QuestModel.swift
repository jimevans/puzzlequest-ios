import Foundation
import Observation

/// A player's quest screen: their entry's progress, kept up to date by the
/// quest's live updates, and once it has finished, the race's standings.
@MainActor
@Observable
public final class QuestModel {
    public let questName: String
    /// The quest, once fetched; nil until then, or once it isn't available.
    public private(set) var quest: PlayerQuest?
    /// True once the server says the player has no entry to see, as after the
    /// puzzle master resets the quest.
    public private(set) var notAvailable = false
    /// Whether the latest fetch failed. A screen showing the quest keeps it;
    /// one that hasn't explains, with a way to try again.
    public private(set) var loadFailed = false
    /// The race's standings, once the player's entry has finished and if
    /// others played it; nil otherwise.
    public private(set) var standings: Standings?
    /// What changed in the latest fetch that changed anything, for VoiceOver.
    public private(set) var changes: [QuestChange] = []
    /// Counts the fetches that changed something, so the screen can tell when
    /// `changes` is new, even if it's the same as before.
    public private(set) var changeCount = 0
    /// Whether live updates are connected and the quest fetched since, so
    /// from here on a change arrives as an update.
    public private(set) var isLive = false
    /// Changes each time following should start again on a new connection;
    /// the screen restarts its following task when it does (`.task(id:)`).
    public private(set) var followGeneration = 0

    private let api: APIClient
    private let follower: LiveUpdateFollower
    /// Fetches can overlap; only the latest one's answer is kept.
    private var latestFetch = 0

    public convenience init(questName: String, api: APIClient) {
        self.init(questName: questName, api: api, connector: URLSessionLiveSocketConnector())
    }

    package init(
        questName: String, api: APIClient, connector: any LiveSocketConnector,
        configure: (inout LiveUpdateFollower) -> Void = { _ in }
    ) {
        self.questName = questName
        self.api = api
        var follower = LiveUpdateFollower(
            url: api.liveUpdatesURL, channel: .quest(questName: questName),
            connector: connector,
            ticket: { try await api.questLiveTicket(questName: questName) })
        configure(&follower)
        self.follower = follower
    }

    /// Fetches the quest, as when the screen appears or is pulled down.
    public func load() async {
        await fetch()
    }

    /// Keeps the quest up to date until the task is cancelled: fetches it
    /// again on every update about it (the web app does the same), and each
    /// time the connection is made, since changes may have been missed.
    public func followLiveUpdates() async {
        defer { isLive = false }
        await follower.run { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected:
                await fetch()
                isLive = true
            case .update(.questChanged(_, let questName, _)) where questName == self.questName:
                await fetch()
            case .disconnected:
                isLive = false
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

    private func fetch() async {
        latestFetch += 1
        let fetch = latestFetch
        do throws(APIError) {
            let fetched = try await api.playerQuest(questName: questName)
            // Standings only for a finished entry: during a race, a player
            // still racing isn't shown the others.
            var fetchedStandings: Standings?
            if let fetched, fetched.entry.isFinished {
                fetchedStandings = try? await api.standings(questName: questName)
            }
            guard fetch == latestFetch else { return }
            loadFailed = false
            guard let fetched else {
                quest = nil
                standings = nil
                notAvailable = true
                return
            }
            var changed: [QuestChange] = []
            if let quest {
                changed += QuestChange.between(quest, fetched)
            }
            notAvailable = false
            quest = fetched
            if let fetchedStandings {
                // A quest one player or team played has no standings to show.
                let shown = fetchedStandings.entries.count >= 2 ? fetchedStandings : nil
                if let standings, let shown {
                    changed += QuestChange.between(standings, shown, ownEntryId: fetched.entry.id)
                }
                standings = shown
            } else if !fetched.entry.isFinished {
                standings = nil
            }
            if !changed.isEmpty {
                changes = changed
                changeCount += 1
            }
        } catch {
            guard fetch == latestFetch else { return }
            loadFailed = true
        }
    }
}

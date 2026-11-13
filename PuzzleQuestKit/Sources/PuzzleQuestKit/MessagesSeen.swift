import Foundation
import Synchronization

/// Which of the puzzle master's messages this phone has shown, so each pops
/// up once: on arriving, or on opening the quest if it came while the app was
/// closed; and the answered challenge the player has hidden, if any.
public protocol MessagesSeen: Sendable {
    /// The IDs of the messages shown for an entry.
    func seen(entryId: String) -> Set<String>
    /// Records messages as shown.
    func markSeen(_ ids: some Sequence<String>, entryId: String)
    /// The answered challenge the player hid from the quest screen, by its
    /// `Challenge.id`.
    func hiddenChallenge(entryId: String) -> String?
    /// Hides an answered challenge from the quest screen.
    func hideChallenge(_ id: String, entryId: String)
}

/// Keeps what's been shown in `UserDefaults`. An entry keeps only its latest
/// messages, so only their IDs are worth keeping.
public struct UserDefaultsMessagesSeen: MessagesSeen, @unchecked Sendable {
    // UserDefaults is thread-safe, though not marked Sendable.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ entryId: String) -> String {
        "PuzzleQuest.messagesSeen.\(entryId)"
    }

    public func seen(entryId: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key(entryId)) ?? [])
    }

    public func markSeen(_ ids: some Sequence<String>, entryId: String) {
        let all = seen(entryId: entryId).union(ids)
        // Messages beyond the entry's latest 50 are gone from the server.
        defaults.set(Array(all.sorted().suffix(100)), forKey: key(entryId))
    }

    private func hiddenKey(_ entryId: String) -> String {
        "PuzzleQuest.challengeHidden.\(entryId)"
    }

    public func hiddenChallenge(entryId: String) -> String? {
        defaults.string(forKey: hiddenKey(entryId))
    }

    public func hideChallenge(_ id: String, entryId: String) {
        // Only the latest is kept: a challenge replaces the one before.
        defaults.set(id, forKey: hiddenKey(entryId))
    }
}

/// Keeps what's been shown in memory, as tests do.
public final class InMemoryMessagesSeen: MessagesSeen {
    private let ids = Mutex<[String: Set<String>]>([:])
    private let hidden = Mutex<[String: String]>([:])

    public init() {}

    public func seen(entryId: String) -> Set<String> {
        ids.withLock { $0[entryId] ?? [] }
    }

    public func markSeen(_ ids: some Sequence<String>, entryId: String) {
        let new = Set(ids)
        self.ids.withLock { $0[entryId, default: []].formUnion(new) }
    }

    public func hiddenChallenge(entryId: String) -> String? {
        hidden.withLock { $0[entryId] }
    }

    public func hideChallenge(_ id: String, entryId: String) {
        hidden.withLock { $0[entryId] = id }
    }
}

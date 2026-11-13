import Foundation
import Synchronization

/// Which of the puzzle master's messages this phone has shown, so each pops
/// up once: on arriving, or on opening the quest if it came while the app was
/// closed.
public protocol MessagesSeen: Sendable {
    /// The IDs of the messages shown for an entry.
    func seen(entryId: String) -> Set<String>
    /// Records messages as shown.
    func markSeen(_ ids: some Sequence<String>, entryId: String)
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
}

/// Keeps what's been shown in memory, as tests do.
public final class InMemoryMessagesSeen: MessagesSeen {
    private let ids = Mutex<[String: Set<String>]>([:])

    public init() {}

    public func seen(entryId: String) -> Set<String> {
        ids.withLock { $0[entryId] ?? [] }
    }

    public func markSeen(_ ids: some Sequence<String>, entryId: String) {
        let new = Set(ids)
        self.ids.withLock { $0[entryId, default: []].formUnion(new) }
    }
}

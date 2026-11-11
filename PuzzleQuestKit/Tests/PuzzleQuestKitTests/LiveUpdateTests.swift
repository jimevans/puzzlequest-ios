import Foundation
import Synchronization
import Testing

@testable import PuzzleQuestKit

/// Hands out numbered tickets, failing the calls a test names.
final class Tickets: Sendable {
    private let calls = Mutex(0)
    private let failing: Set<Int>

    init(failing: Set<Int> = []) {
        self.failing = failing
    }

    var count: Int { calls.withLock { $0 } }

    func next() throws -> String {
        let call = calls.withLock { calls in
            calls += 1
            return calls
        }
        if failing.contains(call) {
            throw APIError.unreachable
        }
        return "ticket-\(call)"
    }
}

@MainActor
@Suite("Following live updates")
struct LiveUpdateFollowerTests {
    let connector = FakeLiveSocketConnector()
    let events = Recorder<LiveEvent>()
    let delays = Recorder<Duration>()
    let url = URL(string: "wss://example.com/api/v1/updates")!

    /// Starts following the user pat's quests, recording events and waits.
    private func follow(
        _ channel: LiveChannel = .userQuests(userName: "pat"), tickets: Tickets = Tickets(),
        pingInterval: Duration = .seconds(60)
    ) -> Task<Void, Never> {
        var follower = LiveUpdateFollower(
            url: url, channel: channel, connector: connector, ticket: { try tickets.next() })
        let delays = delays
        follower.wait = { delay in await delays.record(delay) }
        follower.pingInterval = pingInterval
        let events = events
        return Task { await follower.run { events.record($0) } }
    }

    private func subscription(_ socket: FakeLiveSocket) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(try #require(socket.sent.first).utf8))
    }

    @Test("It connects to the websocket and subscribes with a new ticket")
    func subscribes() async throws {
        let following = follow()
        defer { following.cancel() }

        let socket = try await connector.socket(0)
        #expect(connector.urls == [url])
        #expect(try subscription(socket) == ["message": "subscribe", "userName": "pat", "ticket": "ticket-1"])
    }

    @Test("It subscribes to a quest the same way, for the quest screen")
    func subscribesToQuest() async throws {
        let following = follow(.quest(questName: "harbor-walk"))
        defer { following.cancel() }

        let socket = try await connector.socket(0)
        #expect(
            try subscription(socket)
                == ["message": "subscribe", "questName": "harbor-walk", "ticket": "ticket-1"])
    }

    @Test("It reports the connection and each update, and ignores messages it doesn't know")
    func reportsUpdates() async throws {
        let following = follow()
        defer { following.cancel() }
        let socket = try await connector.socket(0)

        socket.deliver(#"{"message":"connection","connectionId":"c1"}"#)
        socket.deliver(#"{"message":"somethingNew","questName":"x"}"#)
        socket.deliver("not JSON")
        socket.deliver(#"{"message":"questsChanged"}"#)
        try await eventually("two events") { events.values.count == 2 }

        #expect(events.values == [.connected(connectionId: "c1"), .update(.questsChanged)])
    }

    @Test("After a drop it reconnects with a new ticket, waiting longer after each failure")
    func reconnects() async throws {
        // The second and third tickets can't be had.
        let tickets = Tickets(failing: [2, 3])
        let following = follow(tickets: tickets)
        defer { following.cancel() }
        let first = try await connector.socket(0)
        first.deliver(#"{"message":"connection","connectionId":"c1"}"#)
        try await eventually("connected") { events.values.count == 1 }

        first.close()
        let second = try await connector.socket(1)
        #expect(try subscription(second)["ticket"] == "ticket-4")
        second.deliver(#"{"message":"connection","connectionId":"c2"}"#)
        try await eventually("connected again") { events.values.count == 3 }

        #expect(
            events.values == [
                .connected(connectionId: "c1"), .disconnected, .connected(connectionId: "c2"),
            ])
        #expect(delays.values == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test("The wait between attempts grows to 15 seconds at most")
    func longestWait() async throws {
        let tickets = Tickets(failing: Set(1...7))
        let following = follow(tickets: tickets)
        defer { following.cancel() }

        _ = try await connector.socket(0)
        #expect(
            delays.values
                == [1, 2, 4, 8, 15, 15, 15].map { Duration.seconds($0) })
    }

    @Test("A connection whose pings fail counts as dropped")
    func failedPing() async throws {
        let following = follow(pingInterval: .milliseconds(10))
        defer { following.cancel() }
        let first = try await connector.socket(0)
        first.deliver(#"{"message":"connection","connectionId":"c1"}"#)

        first.failPings()
        let second = try await connector.socket(1)
        #expect(first.isClosed)
        #expect(try subscription(second)["ticket"] == "ticket-2")
    }

    @Test("It stops, and closes the connection, when its task is cancelled")
    func stops() async throws {
        let tickets = Tickets()
        let following = follow(tickets: tickets)
        let socket = try await connector.socket(0)
        socket.deliver(#"{"message":"connection","connectionId":"c1"}"#)
        try await eventually("connected") { events.values.count == 1 }

        following.cancel()
        await following.value

        #expect(socket.isClosed)
        #expect(connector.sockets.count == 1)
        #expect(tickets.count == 1)
        // No report of a drop: nobody is listening any more.
        #expect(events.values == [.connected(connectionId: "c1")])
    }
}

@Suite("Live-update messages")
struct LiveUpdateMessageTests {
    @Test("Each message the API describes is read")
    func knownMessages() {
        let read = { LiveUpdateFollower.message(from: $0) }
        #expect(read(#"{"message":"connection","connectionId":"c1"}"#) == .connection("c1"))
        #expect(read(#"{"message":"questsChanged"}"#) == .update(.questsChanged))
        let changes = [
            #"{"message":"puzzleActivated","questName":"q","entryId":"e","puzzleName":"p","activationTime":"2026-11-11T16:00:00.000Z"}"#,
            #"{"message":"puzzleSolved","questName":"q","entryId":"e","puzzleName":"p","solutionText":"s","endTime":"2026-11-11T16:00:00Z","questComplete":false}"#,
            #"{"message":"puzzleStarted","questName":"q","entryId":"e","puzzleName":"p","displayName":"P","startTime":"2026-11-11T16:00:00.000Z"}"#,
            #"{"message":"hintRevealed","questName":"q","entryId":"e","puzzleName":"p","hintText":"h","timePenaltySeconds":60,"nextHint":null}"#,
            #"{"message":"questUpdated","questName":"q","entryId":"e"}"#,
        ]
        let kinds = ["puzzleActivated", "puzzleSolved", "puzzleStarted", "hintRevealed", "questUpdated"]
        for (text, kind) in zip(changes, kinds) {
            #expect(read(text) == .update(.questChanged(message: kind, questName: "q", entryId: "e")))
        }
    }

    @Test("A field the app doesn't know is ignored")
    func unknownField() {
        #expect(
            LiveUpdateFollower.message(from: #"{"message":"questsChanged","reason":"started"}"#)
                == .update(.questsChanged))
    }

    @Test("A message the app doesn't know, or can't read, is nothing")
    func unknownMessages() {
        for text in [#"{"message":"teamRenamed","teamName":"reds"}"#, "{}", "[]", "not JSON", ""] {
            #expect(LiveUpdateFollower.message(from: text) == nil)
        }
    }

    @Test("The websocket is on the API's site, encrypted when the site is")
    func address() {
        let tokens = InMemoryTokenStore()
        let transport = FakeTransport { _ in json(500, "{}") }
        let secure = APIClient(
            server: URL(string: "https://thepuzzlequest.com")!, tokens: tokens, transport: transport)
        #expect(secure.liveUpdatesURL.absoluteString == "wss://thepuzzlequest.com/api/v1/updates")
        let local = APIClient(
            server: URL(string: "http://localhost:3000")!, tokens: tokens, transport: transport)
        #expect(local.liveUpdatesURL.absoluteString == "ws://localhost:3000/api/v1/updates")
    }
}

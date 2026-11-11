import Foundation
import HTTPTypes
import OpenAPIRuntime
import Synchronization
import Testing

@testable import PuzzleQuestKit

/// A quest summary as the API sends one, with a stopped clock unless one is
/// given.
func questJSON(
    _ name: String, status: String = "inProgress", description: String = "In progress",
    paused: Bool = false,
    clock: String = #"{"startTime":null,"endTime":null,"running":false,"clockStart":null,"elapsedMs":0,"penaltyMs":0,"totalMs":0}"#
) -> String {
    #"{"questName":"\#(name)","displayName":"The \#(name)","status":"\#(status)","statusDescription":"\#(description)","paused":\#(paused),"progress":\#(clock)}"#
}

/// A page of quest summaries.
func pageJSON(_ quests: [String], next: String? = nil) -> String {
    #"{"items":[\#(quests.joined(separator: ","))],"next":\#(next.map { #""\#($0)""# } ?? "null")}"#
}

/// A value shared with the fake server's answers, which run on any thread.
/// (A `Mutex` can't be captured by an escaping closure itself, so a class
/// holds it.)
final class Shared<Value: Sendable>: Sendable {
    private let value: Mutex<Value>

    init(_ value: Value) {
        self.value = Mutex(value)
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try value.withLock { try body(&$0) }
    }
}

@Suite("A quest's clock")
struct QuestClockTests {
    let start = Date(timeIntervalSince1970: 1_794_412_800)
    let minute = 60_000

    @Test("A running clock counts up from when it started, and adds penalties to the total")
    func running() {
        let clock = QuestClock(
            running: true, clockStart: start, elapsedMs: 0, penaltyMs: minute, totalMs: minute)
        let later = start.addingTimeInterval(5 * 60)
        #expect(clock.isCounting)
        #expect(clock.elapsedMs(at: later) == 5 * minute)
        #expect(clock.totalMs(at: later) == 6 * minute)
    }

    @Test("A stopped clock keeps its time, whatever the time is now")
    func stopped() {
        let clock = QuestClock(
            running: false, clockStart: nil, elapsedMs: 5 * minute, penaltyMs: minute,
            totalMs: 6 * minute)
        #expect(!clock.isCounting)
        #expect(clock.elapsedMs(at: start) == 5 * minute)
        #expect(clock.totalMs(at: start) == 6 * minute)
    }

    @Test(
        "Times show as a clock does",
        arguments: [
            (0, "0:00"), (5_000, "0:05"), (65_000, "1:05"), (3_845_000, "1:04:05"),
            (59_999, "0:59"),
            // A phone whose clock is behind the server's.
            (-5_000, "0:00"),
        ])
    func format(milliseconds: Int, text: String) {
        #expect(QuestClock.format(milliseconds: milliseconds) == text)
    }
}

@Suite("Who sees what")
struct HomeScreenTests {
    @Test(
        "Players see their quests; staff, administrators, and roles added later see the website note",
        arguments: [
            (Role.player, HomeScreen.quests), (.staff, .website), (.admin, .website),
            (.other("organiser"), .website),
        ])
    func routing(role: Role, screen: HomeScreen) {
        let user = SignedInUser(
            userName: "pat", displayName: "Pat", role: role, emailVerified: true)
        #expect(user.homeScreen == screen)
    }
}

@Suite("Fetching the player's quests")
struct UserQuestsTests {
    @Test("Every page is fetched, each after the one before")
    func paging() async throws {
        let pages = Shared([
            pageJSON([questJSON("first")], next: "cursor-1"),
            pageJSON([questJSON("second"), questJSON("third")], next: "cursor-2"),
            pageJSON([]),
        ])
        let transport = FakeTransport { _ in json(200, pages.withLock { $0.removeFirst() }) }
        let quests = try await api(transport, tokens: InMemoryTokenStore(token: "t"))
            .userQuests(userName: "player one")

        #expect(quests.map(\.questName) == ["first", "second", "third"])
        #expect(
            transport.requests.map(\.request.path) == [
                "/users/player%20one/quests",
                "/users/player%20one/quests?after=cursor-1",
                "/users/player%20one/quests?after=cursor-2",
            ])
    }

    @Test("A quest is read with its status, pause, and clock")
    func reading() async throws {
        let transport = FakeTransport { _ in
            json(
                200,
                pageJSON([
                    questJSON(
                        "trail", description: "Paused", paused: true,
                        clock: #"{"startTime":"2026-11-11T16:00:00.000Z","endTime":null,"running":true,"clockStart":"2026-11-11T16:00:00.000Z","elapsedMs":300000,"penaltyMs":60000,"totalMs":360000}"#),
                    questJSON("next", status: "racing", description: "Racing"),
                ]))
        }
        let quests = try await api(transport).userQuests(userName: "pat")
        #expect(
            quests.first
                == QuestSummary(
                    questName: "trail", displayName: "The trail", status: .inProgress,
                    statusDescription: "Paused", paused: true,
                    progress: QuestClock(
                        running: true, clockStart: Date(timeIntervalSince1970: 1_794_412_800),
                        elapsedMs: 300_000, penaltyMs: 60_000, totalMs: 360_000)))
        #expect(quests.last?.status == .other("racing"))
    }
}

/// The API as the home screen uses it: each list of quests in turn (repeating
/// the last), live tickets, and verification emails.
final class HomeServer: Sendable {
    let transport: FakeTransport

    init(lists: [String], fails: Bool = false) {
        let lists = Shared(lists)
        transport = FakeTransport { operation in
            switch operation {
            case "listUserQuests":
                if fails { throw URLError(.notConnectedToInternet) }
                return json(200, lists.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] })
            case "createUserLiveTicket":
                return json(201, #"{"ticket":"ticket","expiresAt":"2026-11-11T16:00:00.000Z"}"#)
            default:
                return json(500, "{}")
            }
        }
    }

    var fetches: Int { transport.requests.filter { $0.operationID == "listUserQuests" }.count }
}

@MainActor
@Suite("The home screen's model")
struct HomeModelTests {
    let pat = SignedInUser(userName: "pat", displayName: "Pat", role: .player, emailVerified: false)
    let connector = FakeLiveSocketConnector()

    private func model(_ server: HomeServer) -> HomeModel {
        HomeModel(
            user: pat, api: api(server.transport, tokens: InMemoryTokenStore(token: "t")),
            connector: connector, configure: { $0.wait = { _ in } })
    }

    @Test("Before fetching it has no quests; then it has them, or none")
    func loads() async {
        let server = HomeServer(lists: [pageJSON([questJSON("trail")])])
        let home = model(server)
        #expect(home.quests == nil)
        #expect(!home.loadFailed)

        await home.load()
        #expect(home.quests?.map(\.questName) == ["trail"])

        let empty = model(HomeServer(lists: [pageJSON([])]))
        await empty.load()
        #expect(empty.quests == [])
    }

    @Test("A failed first fetch is reported, with no quests")
    func failure() async {
        let home = model(HomeServer(lists: [pageJSON([])], fails: true))
        await home.load()
        #expect(home.loadFailed)
        #expect(home.quests == nil)
    }

    @Test("A failed refresh keeps the quests already shown")
    func failedRefresh() async throws {
        let server = HomeServer(lists: [pageJSON([questJSON("trail")]), "not JSON"])
        let home = model(server)
        await home.load()
        await home.load()
        #expect(home.loadFailed)
        #expect(home.quests?.map(\.questName) == ["trail"])
    }

    @Test("Live updates fetch the list on connecting and on each change, and count only real changes")
    func followsLiveUpdates() async throws {
        let server = HomeServer(lists: [
            pageJSON([]),
            // On connecting: nothing new.
            pageJSON([]),
            // The quest starts.
            pageJSON([questJSON("trail")]),
            // Only its clock has moved.
            pageJSON([
                questJSON(
                    "trail",
                    clock: #"{"startTime":null,"endTime":null,"running":false,"clockStart":null,"elapsedMs":9,"penaltyMs":0,"totalMs":9}"#)
            ]),
            // It's paused.
            pageJSON([questJSON("trail", paused: true)]),
        ])
        let home = model(server)
        await home.load()
        let following = Task { await home.followLiveUpdates() }
        defer { following.cancel() }

        let socket = try await connector.socket(0)
        socket.deliver(#"{"message":"connection","connectionId":"c1"}"#)
        try await eventually("fetched on connecting") { server.fetches == 2 }
        #expect(home.liveChanges == 0)

        socket.deliver(#"{"message":"questsChanged"}"#)
        try await eventually("fetched on a change") { home.quests?.count == 1 }
        #expect(home.liveChanges == 1)

        socket.deliver(#"{"message":"questsChanged"}"#)
        try await eventually("fetched again") { server.fetches == 4 }
        #expect(home.liveChanges == 1)

        socket.deliver(#"{"message":"questsChanged"}"#)
        try await eventually("paused") { home.quests?.first?.paused == true }
        #expect(home.liveChanges == 2)

        // Updates about a quest itself are for the quest screen.
        socket.deliver(#"{"message":"questUpdated","questName":"trail","entryId":"e"}"#)
        socket.deliver(#"{"message":"questsChanged"}"#)
        try await eventually("fetched again") { server.fetches == 6 }
    }

    @Test("After a drop it reconnects and fetches again, since changes may have been missed")
    func refetchesAfterReconnecting() async throws {
        let server = HomeServer(lists: [pageJSON([]), pageJSON([]), pageJSON([questJSON("trail")])])
        let home = model(server)
        await home.load()
        let following = Task { await home.followLiveUpdates() }
        defer { following.cancel() }
        let first = try await connector.socket(0)
        first.deliver(#"{"message":"connection","connectionId":"c1"}"#)
        try await eventually("fetched on connecting") { server.fetches == 2 }

        first.close()
        let second = try await connector.socket(1)
        second.deliver(#"{"message":"connection","connectionId":"c2"}"#)
        try await eventually("fetched on reconnecting") { home.quests?.count == 1 }
        #expect(home.liveChanges == 1)
        #expect(server.transport.requests.filter { $0.operationID == "createUserLiveTicket" }.count == 2)
    }

    @Test("It's live only once the fetch on connecting is done, and not after a drop")
    func isLive() async throws {
        let server = HomeServer(lists: [pageJSON([]), pageJSON([questJSON("trail")])])
        let home = model(server)
        await home.load()
        let following = Task { await home.followLiveUpdates() }
        defer { following.cancel() }
        let first = try await connector.socket(0)
        #expect(!home.isLive)

        first.deliver(#"{"message":"connection","connectionId":"c1"}"#)
        try await eventually("live") { home.isLive }
        // The fetch on connecting had already finished.
        #expect(server.fetches == 2)
        #expect(home.quests?.map(\.questName) == ["trail"])

        first.close()
        try await eventually("not live") { !home.isLive }
        _ = try await connector.socket(1)
        #expect(!home.isLive)
    }

    @Test("Back in the foreground it fetches again and asks to follow on a new connection")
    func returnedToForeground() async throws {
        let server = HomeServer(lists: [pageJSON([]), pageJSON([questJSON("trail")])])
        let home = model(server)
        await home.load()
        let generation = home.followGeneration

        await home.returnedToForeground()
        #expect(home.followGeneration == generation + 1)
        #expect(server.fetches == 2)
        #expect(home.quests?.map(\.questName) == ["trail"])
        #expect(!home.isLive)
        // Not a live change: nobody is told the list was updated.
        #expect(home.liveChanges == 0)
    }

    @Test("Following stops when its task is cancelled")
    func stops() async throws {
        let home = model(HomeServer(lists: [pageJSON([])]))
        let following = Task { await home.followLiveUpdates() }
        let socket = try await connector.socket(0)
        following.cancel()
        await following.value
        #expect(socket.isClosed)
    }
}

@MainActor
@Suite("The email reminder")
struct EmailReminderTests {
    private func reminder(_ answer: @escaping FakeTransport.Answer) -> (EmailReminderModel, FakeTransport) {
        let transport = FakeTransport(answer)
        let user = SignedInUser(userName: "pat", displayName: "Pat", role: .player, emailVerified: false)
        let home = HomeModel(
            user: user, api: api(transport, tokens: InMemoryTokenStore(token: "t")),
            connector: FakeLiveSocketConnector())
        return (home.emailReminder, transport)
    }

    @Test("It sends the email again, once")
    func sends() async {
        let (reminder, transport) = reminder { _ in (HTTPResponse(status: .noContent), nil) }
        #expect(reminder.canSend)
        await reminder.send()
        #expect(reminder.state == .sent)
        #expect(!reminder.canSend)
        await reminder.send()
        #expect(transport.requests.map(\.operationID) == ["sendVerificationEmail"])
        #expect(transport.requests.first?.request.path == "/users/pat/email-verification-requests")
    }

    @Test(
        "It says why it couldn't, and lets the player try again",
        arguments: [
            (429, "/problems/too-many-requests", EmailReminderFailure.tooManyRequests),
            (500, "/problems/unexpected", .unexpected),
        ])
    func refused(status: Int, type: String, failure: EmailReminderFailure) async {
        let (reminder, _) = reminder { _ in problem(status, type) }
        await reminder.send()
        #expect(reminder.state == .failed(failure))
        #expect(reminder.canSend)
    }

    @Test("Without a connection it says so")
    func unreachable() async {
        let (reminder, _) = reminder { _ in throw URLError(.notConnectedToInternet) }
        await reminder.send()
        #expect(reminder.state == .failed(.unreachable))
    }
}

@MainActor
@Suite("Refreshing who is signed in")
struct RefreshUserTests {
    @Test("A change made elsewhere, such as verifying the email address, is picked up")
    func picksUpChanges() async throws {
        let verified = Shared(false)
        let transport = FakeTransport { _ in
            json(
                200,
                aliceJSON.replacingOccurrences(
                    of: #""emailVerified":true"#,
                    with: #""emailVerified":\#(verified.withLock { $0 })"#)
                    .wrapped)
        }
        let tokens = InMemoryTokenStore(token: "kept")
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        await session.restore()
        guard case .signedIn(let before) = session.state else {
            Issue.record("expected to be signed in")
            return
        }
        #expect(!before.emailVerified)

        verified.withLock { $0 = true }
        await session.refreshUser()
        #expect(session.state == .signedIn(alice))
    }

    @Test("An ended session is forgotten; an unreachable server changes nothing")
    func failures() async {
        let answers = Shared<[@Sendable () throws -> (HTTPResponse, HTTPBody?)]>([
            { json(200, aliceJSON.wrapped) },
            { throw URLError(.notConnectedToInternet) },
            { problem(401, "/problems/sign-in-required") },
        ])
        let transport = FakeTransport { _ in try answers.withLock { $0.removeFirst() }() }
        let tokens = InMemoryTokenStore(token: "kept")
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        await session.restore()

        await session.refreshUser()
        #expect(session.state == .signedIn(alice))
        await session.refreshUser()
        #expect(session.state == .signedOut)
        #expect(tokens.read() == nil)
    }
}

extension String {
    /// A user's JSON as the current session's response.
    fileprivate var wrapped: String { #"{"user":\#(self)}"# }
}

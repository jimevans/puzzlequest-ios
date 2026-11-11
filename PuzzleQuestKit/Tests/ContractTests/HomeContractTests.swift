import Foundation
import PuzzleQuestAPI
import Testing

@testable import PuzzleQuestKit

/// What the home screen's tests do on the server as its administrator (from
/// scripts/start-test-server.sh), and as new players of their own, so that
/// each test starts with a player who has no quests.
enum TestSite {
    static let adminUserName = TestServer.environment["PQ_TEST_ADMIN_USER_NAME"] ?? ""
    static let adminPassword = TestServer.environment["PQ_TEST_ADMIN_PASSWORD"] ?? ""

    /// A name no one has used, for a user, puzzle, or quest.
    static func unique(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The API, signed in as that user.
    static func signedIn(_ userName: String, password: String) async throws -> APIClient {
        let tokens = InMemoryTokenStore()
        let api = TestServer.api(tokens: tokens)
        tokens.save(try await api.signIn(userName: userName, password: password).token)
        return api
    }

    /// Signs up a new player, and signs in as them.
    static func newPlayer() async throws -> (userName: String, api: APIClient) {
        let userName = unique("player")
        let password = "a long enough password"
        let output = try await TestServer.api().client.createUser(
            body: .json(
                .init(
                    userName: userName, displayName: "Player \(userName)",
                    email: "\(userName)@example.com", password: password)))
        guard case .created = output else {
            throw APIError.unexpectedResponse("createUser: \(output)")
        }
        return (userName, try await signedIn(userName, password: password))
    }

    static func admin() async throws -> APIClient {
        try await signedIn(adminUserName, password: adminPassword)
    }

    /// Makes a quest of one stop for a player to play on their own, without
    /// starting it.
    static func makeQuest(for player: String, admin: APIClient) async throws -> String {
        let puzzleName = unique("puzzle")
        let puzzle = try await admin.client.createPuzzle(
            body: .json(
                .init(
                    puzzleName: puzzleName, displayName: "A puzzle", text: "What has keys?",
                    solutionKeyword: "piano", solutionText: "A piano")))
        guard case .created = puzzle else {
            throw APIError.unexpectedResponse("createPuzzle: \(puzzle)")
        }
        let questName = unique("quest")
        let quest = try await admin.client.createQuest(
            body: .json(
                .init(
                    questName: questName, displayName: "Quest \(questName)",
                    entrants: [.init(kind: .init(value1: .player), name: player)],
                    puzzles: [.init(puzzleName: puzzleName)])))
        guard case .created = quest else {
            throw APIError.unexpectedResponse("createQuest: \(quest)")
        }
        return questName
    }

    static func start(_ questName: String, admin: APIClient) async throws {
        let output = try await admin.client.startQuest(path: .init(questName: questName))
        guard case .ok = output else {
            throw APIError.unexpectedResponse("startQuest: \(output)")
        }
    }
}

/// Collects a follower's events, for a test to wait on.
actor Events {
    private(set) var all: [LiveEvent] = []

    func record(_ event: LiveEvent) {
        all.append(event)
    }

    /// Waits until an event has been reported.
    func waitFor(
        _ wanted: @Sendable (LiveEvent) -> Bool, timeout: Duration = .seconds(15)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !all.contains(where: wanted) {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for the event; had \(all)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite(
    "A player's home screen, against a real server",
    .enabled(if: TestServer.url != nil, "set PQ_TEST_SERVER_URL (see scripts/start-test-server.sh)"),
    .serialized)
struct HomeContractTests {
    @Test("A new player has no quests; one made for them appears once it starts")
    func questList() async throws {
        let (player, api) = try await TestSite.newPlayer()
        #expect(try await api.userQuests(userName: player) == [])

        let admin = try await TestSite.admin()
        let questName = try await TestSite.makeQuest(for: player, admin: admin)
        // Not started: not on the list yet.
        #expect(try await api.userQuests(userName: player) == [])

        try await TestSite.start(questName, admin: admin)
        let quests = try await api.userQuests(userName: player)
        let quest = try #require(quests.first)
        #expect(quests.count == 1)
        #expect(quest.questName == questName)
        #expect(quest.displayName == "Quest \(questName)")
        #expect(quest.status == .inProgress)
        #expect(!quest.statusDescription.isEmpty)
        #expect(!quest.paused)
        #expect(quest.progress.isCounting)
        #expect(quest.progress.totalMs(at: .now) >= 0)
    }

    @Test("A player can have live tickets for their own quests, one for each connection")
    func liveTicket() async throws {
        let (player, api) = try await TestSite.newPlayer()
        let first = try await api.userLiveTicket(userName: player)
        let second = try await api.userLiveTicket(userName: player)
        #expect(!first.isEmpty)
        #expect(first != second)
    }

    @Test("Following the player's quests hears of a quest starting")
    func liveUpdates() async throws {
        let (player, api) = try await TestSite.newPlayer()
        let admin = try await TestSite.admin()
        let questName = try await TestSite.makeQuest(for: player, admin: admin)

        let events = Events()
        let follower = LiveUpdateFollower(
            url: api.liveUpdatesURL, channel: .userQuests(userName: player),
            ticket: { try await api.userLiveTicket(userName: player) })
        let following = Task { await follower.run { await events.record($0) } }
        defer { following.cancel() }

        try await events.waitFor {
            if case .connected = $0 { true } else { false }
        }
        try await TestSite.start(questName, admin: admin)
        try await events.waitFor { $0 == .update(.questsChanged) }
        #expect(try await api.userQuests(userName: player).map(\.questName) == [questName])
    }

    @Test("The verification email can be sent again, a few times in a while")
    func verificationEmail() async throws {
        let (player, api) = try await TestSite.newPlayer()
        // The server sends it at most three times in 15 minutes.
        for _ in 1...3 {
            try await api.sendVerificationEmail(userName: player)
        }
        do {
            try await api.sendVerificationEmail(userName: player)
            Issue.record("the fourth should have been refused")
        } catch {
            #expect(EmailReminderFailure(error) == .tooManyRequests)
        }
    }

    @Test("A new player hasn't verified their email address")
    func emailNotVerified() async throws {
        let (_, api) = try await TestSite.newPlayer()
        #expect(try await api.currentUser().emailVerified == false)
    }
}

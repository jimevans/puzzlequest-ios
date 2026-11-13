import Foundation
import PuzzleQuestAPI
import Testing

@testable import PuzzleQuestKit

/// The server these tests run against, from scripts/start-test-server.sh
/// (load .test-server/env first). Without it they're skipped.
enum TestServer {
    static let environment = ProcessInfo.processInfo.environment
    static let url = environment["PQ_TEST_SERVER_URL"].flatMap(URL.init(string:))
    static let userName = environment["PQ_TEST_USER_NAME"] ?? ""
    static let password = environment["PQ_TEST_PASSWORD"] ?? ""
    static let displayName = environment["PQ_TEST_DISPLAY_NAME"] ?? ""

    static func api(tokens: any TokenStore = InMemoryTokenStore()) -> APIClient {
        APIClient(server: url!, tokens: tokens)
    }

    /// A user name no account has, different each time: failed sign-ins are
    /// limited per user name, so tests mustn't share one.
    static func nobody() -> String {
        "nobody-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

@Suite(
    "Sessions, against a real server",
    .enabled(if: TestServer.url != nil, "set PQ_TEST_SERVER_URL (see scripts/start-test-server.sh)"),
    .serialized)
struct SessionContractTests {
    @Test("Sign in, see who is signed in, and sign out")
    func signInAndOut() async throws {
        let tokens = InMemoryTokenStore()
        let api = TestServer.api(tokens: tokens)

        let (token, user) = try await api.signIn(
            userName: TestServer.userName, password: TestServer.password)
        #expect(!token.isEmpty)
        #expect(user.userName == TestServer.userName)
        #expect(user.displayName == TestServer.displayName)
        #expect(user.role == .player)

        try tokens.save(token)
        #expect(try await api.currentUser() == user)

        try await api.signOut()
        // The token no longer works.
        do {
            _ = try await api.currentUser()
            Issue.record("the session should have ended")
        } catch {
            guard case .problem(let problem) = error else {
                Issue.record("expected a problem, got \(error)")
                return
            }
            #expect(problem.type == Problem.Types.signInRequired)
            #expect(problem.status == 401)
        }
    }

    @Test("The session store signs in, restores the session, and signs out")
    func sessionStore() async throws {
        let tokens = InMemoryTokenStore()
        let api = TestServer.api(tokens: tokens)
        let first = await SessionStore(api: api, tokens: tokens)
        try await first.signIn(userName: TestServer.userName, password: TestServer.password)
        #expect(tokens.read() != nil)

        // As on the next launch.
        let next = await SessionStore(api: api, tokens: tokens)
        await next.restore()
        guard case .signedIn(let user) = await next.state else {
            Issue.record("expected to be signed in, but \(await next.state)")
            return
        }
        #expect(user.userName == TestServer.userName)

        await next.signOut()
        #expect(tokens.read() == nil)
        #expect(await next.state == .signedOut)
    }

    @Test("A session the server has ended is dropped on restoring")
    func endedSession() async throws {
        let tokens = InMemoryTokenStore()
        let api = TestServer.api(tokens: tokens)
        let (token, _) = try await api.signIn(
            userName: TestServer.userName, password: TestServer.password)
        try tokens.save(token)
        try await api.signOut()

        let session = await SessionStore(api: api, tokens: tokens)
        await session.restore()
        #expect(await session.state == .signedOut)
        #expect(tokens.read() == nil)
    }

    @Test("A wrong password is a failed sign-in")
    func wrongPassword() async {
        do {
            _ = try await TestServer.api().signIn(
                userName: TestServer.nobody(), password: "not the password")
            Issue.record("signing in should have failed")
        } catch {
            guard case .problem(let problem) = error else {
                Issue.record("expected a problem, got \(error)")
                return
            }
            #expect(problem.type == Problem.Types.signInFailed)
            #expect(problem.status == 401)
            #expect(SignInFailure(error) == .wrongUserNameOrPassword)
        }
    }

    @Test("An empty user name is an invalid request")
    func invalidRequest() async {
        do {
            _ = try await TestServer.api().signIn(userName: "", password: "x")
            Issue.record("signing in should have failed")
        } catch {
            #expect(SignInFailure(error) == .invalidRequest)
        }
    }

    @Test("Too many failed sign-ins are refused for a while")
    func tooManyAttempts() async {
        let userName = TestServer.nobody()
        var failures: [SignInFailure] = []
        // The server allows 10 failed attempts per user name in 15 minutes.
        for _ in 1...11 {
            do {
                _ = try await TestServer.api().signIn(userName: userName, password: "wrong")
            } catch {
                failures.append(SignInFailure(error))
            }
        }
        #expect(failures.first == .wrongUserNameOrPassword)
        #expect(failures.last == .tooManyAttempts)
    }

    @Test("The server serves the version of the API the app is pinned to")
    func pinnedVersion() async throws {
        let (data, _) = try await URLSession.shared.data(
            from: TestServer.url!.appending(path: "api/v1/openapi.json"))
        let served = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // The pinned release's description (api/openapi.json). Its API
        // version can be older than the release's tag (api/VERSION): a
        // release that changes only the server, such as 1.1.2, keeps the
        // API's version.
        let pinned = try JSONSerialization.jsonObject(
            with: Data(
                contentsOf: URL(filePath: #filePath)
                    .appending(path: "../../../../api/openapi.json").standardized))
            as? [String: Any]
        let servedVersion = (served?["info"] as? [String: Any])?["version"] as? String
        let pinnedVersion = (pinned?["info"] as? [String: Any])?["version"] as? String
        #expect(servedVersion != nil)
        #expect(servedVersion == pinnedVersion)
    }
}

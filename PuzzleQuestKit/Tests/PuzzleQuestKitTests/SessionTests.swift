import Foundation
import HTTPTypes
import Testing

@testable import PuzzleQuestKit

@MainActor
@Suite("Signing in, restoring the session, and signing out")
struct SessionTests {
    @Test("With no token kept, restoring asks nothing and is signed out")
    func restoreWithoutToken() async {
        let transport = FakeTransport { _ in Issue.record("nothing should be sent"); return json(500, "{}") }
        let tokens = InMemoryTokenStore()
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        await session.restore()
        #expect(session.state == .signedOut)
        #expect(transport.requests.isEmpty)
    }

    @Test("A kept token is checked with the server, sent as a Bearer token")
    func restoreWithToken() async {
        let transport = FakeTransport { _ in json(200, #"{"user":\#(aliceJSON)}"#) }
        let tokens = InMemoryTokenStore(token: "kept")
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        await session.restore()
        #expect(session.state == .signedIn(alice))
        #expect(transport.requests.map(\.operationID) == ["getCurrentSession"])
        #expect(transport.requests.first?.request.headerFields[.authorization] == "Bearer kept")
    }

    @Test("A token the server no longer accepts is dropped")
    func restoreWithEndedSession() async {
        let transport = FakeTransport { _ in problem(401, "/problems/sign-in-required") }
        let tokens = InMemoryTokenStore(token: "ended")
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        await session.restore()
        #expect(session.state == .signedOut)
        #expect(tokens.read() == nil)
    }

    @Test("When the server can't be reached, the token is kept to try again")
    func restoreWhileUnreachable() async {
        let transport = FakeTransport { _ in throw URLError(.cannotConnectToHost) }
        let tokens = InMemoryTokenStore(token: "kept")
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        await session.restore()
        #expect(session.state == .restoreFailed)
        #expect(tokens.read() == "kept")
    }

    @Test("Signing in asks for a token as an app, and keeps it")
    func signIn() async throws {
        let transport = FakeTransport { _ in
            json(201, #"{"user":\#(aliceJSON),"token":"new-token"}"#)
        }
        let tokens = InMemoryTokenStore()
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        try await session.signIn(userName: "alice", password: "secret")
        #expect(session.state == .signedIn(alice))
        #expect(tokens.read() == "new-token")
        let sent = try #require(transport.requests.first)
        #expect(sent.operationID == "signIn")
        let body = try JSONDecoder().decode([String: String].self, from: Data((sent.body ?? "").utf8))
        #expect(body == ["userName": "alice", "password": "secret", "client": "native"])
    }

    @Test("Signing out ends the session on the server, then forgets the token")
    func signOut() async {
        let transport = FakeTransport { _ in (HTTPResponse(status: .noContent), nil) }
        let tokens = InMemoryTokenStore(token: "kept")
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        await session.signOut()
        #expect(session.state == .signedOut)
        #expect(tokens.read() == nil)
        #expect(transport.requests.map(\.operationID) == ["signOut"])
        #expect(transport.requests.first?.request.headerFields[.authorization] == "Bearer kept")
    }

    @Test("Signing out without a connection still forgets the token")
    func signOutWhileUnreachable() async {
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let tokens = InMemoryTokenStore(token: "kept")
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        await session.signOut()
        #expect(session.state == .signedOut)
        #expect(tokens.read() == nil)
    }
}

@MainActor
@Suite("The sign-in screen's model")
struct SignInModelTests {
    private func model(_ transport: FakeTransport) -> (SignInModel, SessionStore) {
        let tokens = InMemoryTokenStore()
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        return (SignInModel(session: session), session)
    }

    @Test("Signing in needs a user name and a password")
    func canSignIn() {
        let (model, _) = model(FakeTransport { _ in json(500, "{}") })
        #expect(!model.canSignIn)
        model.userName = "  "
        model.password = "secret"
        #expect(!model.canSignIn)
        model.userName = "alice"
        #expect(model.canSignIn)
    }

    @Test("The user name is sent without surrounding spaces, and the password is cleared after")
    func signsIn() async throws {
        let transport = FakeTransport { _ in
            json(201, #"{"user":\#(aliceJSON),"token":"new-token"}"#)
        }
        let (model, session) = model(transport)
        model.userName = " alice "
        model.password = "secret"
        await model.signIn()
        #expect(session.state == .signedIn(alice))
        #expect(model.password.isEmpty)
        #expect(model.failure == nil)
        #expect(!model.isSigningIn)
        let body = try #require(transport.requests.first?.body)
        let sent = try JSONDecoder().decode([String: String].self, from: Data(body.utf8))
        #expect(sent["userName"] == "alice")
    }

    @Test("A failure is kept to show, and cleared by the next attempt")
    func failure() async {
        let (model, session) = model(FakeTransport { _ in problem(401, "/problems/sign-in-failed") })
        model.userName = "alice"
        model.password = "wrong"
        await model.signIn()
        #expect(model.failure == .wrongUserNameOrPassword)
        #expect(session.state == .restoring)
        #expect(model.password == "wrong")
    }
}

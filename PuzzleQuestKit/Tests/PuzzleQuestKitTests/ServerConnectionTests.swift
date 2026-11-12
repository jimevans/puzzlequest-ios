import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import PuzzleQuestKit

let staging = try! ServerOrigin(parsing: "https://staging.thepuzzlequest.com")

/// A description such as a server's `/api/v1/openapi.json`, cut down to what
/// the check reads.
func apiDescription(title: String = "PuzzleQuest API", version: String = "1.0.1") -> (
    HTTPResponse, HTTPBody?
) {
    json(200, #"{"openapi":"3.1.0","info":{"title":"\#(title)","version":"\#(version)"},"paths":{}}"#)
}

/// UserDefaults of a test's own, forgotten after.
func scratchDefaults() -> UserDefaults {
    let name = "com.thepuzzlequest.PuzzleQuest.tests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Checking a server is PuzzleQuest's")
struct ServerCheckTests {
    @Test("PuzzleQuest's API, version 1, is accepted; its description is fetched from the server")
    func accepts() async throws {
        let transport = FakeTransport { _ in apiDescription() }
        try await ServerCheck(transport: transport).check(staging)
        let sent = try #require(transport.requests.first)
        #expect(sent.baseURL == staging.url)
        #expect(sent.request.method == .get)
        #expect(sent.request.path == "/api/v1/openapi.json")
        #expect(sent.request.headerFields[.authorization] == nil)
    }

    @Test("Any version 1 will do")
    func laterVersion() async throws {
        try await ServerCheck(transport: FakeTransport { _ in apiDescription(version: "1.7.0") })
            .check(staging)
    }

    @Test(
        "Anything else isn't PuzzleQuest",
        arguments: [
            ("another API's description", apiDescription(title: "Pet Store")),
            ("not found", json(404, #"{"error":"not found"}"#)),
            ("a web page", json(200, "<html><body>Hello</body></html>", contentType: "text/html")),
            ("JSON without a title", json(200, #"{"info":{}}"#)),
            ("a server error", json(500, "{}")),
        ])
    func refuses(_: String, answer: (HTTPResponse, HTTPBody?)) async {
        let transport = FakeTransport { _ in answer }
        await #expect(throws: ServerCheckFailure.notPuzzleQuest) {
            try await ServerCheck(transport: transport).check(staging)
        }
    }

    @Test("A later version of the API can't be used")
    func unsupportedVersion() async {
        let transport = FakeTransport { _ in apiDescription(version: "2.0.0") }
        await #expect(throws: ServerCheckFailure.unsupportedVersion) {
            try await ServerCheck(transport: transport).check(staging)
        }
    }

    @Test("A server that doesn't answer is unreachable")
    func unreachable() async {
        let transport = FakeTransport { _ in throw URLError(.cannotFindHost) }
        await #expect(throws: ServerCheckFailure.unreachable) {
            try await ServerCheck(transport: transport).check(staging)
        }
    }
}

@MainActor
@Suite("Choosing the server, and switching servers")
struct ServerConnectionTests {
    let transport = FakeTransport { operationID in
        switch operationID {
        case "signOut": (HTTPResponse(status: .noContent), nil)
        case "signIn": json(201, #"{"user":\#(aliceJSON),"token":"production's"}"#)
        default: json(200, #"{"user":\#(aliceJSON)}"#)
        }
    }
    let defaults = scratchDefaults()
    let vault = InMemoryTokenVault()

    func connection(
        policy: ServerAddressPolicy = .anyAddress, fixed: ServerOrigin? = nil
    ) -> ServerConnection {
        ServerConnection(
            setting: ServerSetting(defaults: defaults, policy: policy), vault: vault, policy: policy,
            fixed: fixed,
            makeAPI: { [transport] in APIClient(server: $0.url, tokens: $1, transport: transport) })
    }

    @Test("Every build starts with Production")
    func defaultsToProduction() {
        #expect(connection(policy: .anyAddress).server == .production)
        #expect(connection(policy: .puzzleQuestDomain).server == .production)
    }

    @Test("The chosen server is remembered across launches")
    func remembered() {
        connection().switchTo(staging)
        #expect(connection().server == staging)
        connection().switchTo(.production)
        #expect(connection().server == .production)
        #expect(defaults.string(forKey: ServerSetting.key) == nil)
    }

    @Test("A remembered server the build may not use is ignored")
    func remembersOnlyAllowed() {
        connection(policy: .anyAddress).switchTo(.thisMac)
        #expect(connection(policy: .puzzleQuestDomain).server == .production)
    }

    @Test("Resetting the setting goes back to Production")
    func reset() {
        connection().switchTo(staging)
        ServerSetting(defaults: defaults, policy: .anyAddress).reset()
        #expect(connection().server == .production)
    }

    @Test("A fixed server wins over the setting, without changing it, and can't be switched")
    func fixed() {
        connection().switchTo(staging)
        let fixed = connection(fixed: .thisMac)
        #expect(fixed.server == .thisMac)
        #expect(fixed.isFixed)
        fixed.switchTo(.production)
        #expect(fixed.server == .thisMac)
        #expect(connection().server == staging)
    }

    @Test("The session talks to the server, with that server's token")
    func sessionUsesServer() async throws {
        try vault.tokens(for: staging).save("staging's")
        try vault.tokens(for: .production).save("production's")
        let connection = connection()
        connection.switchTo(staging)
        // Switching from Production forgot its token.
        #expect(vault.tokens(for: .production).read() == nil)
        await connection.session.restore()
        let sent = try #require(transport.requests.last { $0.operationID != "signOut" })
        #expect(sent.operationID == "getCurrentSession")
        #expect(sent.baseURL == staging.url.appending(path: "api/v1"))
        #expect(sent.request.headerFields[.authorization] == "Bearer staging's")
    }

    @Test("Switching signs out: the old server's token is forgotten, and that server told")
    func switchingSignsOut() async throws {
        let connection = connection()
        await connection.session.restore()
        try await connection.session.signIn(userName: "alice", password: "secret")
        #expect(vault.tokens(for: .production).read() == "production's")
        try vault.tokens(for: staging).save("staging's")
        #expect(connection.switchingSignsOut)
        let oldSession = connection.session

        connection.switchTo(.thisMac)
        #expect(connection.server == .thisMac)
        #expect(connection.session !== oldSession)
        #expect(connection.session.state == .restoring)
        #expect(vault.tokens(for: .production).read() == nil)
        // Only that server's.
        #expect(vault.tokens(for: staging).read() == "staging's")

        await connection.farewell?.value
        let farewell = try #require(transport.requests.last)
        #expect(farewell.operationID == "signOut")
        #expect(farewell.baseURL == ServerOrigin.production.url.appending(path: "api/v1"))
        #expect(farewell.request.headerFields[.authorization] == "Bearer production's")

        await connection.session.restore()
        #expect(connection.session.state == .signedOut)
        #expect(!connection.switchingSignsOut)
    }

    @Test("Switching while signed out tells no server anything")
    func switchingSignedOut() async {
        let connection = connection()
        await connection.session.restore()
        #expect(!connection.switchingSignsOut)
        connection.switchTo(staging)
        #expect(connection.farewell == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test("Switching to the same server does nothing")
    func sameServer() throws {
        try vault.tokens(for: .production).save("kept")
        let connection = connection()
        let session = connection.session
        connection.switchTo(.production)
        #expect(connection.session === session)
        #expect(vault.tokens(for: .production).read() == "kept")
        #expect(transport.requests.isEmpty)
    }
}

@MainActor
@Suite("The Options screen's model")
struct OptionsModelTests {
    let defaults = scratchDefaults()
    let vault = InMemoryTokenVault()

    func model(
        policy: ServerAddressPolicy = .anyAddress, offersThisMac: Bool = true,
        check: @escaping FakeTransport.Answer = { _ in apiDescription() }
    ) -> (OptionsModel, ServerConnection, FakeTransport) {
        let api = FakeTransport { _ in (HTTPResponse(status: .noContent), nil) }
        let connection = ServerConnection(
            setting: ServerSetting(defaults: defaults, policy: policy), vault: vault, policy: policy,
            makeAPI: { APIClient(server: $0.url, tokens: $1, transport: api) })
        let checks = FakeTransport(check)
        let model = OptionsModel(
            connection: connection, offersThisMac: offersThisMac,
            serverCheck: ServerCheck(transport: checks))
        return (model, connection, checks)
    }

    @Test("It starts with the server in use chosen")
    func startsWithCurrent() {
        #expect(model().0.choice == .production)
        model().1.switchTo(staging)
        let (model, _, _) = model()
        #expect(model.choice == .custom)
        #expect(model.customAddress == "https://staging.thepuzzlequest.com")
    }

    @Test("Signed out, choosing This Mac switches at once, without checking it")
    func choosesThisMac() {
        let (model, connection, checks) = model()
        model.choose(.thisMac)
        #expect(connection.server == .thisMac)
        #expect(model.choice == .thisMac)
        #expect(model.pendingSwitch == nil)
        #expect(checks.requests.isEmpty)
    }

    @Test("Choosing Custom waits for an address")
    func choosesCustom() {
        let (model, connection, _) = model()
        model.choose(.custom)
        #expect(model.choice == .custom)
        #expect(connection.server == .production)
        #expect(!model.canUseCustomAddress)
    }

    @Test("A custom address is checked, then used")
    func usesCustom() async throws {
        let (model, connection, checks) = model()
        model.choose(.custom)
        model.customAddress = " Staging.ThePuzzleQuest.com/ "
        await model.useCustomAddress()
        #expect(model.failure == nil)
        #expect(connection.server == staging)
        #expect(model.customAddress == "https://staging.thepuzzlequest.com")
        #expect(try #require(checks.requests.first).baseURL == staging.url)
    }

    @Test("An address the build may not use is refused without asking it anything")
    func refused() async {
        let (model, connection, checks) = model(policy: .puzzleQuestDomain, offersThisMac: false)
        model.choose(.custom)
        model.customAddress = "https://thepuzzlequest.com.evil.example"
        await model.useCustomAddress()
        #expect(model.failure == .refused(.notPuzzleQuestServer))
        #expect(connection.server == .production)
        #expect(checks.requests.isEmpty)
    }

    @Test("A server that isn't PuzzleQuest's is refused, and can be tried again")
    func notPuzzleQuest() async {
        let (model, connection, _) = model(check: { _ in json(404, "{}") })
        model.choose(.custom)
        model.customAddress = "https://example.com"
        await model.useCustomAddress()
        #expect(model.failure == .checkFailed(.notPuzzleQuest))
        #expect(connection.server == .production)
        #expect(model.canUseCustomAddress)
        #expect(!model.isChecking)
    }

    @Test("A server that can't be reached is refused")
    func unreachable() async {
        let (model, connection, _) = model(check: { _ in throw URLError(.timedOut) })
        model.choose(.custom)
        model.customAddress = "https://staging.thepuzzlequest.com"
        await model.useCustomAddress()
        #expect(model.failure == .checkFailed(.unreachable))
        #expect(connection.server == .production)
    }

    @Test("Typing the server in use does nothing")
    func sameServer() async {
        let (model, connection, checks) = model()
        model.choose(.custom)
        model.customAddress = "thepuzzlequest.com"
        let session = connection.session
        await model.useCustomAddress()
        #expect(connection.session === session)
        #expect(checks.requests.isEmpty)
        #expect(model.failure == nil)
    }

    @Test("Signed in, switching waits for confirmation")
    func confirms() throws {
        try vault.tokens(for: .production).save("kept")
        let (model, connection, _) = model()
        model.choose(.thisMac)
        #expect(model.pendingSwitch == .thisMac)
        #expect(connection.server == .production)
        // The server in use stays selected until the switch.
        #expect(model.choice == .production)
        model.confirmSwitch(to: .thisMac)
        #expect(model.choice == .thisMac)
        #expect(model.pendingSwitch == nil)
        #expect(connection.server == .thisMac)
        #expect(vault.tokens(for: .production).read() == nil)
    }

    @Test("Signed in, not confirming changes nothing")
    func cancels() throws {
        try vault.tokens(for: .production).save("kept")
        let (model, connection, _) = model()
        model.choose(.thisMac)
        model.cancelSwitch()
        #expect(model.pendingSwitch == nil)
        #expect(model.choice == .production)
        #expect(connection.server == .production)
        #expect(vault.tokens(for: .production).read() == "kept")
    }

    @Test("Release builds don't offer This Mac")
    func noThisMac() {
        let (model, connection, _) = model(policy: .puzzleQuestDomain, offersThisMac: false)
        model.choose(.thisMac)
        #expect(connection.server == .production)
        #expect(model.choice == .production)
    }
}

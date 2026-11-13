import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import PuzzleQuestAPI

/// The PuzzleQuest API, through the client generated from its pinned
/// description. Every method either returns what the app needs or throws an
/// `APIError`.
public struct APIClient: Sendable {
    /// The generated client, for this package's own code and tests.
    package let client: Client

    /// The site, which puzzles' media paths are on.
    public let server: URL

    /// The live-update websocket's address: `/api/v1/updates` on the site,
    /// over `wss:` (or `ws:` for a site on plain HTTP, such as a local one).
    public let liveUpdatesURL: URL

    /// - Parameters:
    ///   - server: the site, such as https://thepuzzlequest.com; the API is
    ///     under its `/api/v1`.
    ///   - tokens: where the session's token is kept, sent with every request.
    public init(server: URL, tokens: any TokenStore) {
        self.init(server: server, tokens: tokens, transport: URLSessionTransport())
    }

    package init(server: URL, tokens: any TokenStore, transport: any ClientTransport) {
        self.server = server
        var socket = URLComponents(
            url: server.appending(path: "api/v1/updates"), resolvingAgainstBaseURL: false)!
        socket.scheme = socket.scheme == "http" ? "ws" : "wss"
        liveUpdatesURL = socket.url!
        client = Client(
            serverURL: server.appending(path: "api/v1"),
            configuration: Configuration(dateTranscoder: APIDateTranscoder()),
            transport: transport,
            // The first middleware sees the request first and the response
            // last, so problems are read after anything else has run.
            middlewares: [ProblemMiddleware(), BearerTokenMiddleware(tokens: tokens)]
        )
    }

    /// Signs in as an app, which is given the session's token to keep.
    public func signIn(userName: String, password: String) async throws(APIError) -> (
        token: String, user: SignedInUser
    ) {
        let output = try await call {
            try await client.signIn(
                body: .json(.init(userName: userName, password: password, client: .native)))
        }
        guard case .created(let created) = output, case .json(let session) = created.body else {
            throw .unexpectedResponse("signIn: \(output)")
        }
        guard let token = session.token else {
            throw .unexpectedResponse("signIn: the session has no token")
        }
        return (token, SignedInUser(session.user))
    }

    /// Who the session's token belongs to.
    public func currentUser() async throws(APIError) -> SignedInUser {
        let output = try await call { try await client.getCurrentSession() }
        guard case .ok(let ok) = output, case .json(let session) = ok.body else {
            throw .unexpectedResponse("getCurrentSession: \(output)")
        }
        return SignedInUser(session.user)
    }

    /// Ends the session whose token is sent.
    public func signOut() async throws(APIError) {
        let output = try await call { try await client.signOut() }
        guard case .noContent = output else {
            throw .unexpectedResponse("signOut: \(output)")
        }
    }

    /// Every quest the user plays whose entry has started, fetching each page
    /// of the list in turn.
    public func userQuests(userName: String) async throws(APIError) -> [QuestSummary] {
        try await allPages { (after) throws(APIError) in
            let output = try await call {
                try await client.listUserQuests(
                    path: .init(userName: userName), query: .init(after: after))
            }
            guard case .ok(let ok) = output, case .json(let page) = ok.body else {
                throw .unexpectedResponse("listUserQuests: \(output)")
            }
            return (page.items.map(QuestSummary.init), page.next)
        }
    }

    /// A ticket for one connection to the live-update websocket to follow the
    /// user's list of quests. Each can be used once.
    public func userLiveTicket(userName: String) async throws(APIError) -> String {
        let output = try await call {
            try await client.createUserLiveTicket(path: .init(userName: userName))
        }
        guard case .created(let created) = output, case .json(let ticket) = created.body else {
            throw .unexpectedResponse("createUserLiveTicket: \(output)")
        }
        return ticket.ticket
    }

    /// A quest as its player sees it, or nil if it isn't theirs to see: not
    /// found, or with no entry of theirs, as once the puzzle master has reset
    /// it.
    public func playerQuest(questName: String) async throws(APIError) -> PlayerQuest? {
        let output: Operations.GetQuest.Output
        do throws(APIError) {
            output = try await call {
                try await client.getQuest(path: .init(questName: questName))
            }
        } catch .problem(let problem) where problem.status == 404 {
            return nil
        }
        guard case .ok(let ok) = output, case .json(let quest) = ok.body else {
            throw .unexpectedResponse("getQuest: \(output)")
        }
        return PlayerQuest(quest)
    }

    /// A quest's standings, as anyone who may follow it sees them.
    public func standings(questName: String) async throws(APIError) -> Standings {
        let output = try await call {
            try await client.getSpectatorQuest(path: .init(questName: questName))
        }
        guard case .ok(let ok) = output, case .json(let quest) = ok.body else {
            throw .unexpectedResponse("getSpectatorQuest: \(output)")
        }
        return Standings(quest)
    }

    /// A ticket for one connection to the live-update websocket to follow a
    /// quest. Each can be used once.
    public func questLiveTicket(questName: String) async throws(APIError) -> String {
        let output = try await call {
            try await client.createLiveTicket(path: .init(questName: questName))
        }
        guard case .created(let created) = output, case .json(let ticket) = created.body else {
            throw .unexpectedResponse("createLiveTicket: \(output)")
        }
        return ticket.ticket
    }

    /// A stop's puzzle as its players see it, or nil if it isn't theirs to
    /// see: not reached, or gone, as once the puzzle master has reset the
    /// quest.
    public func playerPuzzle(
        questName: String, puzzleName: String
    ) async throws(APIError) -> PlayerPuzzle? {
        let output: Operations.GetPlayerPuzzle.Output
        do throws(APIError) {
            output = try await call {
                try await client.getPlayerPuzzle(
                    path: .init(questName: questName, puzzleName: puzzleName))
            }
        } catch .problem(let problem) where problem.status == 404 {
            return nil
        }
        guard case .ok(let ok) = output, case .json(let puzzle) = ok.body else {
            throw .unexpectedResponse("getPlayerPuzzle: \(output)")
        }
        return PlayerPuzzle(puzzle, server: server)
    }

    /// Starts the puzzle the players have found, with its activation code,
    /// typed or read from its QR code.
    /// - Parameter connectionId: the live-update connection, which then isn't
    ///   sent the update about it.
    public func activatePuzzle(
        questName: String, puzzleName: String, code: String, connectionId: String?
    ) async throws(APIError) {
        let output = try await call {
            try await client.activatePuzzle(
                path: .init(questName: questName, puzzleName: puzzleName),
                body: .json(.init(activationCode: code, connectionId: connectionId)))
        }
        guard case .ok = output else {
            throw .unexpectedResponse("activatePuzzle: \(output)")
        }
    }

    /// Guesses a puzzle's solution. A wrong guess is a problem,
    /// `/problems/wrong-answer`.
    public func attemptSolution(
        questName: String, puzzleName: String, guess: String, connectionId: String?
    ) async throws(APIError) {
        let output = try await call {
            try await client.attemptSolution(
                path: .init(questName: questName, puzzleName: puzzleName),
                body: .json(.init(guess: guess, connectionId: connectionId)))
        }
        guard case .ok = output else {
            throw .unexpectedResponse("attemptSolution: \(output)")
        }
    }

    /// Reveals a puzzle's next hint, adding its penalty to the players' time.
    public func revealHint(
        questName: String, puzzleName: String, connectionId: String?
    ) async throws(APIError) {
        let output = try await call {
            try await client.revealHint(
                path: .init(questName: questName, puzzleName: puzzleName),
                body: .json(.init(connectionId: connectionId)))
        }
        guard case .ok = output else {
            throw .unexpectedResponse("revealHint: \(output)")
        }
    }

    /// Sends the session's push notifications to this phone, replacing any
    /// phone it had; signing out ends them. Every kind is asked for.
    public func setPushTarget(token: String, environment: PushEnvironment) async throws(APIError) {
        let output = try await call {
            try await client.setPushTarget(
                body: .json(
                    .init(
                        platform: .init(value1: .ios), token: token,
                        environment: .init(
                            value1: environment == .development ? .development : .production))))
        }
        guard case .noContent = output else {
            throw .unexpectedResponse("setPushTarget: \(output)")
        }
    }

    /// Answers the challenge the player's entry is waiting for.
    /// - Returns: the confirmation to show the venue's staff.
    public func answerChallenge(
        questName: String, answer: String
    ) async throws(APIError) -> ChallengeAnswer {
        let output = try await call {
            try await client.answerChallenge(
                path: .init(questName: questName), body: .json(.init(answer: answer)))
        }
        guard case .ok(let ok) = output, case .json(let answered) = ok.body else {
            throw .unexpectedResponse("answerChallenge: \(output)")
        }
        return ChallengeAnswer(answeredAt: answered.answeredAt, confirmation: answered.confirmation)
    }

    /// Sends the user another email with the link that verifies their address.
    public func sendVerificationEmail(userName: String) async throws(APIError) {
        let output = try await call {
            try await client.sendVerificationEmail(path: .init(userName: userName))
        }
        guard case .noContent = output else {
            throw .unexpectedResponse("sendVerificationEmail: \(output)")
        }
    }

    /// Runs a generated client's call, turning whatever it throws into an
    /// `APIError`. The client wraps errors from the transport and middleware
    /// in a `ClientError`; what matters is the error inside.
    private func call<Output>(
        _ operation: () async throws -> Output
    ) async throws(APIError) -> Output {
        do {
            return try await operation()
        } catch let error as ClientError {
            throw APIError(error.underlyingError)
        } catch {
            throw APIError(error)
        }
    }
}

/// Gets everything in one of the API's paged lists: each page names the
/// cursor (`next`) to send as `after` for the page that follows, and nil on
/// the last.
/// - Parameter fetchPage: fetches the page after a cursor, or the first page
///   for nil, returning its items and the next cursor.
func allPages<Item>(
    _ fetchPage: (_ after: String?) async throws(APIError) -> (items: [Item], next: String?)
) async throws(APIError) -> [Item] {
    var items: [Item] = []
    var after: String?
    repeat {
        let page = try await fetchPage(after)
        items += page.items
        after = page.next
    } while after != nil
    return items
}

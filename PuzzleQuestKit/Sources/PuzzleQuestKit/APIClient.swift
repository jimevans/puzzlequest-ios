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

    /// - Parameters:
    ///   - server: the site, such as https://thepuzzlequest.com; the API is
    ///     under its `/api/v1`.
    ///   - tokens: where the session's token is kept, sent with every request.
    public init(server: URL, tokens: any TokenStore) {
        self.init(server: server, tokens: tokens, transport: URLSessionTransport())
    }

    package init(server: URL, tokens: any TokenStore, transport: any ClientTransport) {
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

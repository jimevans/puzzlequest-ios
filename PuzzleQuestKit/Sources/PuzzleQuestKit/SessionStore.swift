import Foundation
import Observation

/// Whether anyone is signed in, kept across launches by the session's token.
@MainActor
@Observable
public final class SessionStore {
    public enum State: Equatable, Sendable {
        /// Checking a token kept from before with the server.
        case restoring
        case signedOut
        case signedIn(SignedInUser)
        /// A token was kept, but the server couldn't say whose it is (it
        /// couldn't be reached, or failed). The token is kept to try again.
        case restoreFailed
    }

    public private(set) var state: State = .restoring

    /// The API, sending this session's token; screens make their calls with it.
    public let api: APIClient
    private let tokens: any TokenStore

    public init(api: APIClient, tokens: any TokenStore) {
        self.api = api
        self.tokens = tokens
    }

    /// Picks up the session kept from before, if it hasn't ended. A token the
    /// server no longer accepts is dropped.
    public func restore() async {
        guard tokens.read() != nil else {
            state = .signedOut
            return
        }
        state = .restoring
        do throws(APIError) {
            state = .signedIn(try await api.currentUser())
        } catch .problem(let problem) where problem.status == 401 {
            tokens.delete()
            state = .signedOut
        } catch {
            state = .restoreFailed
        }
    }

    /// Asks the server again who is signed in, to pick up changes made
    /// elsewhere, such as an email address verified on the website. If the
    /// session has ended, it's forgotten; if the server can't be reached,
    /// nothing changes.
    public func refreshUser() async {
        guard case .signedIn = state else { return }
        do throws(APIError) {
            let user = try await api.currentUser()
            // Signed out while asking, or nothing has changed (setting the
            // same value would still redraw every screen that reads it).
            guard case .signedIn(let known) = state, known != user else { return }
            state = .signedIn(user)
        } catch .problem(let problem) where problem.status == 401 {
            tokens.delete()
            state = .signedOut
        } catch {
            // Keep what's known.
        }
    }

    public func signIn(userName: String, password: String) async throws(APIError) {
        let (token, user) = try await api.signIn(userName: userName, password: password)
        // If the Keychain won't keep it, the session lasts until the app quits.
        try? tokens.save(token)
        state = .signedIn(user)
    }

    /// Deletes the signed-in user's own account, with their password. The
    /// server ends its sessions, so it's forgotten here too.
    public func deleteAccount(password: String) async throws(APIError) {
        guard case .signedIn(let user) = state else { return }
        try await api.deleteAccount(userName: user.userName, password: password)
        tokens.delete()
        state = .signedOut
    }

    /// Ends the session on the server, then forgets it here, even if the
    /// server couldn't be told.
    public func signOut() async {
        try? await api.signOut()
        tokens.delete()
        state = .signedOut
    }
}

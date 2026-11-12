import Foundation
import Observation

/// The server the person has chosen, kept in `UserDefaults` (it isn't
/// secret; the session's token is in the Keychain).
@MainActor
public struct ServerSetting {
    static let key = "server"

    private let defaults: UserDefaults
    private let policy: ServerAddressPolicy

    /// - Parameter policy: which servers this build may use; a stored server
    ///   it doesn't allow is ignored.
    public init(defaults: UserDefaults = .standard, policy: ServerAddressPolicy) {
        self.defaults = defaults
        self.policy = policy
    }

    /// The chosen server, or Production if none has been chosen.
    public func read() -> ServerOrigin {
        guard let stored = defaults.string(forKey: Self.key),
            let server = try? policy.check(stored)
        else { return .production }
        return server
    }

    public func save(_ server: ServerOrigin) {
        if server == .production {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(server.url.absoluteString, forKey: Self.key)
        }
    }

    /// Goes back to Production, as the UI tests do at launch.
    public func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// The server the app talks to, and the session with it. Switching servers
/// signs out: the old server's token is forgotten, and a new session (with
/// its own API client) is made for the new one, so nothing of one server's
/// is ever sent to another.
@MainActor
@Observable
public final class ServerConnection {
    public private(set) var server: ServerOrigin
    /// The session with `server`; a new one each time the server changes.
    public private(set) var session: SessionStore
    /// Which servers this build may use.
    public let policy: ServerAddressPolicy
    /// Whether the server is fixed for this run (a debug build's
    /// `PQ_SERVER_URL`, as the UI tests set), so it can't be chosen.
    public let isFixed: Bool

    private let setting: ServerSetting
    private let vault: any TokenVault
    private let makeAPI: (ServerOrigin, any TokenStore) -> APIClient
    /// Telling the old server its session has ended, after switching; tests
    /// wait for it.
    @ObservationIgnored package private(set) var farewell: Task<Void, Never>?

    /// - Parameters:
    ///   - setting: the chosen server.
    ///   - vault: each server's token.
    ///   - fixed: a server to use for this run instead of the chosen one,
    ///     without changing the setting.
    public convenience init(
        setting: ServerSetting, vault: any TokenVault, policy: ServerAddressPolicy,
        fixed: ServerOrigin? = nil
    ) {
        self.init(
            setting: setting, vault: vault, policy: policy, fixed: fixed,
            makeAPI: { APIClient(server: $0.url, tokens: $1) })
    }

    package init(
        setting: ServerSetting, vault: any TokenVault, policy: ServerAddressPolicy,
        fixed: ServerOrigin? = nil,
        makeAPI: @escaping (ServerOrigin, any TokenStore) -> APIClient
    ) {
        let server = fixed ?? setting.read()
        self.server = server
        self.setting = setting
        self.vault = vault
        self.policy = policy
        self.makeAPI = makeAPI
        isFixed = fixed != nil
        let tokens = vault.tokens(for: server)
        session = SessionStore(api: makeAPI(server, tokens), tokens: tokens)
    }

    /// Whether switching away would sign someone out, so they're asked first:
    /// someone is signed in, or a session is kept to try again.
    public var switchingSignsOut: Bool {
        if case .signedIn = session.state { return true }
        return vault.tokens(for: server).read() != nil
    }

    /// Uses another server from now on, and remembers the choice. Anyone
    /// signed in is signed out: the token is forgotten at once, and the old
    /// server is told the session has ended without waiting for it (it may be
    /// the one that can't be reached). The new server's session starts out
    /// as one does at launch, needing `restore()`. Switching to the same
    /// server does nothing.
    public func switchTo(_ newServer: ServerOrigin) {
        guard newServer != server, !isFixed else { return }
        let oldTokens = vault.tokens(for: server)
        if let token = oldTokens.read() {
            oldTokens.delete()
            let oldAPI = makeAPI(server, InMemoryTokenStore(token: token))
            farewell = Task { try? await oldAPI.signOut() }
        }
        setting.save(newServer)
        server = newServer
        let tokens = vault.tokens(for: newServer)
        session = SessionStore(api: makeAPI(newServer, tokens), tokens: tokens)
    }
}

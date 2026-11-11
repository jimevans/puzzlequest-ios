import Foundation
import Security
import Synchronization

/// Where the session's token is kept between launches.
public protocol TokenStore: Sendable {
    func read() -> String?
    func save(_ token: String) throws
    func delete()
}

/// A session's token for each server, kept apart so that one server's token
/// is never sent to another.
public protocol TokenVault: Sendable {
    /// Where the token for a server is kept.
    func tokens(for server: ServerOrigin) -> any TokenStore
    /// Forgets every server's token.
    func forgetAll()
}

/// Tokens in the Keychain, one item for each server (its account is the
/// server's origin), readable only on this device once it has been unlocked
/// since starting up, and never restored onto another device.
public struct KeychainTokenVault: TokenVault {
    /// The Keychain items' service; tests use their own.
    let service: String

    public init() {
        self.init(service: "com.thepuzzlequest.PuzzleQuest.session")
    }

    init(service: String) {
        self.service = service
    }

    public func tokens(for server: ServerOrigin) -> any TokenStore {
        KeychainTokenStore(service: service, account: server.url.absoluteString)
    }

    public func forgetAll() {
        // Without an account, the query matches every server's item. iOS
        // deletes every match at once, but the Mac's file-based Keychain
        // (where `swift test` runs) one at a time, so delete until none is
        // left (with a limit, in case deleting keeps failing).
        let query = KeychainTokenStore.query(service: service, account: nil) as CFDictionary
        var deletions = 0
        while deletions < 100, SecItemDelete(query) == errSecSuccess {
            deletions += 1
        }
    }
}

/// One server's token in the Keychain.
public struct KeychainTokenStore: TokenStore {
    let service: String
    let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    static func query(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        #if !os(macOS)
            // iOS always uses this Keychain; on a Mac (where `swift test`
            // runs) it needs an entitlement that test programs don't have.
            query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private var query: [String: Any] {
        Self.query(service: service, account: account)
    }

    public func read() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        delete()
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// The Keychain refused to keep the token.
public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// A token kept only in memory, for tests and previews.
public final class InMemoryTokenStore: TokenStore {
    private let token: Mutex<String?>

    public init(token: String? = nil) {
        self.token = Mutex(token)
    }

    public func read() -> String? { token.withLock { $0 } }
    public func save(_ token: String) { self.token.withLock { $0 = token } }
    public func delete() { token.withLock { $0 = nil } }
}

/// Each server's token kept only in memory, for tests and previews.
public final class InMemoryTokenVault: TokenVault {
    private let stores = Mutex<[ServerOrigin: InMemoryTokenStore]>([:])

    public init(tokens: [ServerOrigin: String] = [:]) {
        stores.withLock { stores in
            for (server, token) in tokens {
                stores[server] = InMemoryTokenStore(token: token)
            }
        }
    }

    public func tokens(for server: ServerOrigin) -> any TokenStore {
        stores.withLock { stores in
            if let store = stores[server] { return store }
            let store = InMemoryTokenStore()
            stores[server] = store
            return store
        }
    }

    public func forgetAll() {
        stores.withLock { $0.values.forEach { $0.delete() } }
    }
}

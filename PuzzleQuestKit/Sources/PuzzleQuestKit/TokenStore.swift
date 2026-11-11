import Foundation
import Security
import Synchronization

/// Where the session's token is kept between launches.
public protocol TokenStore: Sendable {
    func read() -> String?
    func save(_ token: String) throws
    func delete()
}

/// The token in the Keychain, readable only on this device once it has been
/// unlocked since starting up, and never restored onto another device.
public struct KeychainTokenStore: TokenStore {
    /// The Keychain item's service; tests use their own.
    let service: String

    public init() {
        self.init(service: "com.thepuzzlequest.PuzzleQuest.session")
    }

    init(service: String) {
        self.service = service
    }

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "session",
        ]
        #if !os(macOS)
            // iOS always uses this Keychain; on a Mac (where `swift test`
            // runs) it needs an entitlement that test programs don't have.
            query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
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

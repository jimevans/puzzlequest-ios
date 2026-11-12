import Foundation
import PuzzleQuestKit

/// How this build chooses its server. Every build starts with Production
/// (https://thepuzzlequest.com), and the person can choose another in
/// Options: a release build only PuzzleQuest's own servers, a debug build
/// any, including this Mac's.
enum AppServer {
    #if DEBUG
        static let policy = ServerAddressPolicy.anyAddress
        static let offersThisMac = true
    #else
        static let policy = ServerAddressPolicy.puzzleQuestDomain
        static let offersThisMac = false
    #endif

    /// The server and its session, as the app launches.
    static func connect() -> ServerConnection {
        let setting = ServerSetting(policy: policy)
        let vault = KeychainTokenVault()
        var fixed: ServerOrigin?
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            // The UI tests start each run signed out of every server, and
            // with the server setting as a new install has it.
            if environment["PQ_SIGNED_OUT"] == "1" {
                vault.forgetAll()
            }
            if environment["PQ_RESET_SERVER"] == "1" {
                setting.reset()
            }
            // A debug build can be pointed at a server for one run with the
            // PQ_SERVER_URL environment variable, as most UI tests do. It
            // wins over the setting, without changing it.
            if let address = environment["PQ_SERVER_URL"] {
                guard let server = try? policy.check(address) else {
                    fatalError("PQ_SERVER_URL isn't a server's address: \(address)")
                }
                fixed = server
            }
        #endif
        return ServerConnection(setting: setting, vault: vault, policy: policy, fixed: fixed)
    }
}

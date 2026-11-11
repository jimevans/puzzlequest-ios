import Foundation

enum ServerAddress {
    /// The site the app uses: Info.plist's `PQServerURL`, from the
    /// `PQ_SERVER_URL` build setting (a local server in debug builds,
    /// https://thepuzzlequest.com in release builds). A debug build can be
    /// pointed elsewhere with the `PQ_SERVER_URL` environment variable, as the
    /// UI tests do.
    static var current: URL {
        #if DEBUG
            if let address = ProcessInfo.processInfo.environment["PQ_SERVER_URL"],
                let url = URL(string: address)
            {
                return url
            }
        #endif
        guard let address = Bundle.main.object(forInfoDictionaryKey: "PQServerURL") as? String,
            let url = URL(string: address)
        else {
            fatalError("Info.plist has no valid PQServerURL")
        }
        return url
    }
}

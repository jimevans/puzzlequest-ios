import PuzzleQuestKit
import SwiftUI

@main
struct PuzzleQuestApp: App {
    @State private var session: SessionStore

    init() {
        let tokens = KeychainTokenStore()
        #if DEBUG
            // The UI tests start each run signed out.
            if ProcessInfo.processInfo.environment["PQ_SIGNED_OUT"] == "1" {
                tokens.delete()
            }
        #endif
        let api = APIClient(server: ServerAddress.current, tokens: tokens)
        _session = State(initialValue: SessionStore(api: api, tokens: tokens))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}

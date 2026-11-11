import PuzzleQuestKit
import SwiftUI

@main
struct PuzzleQuestApp: App {
    @State private var connection = AppServer.connect()

    var body: some Scene {
        WindowGroup {
            RootView()
                // A new server brings a new session: `.id` makes SwiftUI
                // build every screen afresh for it, dropping the old
                // session's screens and their state (and any sheet, such as
                // Options, open over them), and running their `.task`s again.
                .id(connection.server)
                .environment(connection)
                .environment(connection.session)
                // VoiceOver hears which server is now in use.
                .onChange(of: connection.server) { _, server in
                    AccessibilityNotification.Announcement(
                        String(localized: "Now using \(server.displayName)")
                    ).post()
                }
        }
    }
}

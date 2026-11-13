import PuzzleQuestKit
import SwiftUI

/// What staff and administrators see: the app is for players, and their tools
/// are on the website.
struct WebsiteNoteView: View {
    let user: SignedInUser
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var session
    @State private var isSigningOut = false
    @State private var showingOptions = false

    private var website: URL { connection.server.url }

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Your tools are on the website", systemImage: "safari")
            } description: {
                Text(
                    "Signed in as \(user.displayName). This app is for players; staff and administrators use PuzzleQuest on the website."
                )
                .accessibilityIdentifier("website.note")
            } actions: {
                Link(destination: website) {
                    Text("Open \(connection.server.displayName)")
                }
                .prominentButton()
                .accessibilityIdentifier("website.open")
                Button("Sign out") {
                    isSigningOut = true
                    Task { await session.signOut() }
                }
                .disabled(isSigningOut)
                .accessibilityIdentifier("website.sign-out")
            }
            .navigationTitle("PuzzleQuest")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Options", systemImage: "gearshape") { showingOptions = true }
                        .accessibilityIdentifier("website.options")
                }
            }
            .sheet(isPresented: $showingOptions) {
                OptionsView(connection: connection)
            }
        }
    }
}

#Preview {
    let connection = ServerConnection(
        setting: ServerSetting(defaults: UserDefaults(suiteName: "preview")!, policy: .anyAddress),
        vault: InMemoryTokenVault(), policy: .anyAddress, fixed: .thisMac)
    WebsiteNoteView(
        user: SignedInUser(userName: "helper", displayName: "Helper", role: .staff, emailVerified: true)
    )
    .environment(connection)
    .environment(connection.session)
}

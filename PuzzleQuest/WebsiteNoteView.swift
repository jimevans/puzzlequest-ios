import PuzzleQuestKit
import SwiftUI

/// What staff and administrators see: the app is for players, and their tools
/// are on the website.
struct WebsiteNoteView: View {
    let user: SignedInUser
    @Environment(SessionStore.self) private var session
    @State private var isSigningOut = false

    private let website = ServerAddress.current

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
                    Text("Open \(website.host() ?? website.absoluteString)")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("website.open")
                Button("Sign out") {
                    isSigningOut = true
                    Task { await session.signOut() }
                }
                .disabled(isSigningOut)
                .accessibilityIdentifier("website.sign-out")
            }
            .navigationTitle("PuzzleQuest")
        }
    }
}

#Preview {
    let tokens = InMemoryTokenStore()
    WebsiteNoteView(
        user: SignedInUser(userName: "helper", displayName: "Helper", role: .staff, emailVerified: true)
    )
    .environment(
        SessionStore(
            api: APIClient(server: URL(string: "http://localhost:3000")!, tokens: tokens),
            tokens: tokens))
}

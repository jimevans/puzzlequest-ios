import PuzzleQuestKit
import SwiftUI

/// A placeholder for the signed-in app.
struct SignedInView: View {
    let user: SignedInUser
    @Environment(SessionStore.self) private var session
    @State private var isSigningOut = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Signed in as \(user.displayName)")
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("signed-in.name")
                Button("Sign out") {
                    isSigningOut = true
                    Task { await session.signOut() }
                }
                .buttonStyle(.bordered)
                .disabled(isSigningOut)
                .accessibilityIdentifier("signed-in.sign-out")
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("PuzzleQuest")
        }
    }
}

#Preview {
    let tokens = InMemoryTokenStore()
    SignedInView(user: SignedInUser(userName: "alex", displayName: "Alex", role: .player))
        .environment(
            SessionStore(
                api: APIClient(server: URL(string: "http://localhost:3000")!, tokens: tokens),
                tokens: tokens))
}

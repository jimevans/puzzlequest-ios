import PuzzleQuestKit
import SwiftUI

/// Shows sign-in or the signed-in app, once the session kept from before has
/// been checked: a player's quests, or for staff and administrators, a note
/// that their tools are on the website.
struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .restoring:
                ProgressView("Signing in…")
            case .signedOut:
                SignInView(session: session)
            case .signedIn(let user):
                switch user.homeScreen {
                case .quests:
                    HomeView(user: user, session: session)
                case .website:
                    WebsiteNoteView(user: user)
                }
            case .restoreFailed:
                RestoreFailedView()
            }
        }
        .task { await session.restore() }
    }
}

/// A session was kept, but the server couldn't confirm it.
struct RestoreFailedView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        ContentUnavailableView {
            Label("Can't reach PuzzleQuest", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Check your internet connection, then try again.")
        } actions: {
            Button("Try again") { Task { await session.restore() } }
                .prominentButton()
                .accessibilityIdentifier("restore.retry")
            Button("Sign out") { Task { await session.signOut() } }
                .accessibilityIdentifier("restore.sign-out")
        }
    }
}

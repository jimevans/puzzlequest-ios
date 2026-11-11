import PuzzleQuestKit
import SwiftUI

/// A player's home: the quests they play, kept up to date as they change, and
/// a reminder to verify their email address until they have.
struct HomeView: View {
    let user: SignedInUser
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: HomeModel
    @State private var isSigningOut = false
    /// Whether the app has been in the background since it was last active.
    @State private var wasInBackground = false

    init(user: SignedInUser, session: SessionStore) {
        self.user = user
        // @State keeps the first model it's given for as long as the view is
        // on screen; later calls to init don't replace it.
        _model = State(initialValue: HomeModel(user: user, api: session.api))
    }

    var body: some View {
        NavigationStack {
            List {
                if !user.emailVerified {
                    Section {
                        EmailReminderView(model: model.emailReminder)
                    }
                }
                Section {
                    quests
                }
            }
            .navigationTitle("Your quests")
            .navigationDestination(for: QuestRoute.self) { route in
                QuestPlaceholderView(route: route)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    accountMenu
                }
            }
            .refreshable { await refresh() }
            #if DEBUG
                .overlay(alignment: .topLeading) { liveUpdatesMarker }
            #endif
        }
        // Each .task runs while the view is on screen, and is cancelled when
        // it goes away (as on signing out), which stops following.
        .task { await model.load() }
        .task(id: model.followGeneration) { await model.followLiveUpdates() }
        // Back in the foreground (from the background, which passes through
        // inactive on the way), reconnect and fetch again: changes may have
        // been missed meanwhile.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasInBackground = true
            case .active where wasInBackground:
                wasInBackground = false
                Task {
                    async let quests: Void = model.returnedToForeground()
                    async let user: Void = session.refreshUser()
                    _ = await (quests, user)
                }
            default:
                break
            }
        }
        // VoiceOver hears when the list changes by itself, but not the clocks.
        .onChange(of: model.liveChanges) {
            AccessibilityNotification.Announcement(String(localized: "Your quests were updated"))
                .post()
        }
        .onChange(of: model.loadFailed) { _, failed in
            if failed && model.quests == nil {
                AccessibilityNotification.Announcement(String(localized: Self.loadFailedMessage))
                    .post()
            }
        }
    }

    private static let loadFailedMessage: LocalizedStringResource =
        "Couldn't load your quests. Check your connection and try again."

    @ViewBuilder
    private var quests: some View {
        if let quests = model.quests {
            if quests.isEmpty {
                Text("You have no quests yet.")
                    .accessibilityIdentifier("home.empty")
            } else {
                ForEach(quests) { quest in
                    NavigationLink(value: QuestRoute(quest)) {
                        QuestRow(quest: quest)
                    }
                    .accessibilityIdentifier("home.quest.\(quest.questName)")
                }
            }
        } else if model.loadFailed {
            VStack(alignment: .leading, spacing: 12) {
                // An icon as well as color, so it doesn't rely on color alone.
                Label {
                    Text(Self.loadFailedMessage)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("home.error")
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home.retry")
            }
        } else {
            ProgressView("Loading your quests…")
                .frame(maxWidth: .infinity)
        }
    }

    #if DEBUG
        /// For the UI tests only (launched with PQ_UI_TESTING=1): whether live
        /// updates are connected, as the web app's data-live-updates attribute
        /// says, so a test can wait for it before changing something.
        @ViewBuilder
        private var liveUpdatesMarker: some View {
            if ProcessInfo.processInfo.environment["PQ_UI_TESTING"] == "1" {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: "Live updates"))
                    .accessibilityValue(Text(verbatim: model.isLive ? "connected" : "connecting"))
                    .accessibilityIdentifier("home.live-updates")
            }
        }
    #endif

    private var accountMenu: some View {
        Menu {
            Section("Signed in as \(user.displayName)") {
                // A menu's items don't keep accessibility identifiers, so the
                // UI tests find this by its label.
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    isSigningOut = true
                    Task { await session.signOut() }
                }
            }
        } label: {
            Label("Account", systemImage: "person.crop.circle")
        }
        .disabled(isSigningOut)
        .accessibilityIdentifier("home.account")
    }

    /// Fetches the quests again, and who is signed in, in case their email
    /// address has been verified since.
    private func refresh() async {
        async let quests: Void = model.load()
        async let user: Void = session.refreshUser()
        _ = await (quests, user)
    }
}

/// Where tapping a quest goes.
struct QuestRoute: Hashable {
    let questName: String
    let displayName: String

    init(_ quest: QuestSummary) {
        questName = quest.questName
        displayName = quest.displayName
    }
}

/// Stands in for the quest's own screen, which comes next.
struct QuestPlaceholderView: View {
    let route: QuestRoute

    var body: some View {
        ContentUnavailableView {
            Label(route.displayName, systemImage: "map")
        } description: {
            Text("Coming soon")
                .accessibilityIdentifier("quest.placeholder")
        }
        .navigationTitle(route.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    let tokens = InMemoryTokenStore()
    let session = SessionStore(
        api: APIClient(server: URL(string: "http://localhost:3000")!, tokens: tokens),
        tokens: tokens)
    HomeView(
        user: SignedInUser(
            userName: "alex", displayName: "Alex", role: .player, emailVerified: false),
        session: session
    )
    .environment(session)
}

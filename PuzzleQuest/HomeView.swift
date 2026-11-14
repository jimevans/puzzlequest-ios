import PuzzleQuestKit
import SwiftUI

/// A player's home: the quests they play, kept up to date as they change, and
/// a reminder to verify their email address until they have.
struct HomeView: View {
    let user: SignedInUser
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PushRegistrar.self) private var push
    @State private var model: HomeModel
    /// The screens open over the list: a quest, and what it opens (a puzzle,
    /// a stop, the messages), each a route of its own type, so a
    /// `NavigationPath`, which holds any. A tapped notification replaces it.
    @State private var path = NavigationPath()
    @State private var isSigningOut = false
    @State private var showingOptions = false
    @State private var deletingAccount = false
    /// Whether the app has been in the background since it was last active.
    @State private var wasInBackground = false

    init(user: SignedInUser, session: SessionStore) {
        self.user = user
        // @State keeps the first model it's given for as long as the view is
        // on screen; later calls to init don't replace it.
        _model = State(initialValue: HomeModel(user: user, api: session.api))
    }

    var body: some View {
        NavigationStack(path: $path) {
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
                QuestView(route: route, api: session.api)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    accountMenu
                }
            }
            .refreshable { await refresh() }
            .sheet(isPresented: $showingOptions) {
                OptionsView(connection: connection)
            }
            .sheet(isPresented: $deletingAccount) {
                DeleteAccountView(session: session)
            }
            #if DEBUG
                .overlay(alignment: .topLeading) { liveUpdatesMarker }
            #endif
        }
        // Each .task runs while the view is on screen, and is cancelled when
        // it goes away (as on signing out), which stops following.
        .task { await model.load() }
        .task(id: model.followGeneration) { await model.followLiveUpdates() }
        // Notifications: if allowed, Apple is asked for the phone's token on
        // each launch, and the token registered with this session.
        .task { await push.refresh() }
        .task(id: push.deviceToken) { await push.register(with: session.api) }
        // A tapped notification opens its quest, over whatever was open.
        .task(id: push.questToOpen) { openTappedQuest() }
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
            Button("Options", systemImage: "gearshape") { showingOptions = true }
            Button("Delete account", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                deletingAccount = true
            }
        } label: {
            Label("Account", systemImage: "person.crop.circle")
        }
        .disabled(isSigningOut)
        .accessibilityIdentifier("home.account")
    }

    /// Fetches the quests again, and who is signed in, in case their email
    /// address has been verified since.
    /// Opens the quest of a tapped notification, named as in the list if
    /// it's there.
    private func openTappedQuest() {
        guard let questName = push.questToOpen else { return }
        push.questToOpen = nil
        let listed = model.quests?.first { $0.questName == questName }
        var opened = NavigationPath()
        opened.append(
            listed.map(QuestRoute.init) ?? QuestRoute(questName: questName, displayName: questName))
        path = opened
    }

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

    /// A quest known only by name, as from a notification; its screen shows
    /// its display name once loaded.
    init(questName: String, displayName: String) {
        self.questName = questName
        self.displayName = displayName
    }
}

#Preview {
    let connection = ServerConnection(
        setting: ServerSetting(defaults: UserDefaults(suiteName: "preview")!, policy: .anyAddress),
        vault: InMemoryTokenVault(), policy: .anyAddress, fixed: .thisMac)
    HomeView(
        user: SignedInUser(
            userName: "alex", displayName: "Alex", role: .player, emailVerified: false),
        session: connection.session
    )
    .environment(connection)
    .environment(connection.session)
}

import PuzzleQuestKit
import SwiftUI

/// Deleting the player's own account, as the website's Delete account page
/// does: what goes, then their password to confirm. Once it's done, the
/// session ends and the app shows the sign-in screen, closing this.
struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: DeleteAccountModel
    @FocusState private var passwordFocused: Bool

    init(session: SessionStore) {
        // @State keeps the first model it's given for as long as the view is
        // on screen; later calls to init don't replace it.
        _model = State(initialValue: DeleteAccountModel(session: session))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "Your account goes, with your details, and you'll leave your teams. Your name comes out of quests' activity logs. A quest you were playing on your own stays, for the puzzle master. This can't be undone."
                    )
                    .accessibilityIdentifier("delete-account.explanation")
                }
                Section {
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .focused($passwordFocused)
                        .onSubmit(delete)
                        .accessibilityIdentifier("delete-account.password")
                } header: {
                    Text("Your password, to confirm")
                } footer: {
                    if let failure = model.failure {
                        // An icon as well as color, so it doesn't rely on color alone.
                        Label {
                            Text(failure.message)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("delete-account.error")
                    }
                }
                Section {
                    Button(role: .destructive, action: delete) {
                        HStack {
                            Text("Delete my account")
                            if model.isDeleting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!model.canDelete)
                    .accessibilityIdentifier("delete-account.delete")
                }
            }
            .navigationTitle("Delete your account?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep my account") { dismiss() }
                        .disabled(model.isDeleting)
                        .accessibilityIdentifier("delete-account.keep")
                }
            }
        }
        // Not swiped away halfway through deleting.
        .interactiveDismissDisabled(model.isDeleting)
        // VoiceOver reads out a failure as soon as it's shown.
        .onChange(of: model.failure) { _, failure in
            if let failure {
                AccessibilityNotification.Announcement(String(localized: failure.message)).post()
            }
        }
    }

    private func delete() {
        Task { await model.delete() }
    }
}

extension DeleteAccountFailure {
    /// What the person is told.
    var message: LocalizedStringResource {
        switch self {
        case .incorrectPassword:
            "That isn't your password. Check it and try again."
        case .tooManyAttempts:
            "Too many attempts. Wait a few minutes, then try again."
        case .notPossible:
            "This account can't be deleted now. Ask PuzzleQuest for help."
        case .unreachable:
            "Can't reach PuzzleQuest. Check your internet connection, then try again."
        case .unexpected:
            "Something went wrong at PuzzleQuest. Try again in a moment."
        }
    }
}

#Preview {
    let connection = ServerConnection(
        setting: ServerSetting(defaults: UserDefaults(suiteName: "preview")!, policy: .anyAddress),
        vault: InMemoryTokenVault(), policy: .anyAddress, fixed: .thisMac)
    DeleteAccountView(session: connection.session)
}

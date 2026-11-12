import PuzzleQuestKit
import SwiftUI

/// Signing in, to the server chosen in Options, which it names unless it's
/// Production.
struct SignInView: View {
    @Environment(ServerConnection.self) private var connection
    @State private var model: SignInModel
    @State private var showingOptions = false
    @FocusState private var focus: Field?

    private enum Field {
        case userName, password
    }

    init(session: SessionStore) {
        // @State keeps the first model it's given for as long as the view is
        // on screen; later calls to init don't replace it.
        _model = State(initialValue: SignInModel(session: session))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("User name", text: $model.userName)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .userName)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("sign-in.user-name")
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(signIn)
                        .accessibilityIdentifier("sign-in.password")
                } header: {
                    if connection.server != .production {
                        serverNote
                    }
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
                        .accessibilityIdentifier("sign-in.error")
                    }
                }
                Section {
                    Button(action: signIn) {
                        HStack {
                            Text("Sign in")
                            if model.isSigningIn {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!model.canSignIn)
                    .accessibilityIdentifier("sign-in.submit")
                }
                // Signing up is on the website until the app has it.
                Section {
                    Link(destination: connection.server.url) {
                        Text("New to PuzzleQuest? Sign up on the website")
                    }
                    .accessibilityIdentifier("sign-in.sign-up")
                }
            }
            .navigationTitle("Sign in")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Options", systemImage: "gearshape") { showingOptions = true }
                        .accessibilityIdentifier("sign-in.options")
                }
            }
            .sheet(isPresented: $showingOptions) {
                OptionsView(connection: connection)
            }
        }
        // VoiceOver reads out a failure as soon as it's shown.
        .onChange(of: model.failure) { _, failure in
            if let failure {
                AccessibilityNotification.Announcement(String(localized: failure.message)).post()
            }
        }
    }

    /// Which server this is, when it isn't Production: worth knowing, but
    /// not a warning.
    private var serverNote: some View {
        Label {
            Text("Signing in to \(connection.server.displayName)")
        } icon: {
            Image(systemName: "server.rack")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        // Section headers are in capitals by default; a server's name isn't.
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sign-in.server")
    }

    private func signIn() {
        Task { await model.signIn() }
    }
}

extension SignInFailure {
    /// What the person is told.
    var message: LocalizedStringResource {
        switch self {
        case .wrongUserNameOrPassword:
            "That user name and password don't match an account. Check them and try again."
        case .tooManyAttempts:
            "Too many attempts to sign in. Wait a few minutes, then try again."
        case .invalidRequest:
            "PuzzleQuest couldn't accept that. Check your user name and password, then try again."
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
    SignInView(session: connection.session)
        .environment(connection)
}

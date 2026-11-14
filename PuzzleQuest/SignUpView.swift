import PuzzleQuestKit
import SwiftUI

/// Signing up, with the fields the website's form has, then signing straight
/// in as the new player (the session switches the app to their home screen).
struct SignUpView: View {
    @Environment(ServerConnection.self) private var connection
    @State private var model: SignUpModel
    @FocusState private var focus: SignUpField?

    init(session: SessionStore) {
        // @State keeps the first model it's given for as long as the view is
        // on screen; later calls to init don't replace it.
        _model = State(initialValue: SignUpModel(session: session))
    }

    var body: some View {
        Form {
            Section {
                field(.userName) {
                    TextField("User name", text: $model.userName)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field(.password) {
                    // .newPassword lets iOS offer a strong password.
                    SecureField("Password", text: $model.password)
                        .textContentType(.newPassword)
                }
                field(.confirmPassword) {
                    SecureField("Confirm password", text: $model.confirmPassword)
                        .textContentType(.newPassword)
                }
            } footer: {
                Text("At least \(SignUpModel.minimumPasswordLength) characters.")
            }
            Section {
                field(.displayName) {
                    TextField("Display name", text: $model.displayName)
                        .textContentType(.name)
                }
                field(.email) {
                    TextField("Email", text: $model.email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text("We'll send you an email to check it's yours.")
            }
            Section {
                field(.phone) {
                    TextField("Phone number (optional)", text: $model.phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                }
                Toggle("Allow sending of SMS messages", isOn: $model.sms)
                    .accessibilityIdentifier("sign-up.sms")
            } footer: {
                smsConsent
            }
            Section {
                Button(action: signUp) {
                    HStack {
                        Text("Sign up")
                        if model.isSigningUp {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(model.isSigningUp)
                .accessibilityIdentifier("sign-up.submit")
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
                    .accessibilityIdentifier("sign-up.error")
                }
            }
        }
        // Scrolling puts the keyboard away, so the Sign up button beneath it
        // can be reached (the phone pad has no Return key).
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Sign up")
        .navigationBarTitleDisplayMode(.inline)
        // VoiceOver reads out a failure as soon as it's shown.
        .onChange(of: model.failure) { _, failure in
            if let failure {
                AccessibilityNotification.Announcement(String(localized: failure.message)).post()
            }
        }
        // And the first field that's wrong, which gets the keyboard.
        .onChange(of: model.fieldProblems) { _, problems in
            guard let first = SignUpField.allCases.first(where: { problems[$0] != nil }) else {
                return
            }
            focus = first
            if let problem = problems[first] {
                AccessibilityNotification.Announcement(String(localized: problem.message)).post()
            }
        }
    }

    /// A field, with what's wrong with it shown beneath; editing it clears
    /// that, and Return goes on to the next field.
    private func field(_ name: SignUpField, @ViewBuilder _ content: () -> some View) -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            content()
                .focused($focus, equals: name)
                .submitLabel(name == .phone ? .done : .next)
                .onSubmit { focus = name.next }
                .accessibilityIdentifier("sign-up.\(name.rawValue)")
            if let problem = model.fieldProblems[name] {
                Label {
                    Text(problem.message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sign-up.\(name.rawValue).error")
            }
        }
        .onChange(of: text(of: name)) { model.edited(name) }
    }

    private func text(of field: SignUpField) -> String {
        switch field {
        case .userName: model.userName
        case .password: model.password
        case .confirmPassword: model.confirmPassword
        case .displayName: model.displayName
        case .email: model.email
        case .phone: model.phone
        }
    }

    /// The consent the website shows, word for word, as the SMS provider
    /// requires, with a link to the privacy policy.
    private var smsConsent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("US and Canadian numbers only, for now.")
            Text(
                "Checking this box gives The PuzzleQuest Game consent to send you mobile text (SMS) messages. These messages will come from The PuzzleQuest Game number (813-296-5411). The PuzzleQuest Game does not charge for these services, but messaging and data rates from your mobile provider may apply. You may opt out of receiving the messages at any time by replying \"STOP\", or by unchecking this checkbox. See our Privacy Policy for full details."
            )
            .accessibilityIdentifier("sign-up.sms-consent")
            Link("Privacy Policy", destination: connection.server.privacyPolicy)
                .accessibilityIdentifier("sign-up.privacy")
        }
    }

    private func signUp() {
        focus = nil
        Task { await model.signUp() }
    }
}

extension SignUpField {
    /// The field Return goes on to.
    var next: SignUpField? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.endIndex else { return nil }
        return all[index + 1]
    }
}

extension FieldProblem {
    /// What the person is told, beneath the field.
    var message: LocalizedStringResource {
        switch self {
        case .required:
            "Required."
        case .passwordTooShort:
            "Use at least \(SignUpModel.minimumPasswordLength) characters."
        case .passwordsDiffer:
            "The passwords don't match."
        case .server(let words):
            "\(words)"
        }
    }
}

extension SignUpFailure {
    /// What the person is told.
    var message: LocalizedStringResource {
        switch self {
        case .alreadyInUse(let words):
            "\(words). Choose another, or sign in if the account is yours."
        case .tooManyAttempts:
            "Too many attempts to sign up. Wait a few minutes, then try again."
        case .unreachable:
            "Can't reach PuzzleQuest. Check your internet connection, then try again."
        case .signedUpButNotSignedIn:
            "Your account is made, but signing in failed. Go back and sign in with it."
        case .unexpected:
            "Something went wrong at PuzzleQuest. Try again in a moment."
        }
    }
}

#Preview {
    let connection = ServerConnection(
        setting: ServerSetting(defaults: UserDefaults(suiteName: "preview")!, policy: .anyAddress),
        vault: InMemoryTokenVault(), policy: .anyAddress, fixed: .thisMac)
    NavigationStack {
        SignUpView(session: connection.session)
    }
    .environment(connection)
}

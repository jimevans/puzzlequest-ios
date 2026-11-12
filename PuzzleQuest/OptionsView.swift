import PuzzleQuestKit
import SwiftUI

/// Options, shown as a sheet from the sign-in screen and the account menu:
/// which PuzzleQuest server the app uses. Choosing another one signs out,
/// after asking, if someone is signed in. Once it switches, every screen is
/// rebuilt for the new server (see PuzzleQuestApp), which closes this sheet.
struct OptionsView: View {
    let connection: ServerConnection
    @Environment(\.dismiss) private var dismiss
    @State private var model: OptionsModel
    @FocusState private var addressFocused: Bool

    init(connection: ServerConnection) {
        self.connection = connection
        // @State keeps the first model it's given for as long as the view is
        // on screen; later calls to init don't replace it.
        _model = State(
            initialValue: OptionsModel(
                connection: connection, offersThisMac: AppServer.offersThisMac))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server in use", value: connection.server.displayName)
                        .accessibilityIdentifier("options.current")
                    choiceRow(
                        .production, title: "Production",
                        detail: Text(verbatim: ServerOrigin.production.displayName),
                        identifier: "production")
                    if model.offersThisMac {
                        choiceRow(
                            .thisMac, title: "This Mac",
                            detail: Text(verbatim: ServerOrigin.thisMac.displayName),
                            identifier: "this-mac")
                    }
                    choiceRow(
                        .custom, title: "Custom", detail: Text("Another PuzzleQuest server"),
                        identifier: "custom")
                } header: {
                    Text("Server")
                } footer: {
                    #if DEBUG
                        if connection.isFixed {
                            Text(verbatim: "Set for this run by the PQ_SERVER_URL environment variable.")
                        }
                    #endif
                }
                .disabled(connection.isFixed || model.isChecking)
                if model.choice == .custom {
                    customServer
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("options.done")
                }
            }
            // A native confirmation, the platform's equivalent of the web
            // app's in-page ones. `presenting:` hands the server waiting to be
            // switched to into the buttons.
            .confirmationDialog(
                "Switch servers?", isPresented: isConfirming, titleVisibility: .visible,
                presenting: model.pendingSwitch
            ) { server in
                Button("Switch and sign out", role: .destructive) {
                    model.confirmSwitch(to: server)
                }
                Button("Cancel", role: .cancel) { model.cancelSwitch() }
            } message: { server in
                Text(
                    "Switching to \(server.displayName) signs you out of \(connection.server.displayName)."
                )
            }
        }
        .onChange(of: model.choice) { _, choice in
            if choice == .custom {
                addressFocused = true
            }
        }
        // VoiceOver reads out a refusal as soon as it's shown.
        .onChange(of: model.failure) { _, failure in
            if let failure {
                AccessibilityNotification.Announcement(String(localized: failure.message)).post()
            }
        }
    }

    /// Shows the confirmation while a switch waits for it. Dismissing it
    /// (by tapping outside it, say) is the same as Cancel.
    private var isConfirming: Binding<Bool> {
        Binding {
            model.pendingSwitch != nil
        } set: { isShown in
            if !isShown {
                model.cancelSwitch()
            }
        }
    }

    private func choiceRow(
        _ choice: ServerChoice, title: LocalizedStringKey, detail: Text, identifier: String
    ) -> some View {
        let isChosen = model.choice == choice
        return Button {
            model.choose(choice)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    detail
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isChosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
            // The whole row can be tapped, not just its words.
            .contentShape(Rectangle())
        }
        // VoiceOver reads the row as one ("Production, thepuzzlequest.com,
        // Selected"), so the checkmark isn't the only sign of the choice.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("options.server.\(identifier)")
    }

    private var customServer: some View {
        Section {
            TextField(
                "Server address", text: $model.customAddress,
                prompt: Text(verbatim: "https://staging.thepuzzlequest.com")
            )
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .focused($addressFocused)
            .onSubmit(useCustomAddress)
            .disabled(connection.isFixed)
            .accessibilityIdentifier("options.custom-address")
            Button(action: useCustomAddress) {
                HStack {
                    Text("Use this server")
                    if model.isChecking {
                        Spacer()
                        ProgressView()
                            .accessibilityLabel(Text("Checking the server"))
                    }
                }
            }
            .disabled(!model.canUseCustomAddress || connection.isFixed)
            .accessibilityIdentifier("options.use-custom")
        } header: {
            Text("Custom server")
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
                .accessibilityIdentifier("options.error")
            } else if connection.policy == .puzzleQuestDomain {
                Text(
                    "This app connects only to PuzzleQuest's own servers: thepuzzlequest.com and addresses ending in .thepuzzlequest.com."
                )
            } else {
                Text("The app checks it's a PuzzleQuest server before using it.")
            }
        }
    }

    private func useCustomAddress() {
        Task { await model.useCustomAddress() }
    }
}

extension CustomServerFailure {
    /// What the person is told.
    var message: LocalizedStringResource {
        switch self {
        case .refused(.notAnAddress):
            "That isn't a server's address. Enter one such as https://staging.thepuzzlequest.com."
        case .refused(.notAWebAddress):
            "A server's address starts with https:// (or http:// for a test server)."
        case .refused(.hasUserInfo):
            "A server's address can't include a user name or password."
        case .refused(.notJustTheServer):
            "Enter only the server's address, with nothing after its name, such as https://staging.thepuzzlequest.com."
        case .refused(.notSecure):
            "PuzzleQuest's servers use secure connections: the address must start with https://."
        case .refused(.hasPort):
            "PuzzleQuest's servers don't use a port number. Leave out the colon and the number after the name."
        case .refused(.notPuzzleQuestServer):
            "This app connects only to PuzzleQuest's own servers: thepuzzlequest.com and addresses ending in .thepuzzlequest.com."
        case .checkFailed(.unreachable):
            "Can't reach that server. Check the address and your internet connection, then try again."
        case .checkFailed(.notPuzzleQuest):
            "That isn't a PuzzleQuest server. Check the address, then try again."
        case .checkFailed(.unsupportedVersion):
            "That server runs a version of PuzzleQuest this app can't use."
        }
    }
}

#Preview {
    OptionsView(
        connection: ServerConnection(
            setting: ServerSetting(defaults: UserDefaults(suiteName: "preview")!, policy: .anyAddress),
            vault: InMemoryTokenVault(), policy: .anyAddress))
}

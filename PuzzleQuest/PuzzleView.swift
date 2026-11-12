import AVKit
import PuzzleQuestKit
import SwiftUI

/// Where tapping the stop being played goes.
struct PuzzleRoute: Hashable {
    let puzzleName: String
    let displayName: String
}

/// A stop's puzzle, as the web app's puzzle screen: waiting to be found and
/// activated (by scanning its QR code or typing its code), being solved
/// (what it asks, its hints, and a place to answer), or solved (the
/// solution, and on to the next stop, or the finish). Like the quest screen,
/// it keeps itself up to date through live updates, tells VoiceOver users
/// what changes, and never says how many stops there are.
struct PuzzleView: View {
    let route: PuzzleRoute
    private let server: URL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var model: PuzzleModel
    @State private var wasInBackground = false

    init(questName: String, route: PuzzleRoute, api: APIClient) {
        self.route = route
        server = api.server
        _model = State(
            initialValue: PuzzleModel(
                questName: questName, puzzleName: route.puzzleName, api: api))
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
                .overlay(alignment: .topLeading) { liveUpdatesMarker }
            #endif
            .task { await model.load() }
            .task(id: model.followGeneration) { await model.followLiveUpdates() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    wasInBackground = true
                case .active where wasInBackground:
                    wasInBackground = false
                    Task { await model.returnedToForeground() }
                default:
                    break
                }
            }
            .onChange(of: model.changeCount) {
                announce(model.changes.map(Self.announcement).joined(separator: " "))
            }
            .onChange(of: model.actionError) { _, error in
                if let error {
                    announce(Self.message(for: error))
                }
            }
            .onChange(of: model.notAvailable) { _, notAvailable in
                if notAvailable {
                    announce(String(localized: "This puzzle is no longer available."))
                }
            }
    }

    private var title: String {
        model.puzzle?.displayName
            ?? (model.puzzleName == route.puzzleName ? route.displayName : "")
    }

    @ViewBuilder
    private var content: some View {
        if let puzzle = model.puzzle {
            PuzzleDetails(puzzle: puzzle, model: model, server: server)
                .refreshable { await model.load() }
        } else if model.notAvailable {
            ContentUnavailableView {
                Label("Puzzle not available", systemImage: "puzzlepiece")
            } description: {
                Text(
                    "The puzzle master may have reset the quest, or it may no longer be yours to play."
                )
            } actions: {
                Button("Back to the quest") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .accessibilityIdentifier("puzzle.not-available")
        } else if model.loadFailed {
            ContentUnavailableView {
                Label("Couldn't load this puzzle", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("puzzle.retry")
            }
            .accessibilityIdentifier("puzzle.error")
        } else {
            ProgressView("Loading the puzzle…")
        }
    }

    private func announce(_ words: String) {
        AccessibilityNotification.Announcement(words).post()
    }

    /// What VoiceOver says about a change, as the web app says it.
    static func announcement(_ change: PuzzleChange) -> String {
        switch change {
        case .paused:
            String(localized: "Paused by the puzzle master. The clock is stopped.")
        case .resumed:
            String(localized: "The quest has resumed.")
        case .started:
            String(localized: "The puzzle is started.")
        case .solved(let solution?):
            String(localized: "Solved: \(solution).")
        case .solved(nil):
            String(localized: "Solved.")
        case .skipped:
            String(localized: "Skipped by the puzzle master.")
        case .hintRevealed(let hint):
            String(localized: "Hint: \(hint)")
        case .questFinished:
            String(localized: "End of the line.")
        }
    }

    /// Why an action didn't succeed, in words for the player.
    static func message(for error: PuzzleActionError) -> String {
        switch error {
        case .wrongCode:
            String(localized: "That isn't this puzzle's code. Check it and try again.")
        case .wrongAnswer:
            String(localized: "That's not the answer. Try again.")
        case .paused:
            String(localized: "The puzzle master has paused the quest. Try again once it resumes.")
        case .tooManyAttempts:
            String(localized: "That's a lot of tries in a short time. Wait a minute, then try again.")
        case .noMoreHints:
            String(localized: "This puzzle has no more hints.")
        case .changed:
            String(
                localized:
                    "This puzzle changed meanwhile, perhaps solved by a teammate. Here's where it stands now."
            )
        case .tryAgain:
            String(localized: "Someone else acted at the same moment. Try again.")
        case .unreachable:
            String(localized: "Couldn't reach the server. Check your connection and try again.")
        case .unexpected:
            String(localized: "Something went wrong. Try again.")
        }
    }

    #if DEBUG
        /// For the UI tests only (PQ_UI_TESTING=1): whether live updates are
        /// connected, so a test can wait for it before changing something.
        @ViewBuilder
        private var liveUpdatesMarker: some View {
            if ProcessInfo.processInfo.environment["PQ_UI_TESTING"] == "1" {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: "Live updates"))
                    .accessibilityValue(Text(verbatim: model.isLive ? "connected" : "connecting"))
                    .accessibilityIdentifier("puzzle.live-updates")
            }
        }
    #endif
}

/// The puzzle, by where it stands.
struct PuzzleDetails: View {
    let puzzle: PlayerPuzzle
    let model: PuzzleModel
    let server: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if puzzle.paused {
                    // In words and with an icon, not by color alone.
                    Label {
                        Text("Paused by the puzzle master. The clock is stopped until the quest resumes.")
                    } icon: {
                        Image(systemName: "pause.circle.fill")
                    }
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("puzzle.paused")
                }
                if puzzle.status == .awaitingActivation {
                    ActivationSection(model: model, paused: puzzle.paused)
                }
                if let content = puzzle.content {
                    PuzzleContentView(
                        content: content, displayName: puzzle.displayName, server: server)
                }
                if !puzzle.hints.isEmpty {
                    HintsList(hints: puzzle.hints)
                }
                if puzzle.status == .inProgress {
                    SolvingSection(puzzle: puzzle, model: model)
                }
                if puzzle.status == .completed {
                    SolvedSection(puzzle: puzzle, model: model)
                }
            }
            .padding()
            // A new puzzle starts afresh, without the last one's typing.
            .id(puzzle.puzzleName)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stop \(puzzle.stopNumber)")
                .font(.subheadline.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.tint)
            Text(puzzle.displayName)
                .font(.title.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                Text("Total time")
                    .foregroundStyle(.secondary)
                ClockText(clock: puzzle.clock, part: .total)
            }
            .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("puzzle.header")
    }
}

/// Why the player's last action didn't succeed.
struct ActionErrorView: View {
    let error: PuzzleActionError?

    var body: some View {
        if let error {
            Label {
                Text(PuzzleView.message(for: error))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("puzzle.action-error")
        }
    }
}

/// Starting a puzzle the players have found: scanning its QR code where the
/// phone can, or typing its code.
struct ActivationSection: View {
    let model: PuzzleModel
    let paused: Bool
    @State private var scanning = CodeScannerView.canScan
    @State private var cameraFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if scanning && !paused {
                Text("You've found this puzzle's place. Point your camera at its QR code.")
                ActionErrorView(error: model.actionError)
                CodeScannerView(
                    onCode: { code in Task { await model.scanned(code: code) } },
                    onUnavailable: {
                        cameraFailed = true
                        switchMethod(scan: false)
                    }
                )
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel(Text("Camera, looking for the QR code"))
                Button("Enter the code instead") { switchMethod(scan: false) }
                    .accessibilityIdentifier("puzzle.type-code")
            } else {
                if cameraFailed {
                    Text("We couldn't use your camera, so enter this puzzle's code to begin.")
                } else {
                    Text("You've found this puzzle's place. Enter its code to begin.")
                }
                ActionErrorView(error: model.actionError)
                AnswerForm(
                    label: "Activation code", buttonLabel: "Start this puzzle",
                    emptyMessage: "Enter the code", identifier: "puzzle.activation-code",
                    isDisabled: paused, isPending: model.pending == .activating
                ) { code in
                    await model.activate(code: code)
                    return model.actionError == nil
                }
                if CodeScannerView.canScan && !paused {
                    Button("Scan the QR code instead") { switchMethod(scan: true) }
                        .accessibilityIdentifier("puzzle.scan-code")
                }
            }
        }
    }

    private func switchMethod(scan: Bool) {
        model.clearActionError()
        if scan {
            cameraFailed = false
        }
        scanning = scan
    }
}

/// Solving: a place to answer, and the next hint, if there is one.
struct SolvingSection: View {
    let puzzle: PlayerPuzzle
    let model: PuzzleModel
    @State private var askingToGiveAway = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ActionErrorView(error: model.actionError)
            AnswerForm(
                label: "Your answer", buttonLabel: "Check answer", emptyMessage: "Enter your answer",
                identifier: "puzzle.answer", isDisabled: puzzle.paused,
                isPending: model.pending == .solving
            ) { guess in
                await model.solve(guess: guess)
            }
            if let next = puzzle.nextHint {
                Button {
                    model.clearActionError()
                    if next.givesSolutionAway {
                        askingToGiveAway = true
                    } else {
                        Task { await model.revealHint() }
                    }
                } label: {
                    hintLabel(next)
                }
                .buttonStyle(.bordered)
                .disabled(puzzle.paused || model.pending != nil)
                .accessibilityIdentifier("puzzle.reveal-hint")
            }
        }
        .alert("Give away the solution?", isPresented: $askingToGiveAway) {
            Button("Show it", role: .destructive) { Task { await model.revealHint() } }
            Button("Keep trying", role: .cancel) {}
        } message: {
            Text("The next hint shows you the solution.")
        }
    }

    @ViewBuilder
    private func hintLabel(_ next: NextHint) -> some View {
        if next.penaltySeconds > 0 {
            let milliseconds = next.penaltySeconds * 1000
            Text("Reveal next hint (+\(QuestClock.format(milliseconds: milliseconds)))")
                .accessibilityLabel(
                    Text("Reveal next hint, adding \(QuestTime.spoken(milliseconds)) to your time"))
        } else {
            Text("Reveal next hint")
        }
    }
}

/// Solved, or skipped: the solution, then on to the next stop, or the finish.
struct SolvedSection: View {
    let puzzle: PlayerPuzzle
    let model: PuzzleModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ActionErrorView(error: model.actionError)
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(puzzle.skipped ? "Skipped" : "Solved")
                } icon: {
                    Image(systemName: puzzle.skipped ? "forward.circle" : "checkmark.circle.fill")
                        .foregroundStyle(puzzle.skipped ? Color.secondary : Color.green)
                }
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                if let solution = puzzle.solutionText {
                    Text(solution)
                        .accessibilityIdentifier("puzzle.solution")
                }
            }
            if let next = puzzle.next {
                Button {
                    Task { await model.goToNextStop() }
                } label: {
                    Text("On to \(next.displayName)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("puzzle.next-stop")
            } else if puzzle.questFinished {
                VStack(alignment: .leading, spacing: 8) {
                    Label("End of the line", systemImage: "flag.checkered")
                        .font(.title2.weight(.semibold))
                    Text(
                        "Congratulations! You finished \(puzzle.questDisplayName) in \(QuestClock.format(milliseconds: puzzle.clock.totalMs))."
                    )
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("puzzle.finished")
                Button("Back to the quest") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// The hints revealed so far, and what each cost.
struct HintsList: View {
    let hints: [RevealedHint]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hints")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(hints.enumerated()), id: \.offset) { index, hint in
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if hint.penaltySeconds > 0 {
                            Text(
                                "Hint \(index + 1), +\(QuestClock.format(milliseconds: hint.penaltySeconds * 1000))"
                            )
                        } else {
                            Text("Hint \(index + 1)")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Text(hint.text)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("puzzle.hint.\(index + 1)")
            }
        }
    }
}

/// One line to send: an activation code, or a guess at the solution.
struct AnswerForm: View {
    let label: LocalizedStringKey
    let buttonLabel: LocalizedStringKey
    /// What to say if the player sends nothing.
    let emptyMessage: LocalizedStringKey
    /// The field's accessibility identifier; the button's adds ".send".
    let identifier: String
    let isDisabled: Bool
    let isPending: Bool
    /// Sends it; returns whether it was accepted, so the field empties.
    let onSubmit: (String) async -> Bool
    @State private var value = ""
    @State private var isEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
            TextField(label, text: $value)
                .textFieldStyle(.roundedBorder)
                // An answer or code is typed exactly as meant.
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                .onSubmit(submit)
                .onChange(of: value) { isEmpty = false }
                .disabled(isDisabled)
                .accessibilityIdentifier(identifier)
            if isEmpty {
                Text(emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button(action: submit) {
                Text(buttonLabel)
                    .opacity(isPending ? 0 : 1)
                    .overlay {
                        if isPending {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isDisabled || isPending)
            .accessibilityIdentifier("\(identifier).send")
        }
    }

    private func submit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        isEmpty = trimmed.isEmpty
        guard !trimmed.isEmpty, !isPending, !isDisabled else { return }
        Task {
            if await onSubmit(trimmed) {
                value = ""
            }
        }
    }
}

/// What a puzzle asks: its text, picture, recording, or film.
struct PuzzleContentView: View {
    let content: PuzzleContent
    let displayName: String
    let server: URL

    var body: some View {
        Group {
            switch content {
            case .text(let markdown):
                MarkdownView(blocks: MarkdownBlock.blocks(from: markdown, server: server))
            case .image(let url):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let picture):
                        picture
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        Label("Couldn't load this picture", systemImage: "photo")
                            .foregroundStyle(.secondary)
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(displayName))
                .accessibilityAddTraits(.isImage)
            case .audio(let url):
                MediaPlayerView(url: url)
                    .frame(height: 90)
                    .id(url)
            case .video(let url):
                MediaPlayerView(url: url)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .id(url)
            }
        }
        .accessibilityIdentifier("puzzle.content")
    }
}

/// A recording or film, with the system's playback controls.
private struct MediaPlayerView: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onDisappear { player.pause() }
    }
}

#Preview("Solving") {
    let clock = QuestClock(
        running: true, clockStart: .now.addingTimeInterval(-2537), elapsedMs: 0,
        penaltyMs: 60_000, totalMs: 0)
    NavigationStack {
        PuzzleDetails(
            puzzle: PlayerPuzzle(
                questName: "harbor", questDisplayName: "Harbor walk", questStatus: .inProgress,
                paused: false, clock: clock, puzzleName: "lighthouse",
                displayName: "The Lighthouse", status: .inProgress, stopNumber: 3,
                content: .text("Count the *steps*, then add the **year** on the door."),
                hints: [RevealedHint(text: "Start at the bottom.", penaltySeconds: 60)],
                nextHint: NextHint(penaltySeconds: 300, givesSolutionAway: true)),
            model: PuzzleModel(
                questName: "harbor", puzzleName: "lighthouse",
                api: APIClient(
                    server: URL(string: "https://example.com")!, tokens: InMemoryTokenStore())),
            server: URL(string: "https://example.com")!
        )
        .navigationTitle(Text(verbatim: "The Lighthouse"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

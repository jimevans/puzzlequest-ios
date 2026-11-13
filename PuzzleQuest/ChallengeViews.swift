import PuzzleQuestKit
import SwiftUI

/// Answering the puzzle master's challenge: what the screens need of the
/// quest's model, so they can be shown without one, as in previews.
struct ChallengeAnswering {
    var isPending = false
    var error: ChallengeAnswerError?
    /// Sends an answer; returns whether it was right, so the field empties.
    var answer: (String) async -> Bool = { _ in false }
}

/// The puzzle master's messages, over the quest screen: those this phone
/// hasn't shown yet, newest first, or the challenge reopened. A challenge is
/// answered here, and a right answer shows the confirmation, large, to show
/// the venue's staff. Done, or swiping it away, puts it away; the messages
/// stay in the quest's history.
struct MessageSheetView: View {
    let sheet: MessageSheet
    let entry: QuestEntryProgress
    let answering: ChallengeAnswering
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if sheet.showsChallenge, let challenge = entry.challenge {
                    Section {
                        if let answer = challenge.answer {
                            ConfirmationCard(answer: answer, entry: entry)
                        } else {
                            ChallengeQuestion(challenge: challenge, answering: answering)
                        }
                    }
                }
                ForEach(otherMessages) { message in
                    Section {
                        MessageRow(message: message, large: true)
                    }
                }
            }
            .navigationTitle("From the puzzle master")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .accessibilityIdentifier("quest.messages.done")
                }
            }
        }
        // Half the screen is enough for a message or a challenge, and leaves
        // the quest in view; pulled up, it's the whole screen.
        .presentationDetents([.medium, .large])
    }

    /// The messages besides the challenge, which shows above as itself.
    private var otherMessages: [PuzzleMasterMessage] {
        guard sheet.showsChallenge, let challenge = entry.challenge else {
            return sheet.messages
        }
        return sheet.messages.filter { !challenge.isSet(by: $0) }
    }
}

/// A challenge waiting for its answer: the question, why the last answer
/// didn't succeed, and the field to answer it.
struct ChallengeQuestion: View {
    let challenge: Challenge
    let answering: ChallengeAnswering

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("A challenge from the puzzle master", systemImage: "questionmark.bubble.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text(challenge.message)
                .font(.title3)
                .accessibilityIdentifier("quest.challenge.message")
            if let error = answering.error {
                Label {
                    Text(Self.message(for: error))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("quest.challenge.error")
            }
            AnswerForm(
                label: "Your answer", buttonLabel: "Send the answer",
                emptyMessage: "Type your answer first.",
                identifier: "quest.challenge.answer", isDisabled: false,
                isPending: answering.isPending,
                onSubmit: answering.answer)
        }
        .padding(.vertical, 6)
    }

    /// What to say about an answer that didn't succeed.
    static func message(for error: ChallengeAnswerError) -> String {
        switch error {
        case .wrongAnswer:
            String(localized: "That's not the answer. Try again.")
        case .tooManyAttempts:
            String(localized: "That's a lot of tries in a short time. Wait a minute, then try again.")
        case .changed:
            String(
                localized:
                    "This challenge has already been answered, perhaps by a teammate, or the puzzle master sent another."
            )
        case .unreachable:
            String(localized: "Couldn't reach the server. Check your connection and try again.")
        case .unexpected:
            String(localized: "Something went wrong. Try again.")
        }
    }
}

/// The confirmation of a challenge answered rightly, made to be turned
/// toward the venue's staff: large, with who answered it and when.
struct ConfirmationCard: View {
    let answer: ChallengeAnswer
    let entry: QuestEntryProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Show this to the staff", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            Text(answer.confirmation)
                .font(.title.weight(.bold))
                .accessibilityIdentifier("quest.challenge.confirmation")
            if let name = entry.entrantName {
                Text(name)
                    .font(.headline)
            }
            Group {
                if answer.byText {
                    Text("Answered by text at \(answer.answeredAt.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Answered at \(answer.answeredAt.formatted(date: .omitted, time: .shortened))")
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quest.challenge.answered")
    }
}

/// The small row at the top of the quest screen that reopens the challenge:
/// to answer it while it waits, or, once answered, to show the confirmation
/// to the staff. An answered one can be hidden for good with its ✕; it's
/// still in the puzzle master's messages.
struct ChallengeRow: View {
    let challenge: Challenge
    let onOpen: () -> Void
    let onHide: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack {
                    if challenge.answer == nil {
                        Label {
                            Text("Challenge waiting")
                        } icon: {
                            Image(systemName: "questionmark.bubble.fill")
                                .foregroundStyle(.tint)
                        }
                        Spacer()
                        Text("Answer")
                            .foregroundStyle(.tint)
                    } else {
                        Label {
                            Text("Challenge answered")
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Text("Show confirmation")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .accessibilityIdentifier("quest.challenge-row")
            if challenge.answer != nil {
                Button(action: onHide) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text("Hide the answered challenge"))
                .accessibilityIdentifier("quest.challenge-row.hide")
            }
        }
        // Two buttons in one row: each answers only its own taps.
        .buttonStyle(.borderless)
    }
}

/// One of the puzzle master's messages: when it came, whether it set a
/// challenge, and what it says.
struct MessageRow: View {
    let message: PuzzleMasterMessage
    /// Larger, as in the sheet, where it's read on arriving.
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(message.sentAt.formatted(date: .omitted, time: .shortened))
                if message.isChallenge {
                    Text("Challenge")
                        .fontWeight(.semibold)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(message.text)
                .font(large ? .title3 : .body)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Where the row of the puzzle master's messages goes.
struct MessagesRoute: Hashable {}

/// Where a challenge's entry in the messages goes: the message that set it.
struct ChallengeRoute: Hashable {
    let sentAt: Date
}

/// Everything the puzzle master has sent the players, newest first. A
/// challenge's entry opens it.
struct MessagesHistoryView: View {
    let model: QuestModel

    var body: some View {
        List {
            ForEach((model.quest?.entry.messages ?? []).reversed()) { message in
                if message.isChallenge {
                    NavigationLink(value: ChallengeRoute(sentAt: message.sentAt)) {
                        MessageRow(message: message)
                    }
                    .accessibilityHint(Text("Opens the challenge"))
                } else {
                    MessageRow(message: message)
                }
            }
        }
        .navigationTitle("From the puzzle master")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("quest.messages")
    }
}

/// One of the puzzle master's challenges, from the messages: the latest
/// waiting for its answer, or answered with its confirmation for the staff;
/// an earlier one only as it was asked, since a challenge replaces the one
/// before.
struct ChallengeDetailView: View {
    let model: QuestModel
    let sentAt: Date

    var body: some View {
        List {
            if let entry = model.quest?.entry {
                if let challenge = entry.challenge, challenge.sentAt == sentAt {
                    Section {
                        if let answer = challenge.answer {
                            ConfirmationCard(answer: answer, entry: entry)
                        } else {
                            ChallengeQuestion(
                                challenge: challenge,
                                answering: ChallengeAnswering(
                                    isPending: model.answeringChallenge,
                                    error: model.challengeError,
                                    answer: { await model.answerChallenge($0) }))
                        }
                    }
                    if challenge.answer != nil {
                        Section("The challenge") {
                            Text(challenge.message)
                        }
                    }
                } else if let message = entry.messages.first(where: {
                    $0.isChallenge && $0.sentAt == sentAt
                }) {
                    Section {
                        MessageRow(message: message, large: true)
                    } footer: {
                        Text("The puzzle master has sent another challenge since this one.")
                    }
                }
            }
        }
        .navigationTitle("Challenge")
        .navigationBarTitleDisplayMode(.inline)
    }
}

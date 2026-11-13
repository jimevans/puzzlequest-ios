import PuzzleQuestKit
import SwiftUI

/// Answering the puzzle master's challenge: what the quest screen needs of
/// its model, so the list can be shown without one, as in previews.
struct ChallengeAnswering {
    var isPending = false
    var error: ChallengeAnswerError?
    /// Sends an answer; returns whether it was right, so the field empties.
    var answer: (String) async -> Bool = { _ in false }
}

/// The puzzle master's latest challenge: waiting for an answer, or answered,
/// showing the confirmation to show the venue's staff. A new challenge
/// replaces it.
struct ChallengeSection: View {
    let challenge: Challenge
    let entry: QuestEntryProgress
    let answering: ChallengeAnswering

    var body: some View {
        Section {
            if let answer = challenge.answer {
                ConfirmationCard(answer: answer, entry: entry)
            } else {
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
        }
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

/// What the puzzle master has sent the players, newest first.
struct MessagesSection: View {
    let messages: [PuzzleMasterMessage]

    var body: some View {
        Section("From the puzzle master") {
            ForEach(messages.reversed()) { message in
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
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("quest.messages")
    }
}

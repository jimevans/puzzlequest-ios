import PuzzleQuestKit
import SwiftUI

/// Asks the player to verify their email address, with a way to have the
/// email sent again.
struct EmailReminderView: View {
    let model: EmailReminderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Please verify your email address: follow the link in the email we sent you.")
            } icon: {
                Image(systemName: "envelope.badge")
            }
            .accessibilityElement(children: .combine)
            Button {
                Task { await model.send() }
            } label: {
                HStack {
                    Text("Send the email again")
                    if model.state == .sending {
                        ProgressView()
                    }
                }
            }
            // Bordered, so that only the button, not the whole row, is tapped.
            .buttonStyle(.bordered)
            .disabled(!model.canSend)
            .accessibilityIdentifier("email-reminder.send")
            if let result {
                Label {
                    Text(result.message)
                } icon: {
                    Image(systemName: result.icon)
                }
                .foregroundStyle(result.color)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("email-reminder.result")
            }
        }
        // VoiceOver reads out the result as soon as it's shown.
        .onChange(of: model.state) {
            if let result {
                AccessibilityNotification.Announcement(String(localized: result.message)).post()
            }
        }
    }

    private var result: (message: LocalizedStringResource, icon: String, color: Color)? {
        switch model.state {
        case .ready, .sending:
            nil
        case .sent:
            ("Sent. Check your inbox.", "checkmark.circle.fill", .green)
        case .failed(let failure):
            (failure.message, "exclamationmark.triangle.fill", .red)
        }
    }
}

extension EmailReminderFailure {
    /// What the player is told.
    var message: LocalizedStringResource {
        switch self {
        case .tooManyRequests:
            "The email has been sent several times lately. Wait a few minutes, then try again."
        case .unreachable:
            "Can't reach PuzzleQuest. Check your internet connection, then try again."
        case .unexpected:
            "Something went wrong at PuzzleQuest. Try again in a moment."
        }
    }
}

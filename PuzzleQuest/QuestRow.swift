import PuzzleQuestKit
import SwiftUI

/// A quest in the player's list: its name, where it stands, and its time. It
/// says nothing about how many stops it has.
struct QuestRow: View {
    let quest: QuestSummary
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(quest.displayName)
                .font(.headline)
            // Side by side, unless the text is so large that they'd be cramped.
            let layout =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                if quest.paused {
                    // In words and with an icon, not by color. The server's
                    // description says "Paused" too, so it isn't shown twice.
                    Label("Paused", systemImage: "pause.circle.fill")
                        .accessibilityIdentifier("quest-row.paused")
                } else {
                    Text(quest.statusDescription)
                }
                QuestTime(clock: quest.progress)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        // VoiceOver reads the row as one item.
        .accessibilityElement(children: .combine)
    }
}

/// A quest's total time (time spent plus penalties), counting up each second
/// while its clock runs.
struct QuestTime: View {
    let clock: QuestClock

    var body: some View {
        if clock.isCounting, let start = clock.clockStart {
            // Redraws on each second of the quest's own clock. VoiceOver
            // doesn't read out the change; it reads the time when it reaches
            // the row.
            TimelineView(.periodic(from: start, by: 1)) { context in
                time(clock.totalMs(at: context.date))
            }
        } else {
            time(clock.totalMs)
        }
    }

    private func time(_ milliseconds: Int) -> some View {
        Label {
            Text(QuestClock.format(milliseconds: milliseconds))
                // Digits of equal width, so the time doesn't jiggle as it counts.
                .monospacedDigit()
        } icon: {
            Image(systemName: "stopwatch")
        }
        // "Time: 1 hour, 4 minutes, 5 seconds" rather than "1:04:05".
        .accessibilityLabel(Text("Time: \(Self.spoken(milliseconds))"))
    }

    private static func spoken(_ milliseconds: Int) -> String {
        Duration.milliseconds(max(0, milliseconds) / 1000 * 1000)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

#Preview {
    List {
        QuestRow(
            quest: QuestSummary(
                questName: "harbor-walk", displayName: "Harbor walk", status: .inProgress,
                statusDescription: "In progress", paused: false,
                progress: QuestClock(
                    running: true, clockStart: .now.addingTimeInterval(-3845),
                    elapsedMs: 0, penaltyMs: 60_000, totalMs: 0)))
        QuestRow(
            quest: QuestSummary(
                questName: "museum-mile", displayName: "Museum mile", status: .inProgress,
                statusDescription: "Paused", paused: true,
                progress: QuestClock(
                    running: false, clockStart: nil, elapsedMs: 600_000, penaltyMs: 0,
                    totalMs: 600_000)))
    }
}

import PuzzleQuestKit
import SwiftUI

/// A player's quest: the stop they're on, first and largest, then the stops
/// they've solved, each opening to its details. It never says how many stops
/// the quest has. Once their entry has finished: the finish, and in a race,
/// the standings. It keeps itself up to date through the quest's live
/// updates, and tells VoiceOver users what changes, but not the clocks.
struct QuestView: View {
    let route: QuestRoute
    private let api: APIClient
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var model: QuestModel
    @State private var wasInBackground = false

    init(route: QuestRoute, api: APIClient) {
        self.route = route
        self.api = api
        _model = State(initialValue: QuestModel(questName: route.questName, api: api))
    }

    var body: some View {
        content
            .navigationTitle(model.quest?.displayName ?? route.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: StopRoute.self) { route in
                StopDetailView(model: model, puzzleName: route.puzzleName)
            }
            .navigationDestination(for: PuzzleRoute.self) { puzzle in
                PuzzleView(questName: route.questName, route: puzzle, api: api)
            }
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
                let words = model.changes.map(Self.announcement).joined(separator: " ")
                AccessibilityNotification.Announcement(words).post()
            }
            .onChange(of: model.notAvailable) { _, notAvailable in
                if notAvailable {
                    AccessibilityNotification.Announcement(
                        String(localized: "This quest is no longer available.")
                    ).post()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let quest = model.quest {
            QuestProgressList(quest: quest, standings: model.standings)
                .refreshable { await model.load() }
        } else if model.notAvailable {
            ContentUnavailableView {
                Label("Quest not available", systemImage: "map")
            } description: {
                Text(
                    "The puzzle master may have reset it, or it may no longer be yours to play."
                )
            } actions: {
                Button("Back to your quests") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .accessibilityIdentifier("quest.not-available")
        } else if model.loadFailed {
            ContentUnavailableView {
                Label("Couldn't load this quest", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("quest.retry")
            }
            .accessibilityIdentifier("quest.error")
        } else {
            ProgressView("Loading the quest…")
        }
    }

    /// What VoiceOver says about a change, as the web app says it.
    static func announcement(_ change: QuestChange) -> String {
        switch change {
        case .paused:
            String(localized: "Paused by the puzzle master. The clock is stopped.")
        case .resumed:
            String(localized: "The quest has resumed.")
        case .stopReached(let number, let displayName):
            String(localized: "Stop \(number) reached: \(displayName).")
        case .stopSolved(let displayName):
            String(localized: "\(displayName) is solved.")
        case .finished:
            String(localized: "End of the line.")
        case .rivalFinished(let entry, let rank):
            String(localized: "\(StandingsSection.name(of: entry)) finished \(ordinal(rank)).")
        case .standingsFinal(let winners):
            String(
                localized:
                    "Final standings: \(winners.map(StandingsSection.name(of:)).formatted(.list(type: .and))) won."
            )
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
                    .accessibilityIdentifier("quest.live-updates")
            }
        }
    #endif
}

/// Where tapping a solved stop goes.
struct StopRoute: Hashable {
    let puzzleName: String
}

/// The quest's progress, as a list: the pause, the total time, the stop being
/// played, the finish and standings, and the stops solved.
struct QuestProgressList: View {
    let quest: PlayerQuest
    let standings: Standings?

    var body: some View {
        List {
            if quest.entry.paused {
                Section {
                    // In words and with an icon, not by color alone.
                    Label {
                        Text("Paused by the puzzle master. The clock is stopped until the quest resumes.")
                    } icon: {
                        Image(systemName: "pause.circle.fill")
                    }
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("quest.paused")
                }
            }
            Section {
                summary
            }
            if let stop = quest.entry.currentStop {
                Section {
                    NavigationLink(
                        value: PuzzleRoute(puzzleName: stop.puzzleName, displayName: stop.displayName)
                    ) {
                        CurrentStopCard(stop: stop)
                    }
                    .accessibilityHint(Text("Opens the puzzle"))
                    .accessibilityIdentifier("quest.current-stop")
                }
            }
            if quest.entry.isFinished {
                Section {
                    finish
                }
                if let standings {
                    StandingsSection(standings: standings, ownEntry: quest.entry)
                }
            }
            if !quest.entry.finishedStops.isEmpty {
                Section("Solved") {
                    ForEach(quest.entry.finishedStops) { stop in
                        NavigationLink(value: StopRoute(puzzleName: stop.puzzleName)) {
                            SolvedStopRow(stop: stop)
                        }
                        .accessibilityIdentifier("quest.solved.\(stop.puzzleName)")
                    }
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Total time")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ClockText(clock: quest.entry.clock, part: .total)
                .font(.largeTitle.weight(.semibold))
            Group {
                if quest.entry.clock.penaltyMs > 0 {
                    Text(
                        "\(quest.entry.statusDescription), including \(QuestClock.format(milliseconds: quest.entry.clock.penaltyMs)) in hint penalties"
                    )
                } else {
                    Text(quest.entry.statusDescription)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quest.summary")
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("End of the line", systemImage: "flag.checkered")
                .font(.title2.weight(.semibold))
            Text(
                "Congratulations! You finished \(quest.displayName) in \(QuestClock.format(milliseconds: quest.entry.clock.totalMs))."
            )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quest.finished")
    }
}

/// The stop being played, large: its number, name, where it stands, and its
/// time. Tapping it opens its puzzle.
struct CurrentStopCard: View {
    let stop: Stop

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stop \(stop.number)")
                .font(.subheadline.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.tint)
            Text(stop.displayName)
                .font(.title2.weight(.semibold))
            Text(stop.statusDescription)
                .foregroundStyle(.secondary)
            if let clock = stop.clock {
                ClockText(clock: clock, part: .total)
                    .font(.title3)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A solved stop, short: a check mark, its number and name, and its time.
struct SolvedStopRow: View {
    let stop: Stop
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stop \(stop.number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(stop.displayName)
                }
            } icon: {
                // Says how it ended in words for VoiceOver, not just by icon.
                Image(systemName: stop.skipped ? "forward.circle" : "checkmark.circle.fill")
                    .foregroundStyle(stop.skipped ? Color.secondary : Color.green)
                    .accessibilityLabel(stop.skipped ? Text("Skipped") : Text("Solved"))
            }
            if !typeSize.isAccessibilitySize {
                Spacer()
            }
            if let clock = stop.clock {
                ClockText(clock: clock, part: .total)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A solved stop's details: when it was reached, found, and solved; its
/// times; and its solution. It stays up to date with the quest.
struct StopDetailView: View {
    let model: QuestModel
    let puzzleName: String

    var body: some View {
        if let stop = model.quest?.entry.stops.first(where: { $0.puzzleName == puzzleName }) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stop \(stop.number)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(stop.displayName)
                            .font(.title2.weight(.semibold))
                        Text(stop.statusDescription)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let solution = stop.solutionText {
                    Section("Solution") {
                        Text(solution)
                            .accessibilityIdentifier("stop.solution")
                    }
                }
                Section("Times") {
                    moment("Started", stop.startTime)
                    moment("Activated", stop.activationTime)
                    moment("Finished", stop.endTime)
                    if let clock = stop.clock {
                        LabeledContent("Time") { ClockText(clock: clock, part: .elapsed) }
                        if clock.penaltyMs > 0 {
                            LabeledContent("Hint penalties") {
                                Text(QuestClock.format(milliseconds: clock.penaltyMs))
                                    .monospacedDigit()
                            }
                            LabeledContent("Total") { ClockText(clock: clock, part: .total) }
                        }
                    }
                }
            }
            .navigationTitle("Stop \(stop.number)")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            // Gone, as when the quest was reset while this was open.
            ContentUnavailableView("Stop not available", systemImage: "mappin.slash")
        }
    }

    @ViewBuilder
    private func moment(_ label: LocalizedStringKey, _ date: Date?) -> some View {
        if let date {
            LabeledContent(label) {
                Text(date, format: .dateTime.hour().minute().second())
            }
        }
    }
}

/// A race's standings, once the player's entry has finished: each entry's
/// place, name, status, and time, with the player's own marked.
struct StandingsSection: View {
    let standings: Standings
    let ownEntry: QuestEntryProgress

    var body: some View {
        Section {
            ForEach(standings.entries) { entry in
                row(entry)
            }
        } header: {
            Text(standings.isFinal ? "Final standings" : "Standings")
        } footer: {
            if standings.provisional {
                Text(
                    "Provisional until every team finishes: a team still playing could beat these times."
                )
            } else if standings.rivalsHidden {
                Text("It's a race: the standings will show here once your team finishes.")
            }
        }
    }

    private func row(_ entry: Standing) -> some View {
        let own = entry.id == ownEntry.id
        let winner = standings.isFinal && entry.rank == 1
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if let rank = entry.rank {
                    Text(ordinal(rank))
                } else {
                    // A dash on screen; words for VoiceOver.
                    Text(verbatim: "–")
                        .accessibilityLabel(Text("Not ranked yet"))
                }
            }
            .font(.headline)
            .frame(minWidth: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.name(of: entry))
                    .fontWeight(own ? .semibold : .regular)
                HStack(spacing: 6) {
                    if winner {
                        Label("Winner", systemImage: "trophy.fill")
                    }
                    if own {
                        Label(
                            ownEntry.isTeam ? "Your team" : "You",
                            systemImage: "person.fill")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                Group {
                    if entry.paused {
                        Text("\(entry.statusDescription), paused")
                    } else {
                        Text(entry.statusDescription)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.started {
                ClockText(clock: entry.clock, part: .total)
            } else {
                Text(verbatim: "–")
                    .accessibilityLabel(Text("Not started"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quest.standing.\(entry.id)")
    }

    /// An entry's name, or what it was if it has been deleted.
    static func name(of entry: Standing) -> String {
        entry.displayName
            ?? (entry.isTeam
                ? String(localized: "A deleted team") : String(localized: "A deleted player"))
    }
}

/// A place in the standings, such as "1st".
func ordinal(_ rank: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .ordinal
    return formatter.string(from: rank as NSNumber) ?? "\(rank)"
}

/// A clock's time, counting up each second while it runs, with digits of
/// equal width; VoiceOver hears it in words.
struct ClockText: View {
    enum Part {
        /// The time spent, without penalties.
        case elapsed
        /// The time spent plus penalties: the score.
        case total
    }

    let clock: QuestClock
    let part: Part

    var body: some View {
        if clock.isCounting, let start = clock.clockStart {
            TimelineView(.periodic(from: start, by: 1)) { context in
                time(at: context.date)
            }
        } else {
            time(at: .now)
        }
    }

    private func time(at date: Date) -> some View {
        let milliseconds =
            part == .total ? clock.totalMs(at: date) : clock.elapsedMs(at: date)
        return Text(QuestClock.format(milliseconds: milliseconds))
            .monospacedDigit()
            .accessibilityLabel(Text(QuestTime.spoken(milliseconds)))
    }
}

#Preview("Playing") {
    let clock = QuestClock(
        running: true, clockStart: .now.addingTimeInterval(-2537), elapsedMs: 0,
        penaltyMs: 120_000, totalMs: 0)
    NavigationStack {
        QuestProgressList(
            quest: PlayerQuest(
                questName: "harbor", displayName: "Harbor walk",
                entry: QuestEntryProgress(
                    id: "e1", isTeam: true, status: .inProgress, statusDescription: "In progress",
                    paused: false, startTime: .now, endTime: nil, clock: clock,
                    stops: [
                        Stop(
                            number: 1, puzzleName: "quay", displayName: "The Quay",
                            status: .completed, statusDescription: "Solved",
                            clock: QuestClock(
                                running: false, clockStart: nil, elapsedMs: 1_184_000,
                                penaltyMs: 0, totalMs: 1_184_000)),
                        Stop(
                            number: 2, puzzleName: "customs", displayName: "Old Customs",
                            status: .completed, statusDescription: "Solved",
                            clock: QuestClock(
                                running: false, clockStart: nil, elapsedMs: 842_000,
                                penaltyMs: 0, totalMs: 842_000)),
                        Stop(
                            number: 3, puzzleName: "lighthouse", displayName: "The Lighthouse",
                            status: .inProgress, statusDescription: "In progress",
                            clock: QuestClock(
                                running: true, clockStart: .now.addingTimeInterval(-511),
                                elapsedMs: 0, penaltyMs: 0, totalMs: 0)),
                    ])),
            standings: nil
        )
        .navigationTitle(Text(verbatim: "Harbor walk"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

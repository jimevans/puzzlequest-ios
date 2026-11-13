// Following live updates over the API's websocket, /api/v1/updates, as the
// web app's packages/api-client/src/live.ts does: a new ticket for each
// connection (tickets can be used once), a subscription naming what's
// followed, and reconnecting with a growing wait whenever the connection
// drops. Updates sent while disconnected are gone, so whoever follows fetches
// what they show again each time it connects, as well as on each update.
import Foundation
import PuzzleQuestAPI

/// What a connection follows.
public enum LiveChannel: Hashable, Sendable {
    /// The list of quests a user plays (a player's home screen), with tickets
    /// from `POST /users/{userName}/live-tickets`.
    case userQuests(userName: String)
    /// Every update of a quest, with tickets from
    /// `POST /quests/{questName}/live-tickets`.
    case quest(questName: String)
}

/// A message from the server about what's followed. Version 1 may add others,
/// which are ignored.
public enum LiveUpdate: Equatable, Sendable {
    /// The user's list of quests should be fetched again, as when one of them
    /// starts.
    case questsChanged
    /// An entry in a quest changed (a stop was activated, started or solved,
    /// a hint revealed, the puzzle master sent a message or a challenge was
    /// answered, or something the follower may not be told about while
    /// racing); `message` is which, as the API names it.
    case questChanged(message: String, questName: String, entryId: String)
}

/// What happens to a connection, as a follower reports it.
public enum LiveEvent: Equatable, Sendable {
    /// The server accepted the subscription. Fetch what's followed again,
    /// since updates may have been missed; send `connectionId` with your own
    /// actions so that their updates aren't sent back.
    case connected(connectionId: String)
    case update(LiveUpdate)
    /// The connection dropped after connecting; the follower tries again.
    case disconnected
}

/// A websocket connection: what the follower needs of one, so tests can stand
/// in for the network.
public protocol LiveSocket: Sendable {
    func send(_ text: String) async throws
    /// The next message, as text. Throws once the connection has closed.
    func receive() async throws -> String
    /// Checks the connection is alive; throws if it isn't.
    func sendPing() async throws
    /// Closes the connection; a `receive()` waiting for a message throws.
    func close()
}

/// Opens websocket connections.
public protocol LiveSocketConnector: Sendable {
    func connect(to url: URL) -> any LiveSocket
}

/// Follows a channel for as long as `run` runs: connects, subscribes with a new
/// ticket, reports each event, and after the connection drops (or can't be
/// made) tries again after a wait that doubles each time, up to
/// `longestWait`. It stops when the task running it is cancelled, as SwiftUI
/// does to a view's `.task` when the view goes away.
public struct LiveUpdateFollower: Sendable {
    /// The longest wait between attempts to connect.
    public static let longestWait: Duration = .seconds(15)

    public let url: URL
    public let channel: LiveChannel
    private let connector: any LiveSocketConnector
    private let ticket: @Sendable () async throws -> String

    /// How long to wait before trying again; tests make it instant.
    package var wait: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// How often to check that a quiet connection is still alive. A phone can
    /// lose its connection without being told (a dead zone, a locked phone),
    /// so a ping that fails or goes unanswered counts as a drop.
    package var pingInterval: Duration = .seconds(25)
    package var pongTimeout: Duration = .seconds(10)

    /// - Parameters:
    ///   - url: the websocket's address, `APIClient.liveUpdatesURL`.
    ///   - channel: what to follow.
    ///   - connector: opens the connection.
    ///   - ticket: gets a new ticket for the channel, for each connection.
    public init(
        url: URL, channel: LiveChannel,
        connector: any LiveSocketConnector = URLSessionLiveSocketConnector(),
        ticket: @escaping @Sendable () async throws -> String
    ) {
        self.url = url
        self.channel = channel
        self.connector = connector
        self.ticket = ticket
    }

    /// Follows the channel until the task is cancelled, reporting each event.
    /// Events are reported one at a time, each after the last has been
    /// handled.
    public func run(_ onEvent: @escaping @MainActor @Sendable (LiveEvent) async -> Void) async {
        var attempts = 0
        while !Task.isCancelled {
            if await connectOnce(onEvent) {
                // It worked, so a drop is likely brief: try again soon.
                attempts = 0
                if Task.isCancelled { return }
                await onEvent(.disconnected)
            }
            let delay = min(Duration.seconds(1 << min(attempts, 10)), Self.longestWait)
            attempts += 1
            do {
                try await wait(delay)
            } catch {
                return
            }
        }
    }

    /// Connects once and reports events until the connection drops.
    /// - Returns: whether the server accepted the subscription.
    private func connectOnce(
        _ onEvent: @escaping @MainActor @Sendable (LiveEvent) async -> Void
    ) async -> Bool {
        let subscription: String
        do {
            subscription = try Self.subscription(to: channel, ticket: try await ticket())
        } catch {
            return false
        }
        if Task.isCancelled { return false }
        let socket = connector.connect(to: url)
        defer { socket.close() }
        return await withTaskGroup(of: Void.self) { group in
            // Pings alongside receiving; when one fails it closes the socket,
            // which ends receiving.
            group.addTask { [pingInterval, pongTimeout] in
                await Self.keepAlive(socket, every: pingInterval, timeout: pongTimeout)
            }
            defer { group.cancelAll() }
            var connected = false
            do {
                try await socket.send(subscription)
                while true {
                    let text = try await withTaskCancellationHandler {
                        try await socket.receive()
                    } onCancel: {
                        socket.close()
                    }
                    switch Self.message(from: text) {
                    case .connection(let id):
                        connected = true
                        await onEvent(.connected(connectionId: id))
                    case .update(let update):
                        await onEvent(.update(update))
                    case nil:
                        break
                    }
                }
            } catch {
                // Closed here too, since the task group waits for a ping in
                // flight, which only closing ends.
                socket.close()
                return connected
            }
        }
    }

    /// Pings the socket now and then until cancelled, closing it if a ping
    /// fails or isn't answered in time.
    private static func keepAlive(
        _ socket: any LiveSocket, every interval: Duration, timeout: Duration
    ) async {
        while true {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return  // Cancelled.
            }
            let answered = await withTaskGroup(of: Bool.self) { group in
                group.addTask { (try? await socket.sendPing()) != nil }
                group.addTask {
                    // Cancelled (false) once the ping is answered.
                    (try? await Task.sleep(for: timeout)) == nil
                }
                let first = await group.next() ?? false
                group.cancelAll()
                if !first {
                    // Closing it ends a ping still waiting for its answer.
                    socket.close()
                }
                return first
            }
            if !answered { return }
        }
    }

    // MARK: Messages

    /// A message from the server, as far as following goes.
    enum Message: Equatable {
        case connection(String)
        case update(LiveUpdate)
    }

    /// The subscription message for a channel, as JSON text.
    static func subscription(to channel: LiveChannel, ticket: String) throws -> String {
        let message: Components.Schemas.LiveUpdateSubscription
        switch channel {
        case .userQuests(let userName):
            message = .init(value2: .init(message: .subscribe, userName: userName, ticket: ticket))
        case .quest(let questName):
            message = .init(value1: .init(message: .subscribe, questName: questName, ticket: ticket))
        }
        return String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let transcoder = APIDateTranscoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try transcoder.decode(decoder.singleValueContainer().decode(String.self))
        }
        return decoder
    }()

    /// Reads a message from the server, or nil for one this version of the
    /// app doesn't know (version 1 may add messages) or can't read. The
    /// generated cases are numbered in the order the API's description lists
    /// the messages, which can change when it gains one: a new pinned
    /// version makes this switch fail to compile until each is checked.
    static func message(from text: String) -> Message? {
        guard
            let update = try? decoder.decode(
                Components.Schemas.LiveUpdate.self, from: Data(text.utf8))
        else { return nil }
        switch update {
        case .case1(let connection):
            return .connection(connection.connectionId)
        case .case2(let activated):
            return .update(
                .questChanged(
                    message: activated.message.rawValue, questName: activated.questName,
                    entryId: activated.entryId))
        case .case3(let solved):
            return .update(
                .questChanged(
                    message: solved.message.rawValue, questName: solved.questName,
                    entryId: solved.entryId))
        case .case4(let started):
            return .update(
                .questChanged(
                    message: started.message.rawValue, questName: started.questName,
                    entryId: started.entryId))
        case .case5(let hint):
            return .update(
                .questChanged(
                    message: hint.message.rawValue, questName: hint.questName,
                    entryId: hint.entryId))
        case .case6(let updated):
            return .update(
                .questChanged(
                    message: updated.message.rawValue, questName: updated.questName,
                    entryId: updated.entryId))
        case .case7(let sent):
            return .update(
                .questChanged(
                    message: sent.message.rawValue, questName: sent.questName,
                    entryId: sent.entryId))
        case .case8(let answered):
            return .update(
                .questChanged(
                    message: answered.message.rawValue, questName: answered.questName,
                    entryId: answered.entryId))
        case .case9:
            return .update(.questsChanged)
        }
    }
}

// MARK: - URLSession

/// Opens websocket connections with `URLSessionWebSocketTask`.
public struct URLSessionLiveSocketConnector: LiveSocketConnector {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(to url: URL) -> any LiveSocket {
        let task = session.webSocketTask(with: url)
        task.resume()
        return URLSessionLiveSocket(task: task)
    }
}

struct URLSessionLiveSocket: LiveSocket {
    let task: URLSessionWebSocketTask

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            return String(decoding: data, as: UTF8.self)
        @unknown default:
            throw URLError(.cannotDecodeContentData)
        }
    }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (answered: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    answered.resume(throwing: error)
                } else {
                    answered.resume()
                }
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

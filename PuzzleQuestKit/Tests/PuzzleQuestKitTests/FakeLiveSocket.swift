import Foundation
import Synchronization
import Testing

@testable import PuzzleQuestKit

/// Stands in for a websocket connection: remembers what's sent, and receives
/// what a test delivers until the test (or the follower) closes it.
final class FakeLiveSocket: LiveSocket {
    struct Closed: Error {}

    private struct State {
        var sent: [String] = []
        var incoming: [String] = []
        var waiting: CheckedContinuation<String, any Error>?
        var isClosed = false
        var pingFails = false
    }

    private let state = Mutex(State())

    var sent: [String] { state.withLock { $0.sent } }
    var isClosed: Bool { state.withLock { $0.isClosed } }

    /// The server sends a message.
    func deliver(_ text: String) {
        state.withLock { state in
            if let waiting = state.waiting {
                state.waiting = nil
                waiting.resume(returning: text)
            } else {
                state.incoming.append(text)
            }
        }
    }

    /// Pings fail from now on, as on a connection that has died silently.
    func failPings() {
        state.withLock { $0.pingFails = true }
    }

    func send(_ text: String) async throws {
        try state.withLock { state in
            guard !state.isClosed else { throw Closed() }
            state.sent.append(text)
        }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                if !state.incoming.isEmpty {
                    continuation.resume(returning: state.incoming.removeFirst())
                } else if state.isClosed {
                    continuation.resume(throwing: Closed())
                } else {
                    state.waiting = continuation
                }
            }
        }
    }

    func sendPing() async throws {
        if state.withLock({ $0.pingFails || $0.isClosed }) {
            throw Closed()
        }
    }

    func close() {
        state.withLock { state in
            state.isClosed = true
            state.waiting?.resume(throwing: Closed())
            state.waiting = nil
        }
    }
}

/// Opens a new fake socket for each connection, and remembers them.
final class FakeLiveSocketConnector: LiveSocketConnector {
    private let opened = Mutex<[(url: URL, socket: FakeLiveSocket)]>([])

    var sockets: [FakeLiveSocket] { opened.withLock { $0.map(\.socket) } }
    var urls: [URL] { opened.withLock { $0.map(\.url) } }

    func connect(to url: URL) -> any LiveSocket {
        let socket = FakeLiveSocket()
        opened.withLock { $0.append((url, socket)) }
        return socket
    }

    /// The connection with that number (from 0), once it has been opened and
    /// its subscription sent.
    func socket(_ index: Int) async throws -> FakeLiveSocket {
        try await eventually("connection \(index) subscribes") {
            sockets.count > index && !sockets[index].sent.isEmpty
        }
        return sockets[index]
    }
}

/// Waits for something the code under test does in the background. It runs
/// on its caller's actor (`#isolation`), so the condition can read the main
/// actor's state when called from there. The limit is generous because CI's
/// simulators can be many times slower than a Mac, and waiting costs nothing
/// once the condition holds.
func eventually(
    _ what: String, timeout: Duration = .seconds(30),
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting until \(what)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Collects what's passed to it, on the main actor, for checking later.
@MainActor
final class Recorder<Value: Sendable> {
    private(set) var values: [Value] = []

    func record(_ value: Value) {
        values.append(value)
    }
}

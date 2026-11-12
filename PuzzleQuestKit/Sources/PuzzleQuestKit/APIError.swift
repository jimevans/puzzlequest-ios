import Foundation

/// Why a call to the API didn't succeed.
public enum APIError: Error, Equatable, Sendable {
    /// The server refused the request and said why, as problem details.
    case problem(Problem)
    /// The server couldn't be reached: no network, or the server is down.
    case unreachable
    /// The server answered with something this version of the app can't read.
    case unexpectedResponse(String)
}

/// A refusal from the API, as RFC 9457 problem details. Act on its `type`;
/// the title and detail are the server's words, for logs rather than people.
public struct Problem: Equatable, Sendable {
    /// One of the types the API's description lists, such as
    /// `/problems/sign-in-failed`, or `about:blank` for a plain HTTP error.
    public var type: String
    public var status: Int
    public var title: String
    public var detail: String?

    public init(type: String, status: Int, title: String, detail: String? = nil) {
        self.type = type
        self.status = status
        self.title = title
        self.detail = detail
    }
}

extension Problem {
    /// The problem types the app acts on. Version 1 may add others, so code
    /// that switches on a type always has a default.
    public enum Types {
        public static let invalidRequest = "/problems/invalid-request"
        public static let signInRequired = "/problems/sign-in-required"
        public static let signInFailed = "/problems/sign-in-failed"
        public static let tooManyRequests = "/problems/too-many-requests"
        public static let unexpected = "/problems/unexpected"
        public static let wrongState = "/problems/wrong-state"
        public static let questPaused = "/problems/quest-paused"
        public static let tryAgain = "/problems/try-again"
        public static let wrongActivationCode = "/problems/wrong-activation-code"
        public static let wrongAnswer = "/problems/wrong-answer"
        public static let noMoreHints = "/problems/no-more-hints"
    }
}

extension APIError {
    /// Classifies an error thrown while calling the API.
    init(_ error: any Error) {
        switch error {
        case let error as APIError:
            self = error
        case is URLError:
            self = .unreachable
        default:
            self = .unexpectedResponse(String(describing: error))
        }
    }
}

import Foundation
import Observation

/// The sign-in screen's state: what's typed, whether it's being sent, and
/// why it last failed.
@MainActor
@Observable
public final class SignInModel {
    public var userName = ""
    public var password = ""
    public private(set) var isSigningIn = false
    public private(set) var failure: SignInFailure?

    private let session: SessionStore

    public init(session: SessionStore) {
        self.session = session
    }

    /// User names are typed by hand, often on a phone's keyboard.
    private var trimmedUserName: String {
        userName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var canSignIn: Bool {
        !trimmedUserName.isEmpty && !password.isEmpty && !isSigningIn
    }

    public func signIn() async {
        guard canSignIn else { return }
        isSigningIn = true
        failure = nil
        defer { isSigningIn = false }
        do throws(APIError) {
            try await session.signIn(userName: trimmedUserName, password: password)
            password = ""
        } catch {
            failure = SignInFailure(error)
        }
    }
}

/// Why signing in failed, as the screen explains it.
public enum SignInFailure: Equatable, Sendable {
    /// The user name and password don't match an account.
    case wrongUserNameOrPassword
    /// Too many failed attempts; wait before trying again.
    case tooManyAttempts
    /// The server didn't accept what was sent.
    case invalidRequest
    /// The server couldn't be reached.
    case unreachable
    /// Anything else, such as a fault on the server.
    case unexpected

    public init(_ error: APIError) {
        switch error {
        case .problem(let problem):
            switch problem.type {
            case Problem.Types.signInFailed: self = .wrongUserNameOrPassword
            case Problem.Types.tooManyRequests: self = .tooManyAttempts
            case Problem.Types.invalidRequest: self = .invalidRequest
            default: self = .unexpected
            }
        case .unreachable:
            self = .unreachable
        case .unexpectedResponse:
            self = .unexpected
        }
    }
}

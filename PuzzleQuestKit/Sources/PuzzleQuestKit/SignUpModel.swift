import Foundation
import Observation

/// What a new player gives to sign up, as the website's form asks.
public struct NewAccount: Equatable, Sendable {
    public var userName: String
    public var password: String
    public var displayName: String
    public var email: String
    /// Optional: US and Canadian numbers only, for now.
    public var phone: String?
    /// Whether the player agrees to text messages, with the consent shown.
    public var sms: Bool

    public init(
        userName: String, password: String, displayName: String, email: String,
        phone: String? = nil, sms: Bool = false
    ) {
        self.userName = userName
        self.password = password
        self.displayName = displayName
        self.email = email
        self.phone = phone
        self.sms = sms
    }
}

/// The sign-up form's fields, by the names the API gives them.
public enum SignUpField: String, CaseIterable, Sendable {
    case userName, password, confirmPassword, displayName, email, phone
}

/// What's wrong with a field: found here before sending, or said by the
/// server, in its own words.
public enum FieldProblem: Equatable, Sendable {
    case required
    /// The password is shorter than the server allows.
    case passwordTooShort
    /// The two passwords typed differ.
    case passwordsDiffer
    case server(String)
}

/// The sign-up screen's state: what's typed, what's wrong with it, and
/// whether it's being sent. Signing up signs the new player straight in.
@MainActor
@Observable
public final class SignUpModel {
    /// The server's rule is the one that counts; this just answers sooner.
    public static let minimumPasswordLength = 8

    public var userName = ""
    public var password = ""
    public var confirmPassword = ""
    public var displayName = ""
    public var email = ""
    public var phone = ""
    public var sms = false

    public private(set) var isSigningUp = false
    /// What's wrong with each field, from the last try.
    public private(set) var fieldProblems: [SignUpField: FieldProblem] = [:]
    /// Why the last try failed, when it isn't about a field.
    public private(set) var failure: SignUpFailure?

    private let session: SessionStore

    public init(session: SessionStore) {
        self.session = session
    }

    /// Checks the fields as the website does before sending: what's required,
    /// the password's length, and that the two passwords match.
    private func checkFields() -> [SignUpField: FieldProblem] {
        var problems: [SignUpField: FieldProblem] = [:]
        if trimmed(userName).isEmpty { problems[.userName] = .required }
        if password.count < Self.minimumPasswordLength { problems[.password] = .passwordTooShort }
        if confirmPassword != password { problems[.confirmPassword] = .passwordsDiffer }
        if trimmed(displayName).isEmpty { problems[.displayName] = .required }
        if trimmed(email).isEmpty { problems[.email] = .required }
        return problems
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clears what was said about a field, as when the player changes it.
    public func edited(_ field: SignUpField) {
        fieldProblems[field] = nil
    }

    /// Signs up, then signs in as the new player. A refusal about a field is
    /// shown at the field; anything else, above the form.
    public func signUp() async {
        guard !isSigningUp else { return }
        failure = nil
        fieldProblems = checkFields()
        guard fieldProblems.isEmpty else { return }
        isSigningUp = true
        defer { isSigningUp = false }
        let phone = trimmed(phone)
        let account = NewAccount(
            userName: trimmed(userName), password: password, displayName: trimmed(displayName),
            email: trimmed(email), phone: phone.isEmpty ? nil : phone, sms: sms)
        do throws(APIError) {
            try await session.api.signUp(account)
        } catch {
            if case .problem(let problem) = error {
                let fields = Self.fieldProblems(problem)
                if !fields.isEmpty {
                    fieldProblems = fields
                    return
                }
            }
            failure = SignUpFailure(error)
            return
        }
        // The account is made; if signing in fails now, they can sign in.
        do throws(APIError) {
            try await session.signIn(userName: account.userName, password: account.password)
        } catch {
            failure = .signedUpButNotSignedIn
        }
    }

    /// What the server said about each field, by where it was, such as
    /// `body.email`.
    static func fieldProblems(_ problem: Problem) -> [SignUpField: FieldProblem] {
        var problems: [SignUpField: FieldProblem] = [:]
        for error in problem.errors {
            guard error.path.hasPrefix("body."),
                let field = SignUpField(rawValue: String(error.path.dropFirst(5)))
            else { continue }
            problems[field] = .server(error.message)
        }
        // A password the server won't take, without saying where.
        if problems.isEmpty, problem.type == Problem.Types.passwordNotAllowed {
            problems[.password] = .server(problem.detail ?? problem.title)
        }
        return problems
    }
}

/// Why signing up failed, when it isn't about a field.
public enum SignUpFailure: Equatable, Sendable {
    /// The user name or email address is already in use; the server's words
    /// say which (as the website shows them).
    case alreadyInUse(String)
    /// Too many tries in a short time.
    case tooManyAttempts
    case unreachable
    /// The account was made, but signing in then failed: sign in with it.
    case signedUpButNotSignedIn
    case unexpected

    public init(_ error: APIError) {
        switch error {
        case .problem(let problem) where problem.type == Problem.Types.alreadyExists:
            self = .alreadyInUse(problem.detail ?? problem.title)
        case .problem(let problem) where problem.type == Problem.Types.tooManyRequests:
            self = .tooManyAttempts
        case .unreachable:
            self = .unreachable
        default:
            self = .unexpected
        }
    }
}

/// Deleting the signed-in player's own account, once they've confirmed it
/// with their password.
@MainActor
@Observable
public final class DeleteAccountModel {
    public var password = ""
    public private(set) var isDeleting = false
    public private(set) var failure: DeleteAccountFailure?

    private let session: SessionStore

    public init(session: SessionStore) {
        self.session = session
    }

    public var canDelete: Bool { !password.isEmpty && !isDeleting }

    /// Deletes the account. On success, the session is gone and the app is
    /// signed out.
    public func delete() async {
        guard canDelete else { return }
        isDeleting = true
        failure = nil
        defer { isDeleting = false }
        do throws(APIError) {
            try await session.deleteAccount(password: password)
        } catch {
            failure = DeleteAccountFailure(error)
        }
    }
}

/// Why deleting an account failed.
public enum DeleteAccountFailure: Equatable, Sendable {
    case incorrectPassword
    /// Too many wrong passwords in a short time.
    case tooManyAttempts
    /// It can't be deleted now, as the only administrator's can't.
    case notPossible
    case unreachable
    case unexpected

    public init(_ error: APIError) {
        switch error {
        case .problem(let problem):
            switch problem.type {
            case Problem.Types.incorrectPassword: self = .incorrectPassword
            case Problem.Types.tooManyRequests: self = .tooManyAttempts
            case Problem.Types.wrongState: self = .notPossible
            default: self = .unexpected
            }
        case .unreachable:
            self = .unreachable
        case .unexpectedResponse:
            self = .unexpected
        }
    }
}

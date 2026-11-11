import PuzzleQuestAPI

/// Who is signed in.
public struct SignedInUser: Equatable, Sendable {
    public var userName: String
    public var displayName: String
    public var role: Role
    /// Whether they've followed the link in the email sent to their address.
    public var emailVerified: Bool

    public init(userName: String, displayName: String, role: Role, emailVerified: Bool) {
        self.userName = userName
        self.displayName = displayName
        self.role = role
        self.emailVerified = emailVerified
    }

    /// What the app shows them once signed in.
    public var homeScreen: HomeScreen { HomeScreen(role) }
}

/// What the app shows someone once they're signed in. The app is for players;
/// staff and administrators have their tools on the website.
public enum HomeScreen: Equatable, Sendable {
    /// Their quests.
    case quests
    /// A note that their tools are on the website.
    case website

    public init(_ role: Role) {
        switch role {
        case .player: self = .quests
        // A role added later is more likely one with tools of its own (players
        // are everyone's starting role), and the website is where those are.
        case .staff, .admin, .other: self = .website
        }
    }
}

/// What a user may do. Version 1 may add roles, which the app shows as
/// `.other` rather than failing.
public enum Role: Equatable, Sendable {
    case player
    case staff
    case admin
    case other(String)
}

extension SignedInUser {
    init(_ user: Components.Schemas.User) {
        self.init(
            userName: user.userName, displayName: user.displayName, role: Role(user.role),
            emailVerified: user.emailVerified)
    }
}

extension Role {
    init(_ role: Components.Schemas.Role) {
        switch role.value1 {
        case .player: self = .player
        case .staff: self = .staff
        case .admin: self = .admin
        case nil: self = .other(role.value2 ?? "")
        }
    }
}

import PuzzleQuestAPI

/// Who is signed in.
public struct SignedInUser: Equatable, Sendable {
    public var userName: String
    public var displayName: String
    public var role: Role

    public init(userName: String, displayName: String, role: Role) {
        self.userName = userName
        self.displayName = displayName
        self.role = role
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
        self.init(userName: user.userName, displayName: user.displayName, role: Role(user.role))
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

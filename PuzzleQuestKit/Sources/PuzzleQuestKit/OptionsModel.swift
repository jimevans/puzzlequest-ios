import Foundation
import Observation

/// The servers the Options screen offers.
public enum ServerChoice: Hashable, Sendable {
    /// https://thepuzzlequest.com.
    case production
    /// http://localhost:3000, in debug builds.
    case thisMac
    /// An address the person types.
    case custom
}

/// The Options screen's state: which server is chosen, a custom address being
/// typed and checked, and a switch waiting for the person to confirm it.
@MainActor
@Observable
public final class OptionsModel {
    /// The choice shown as selected. Picking Custom selects it before any
    /// address is used; otherwise it's the server in use (not one waiting
    /// for confirmation).
    public private(set) var choice: ServerChoice
    /// The custom address as typed.
    public var customAddress: String
    /// Whether a custom server is being checked.
    public private(set) var isChecking = false
    /// Why the custom address was refused, until it's tried again.
    public private(set) var failure: CustomServerFailure?
    /// A server to switch to once the person confirms that it signs them
    /// out.
    public private(set) var pendingSwitch: ServerOrigin?

    /// Whether This Mac is offered (debug builds).
    public let offersThisMac: Bool

    private let connection: ServerConnection
    private let serverCheck: ServerCheck

    public convenience init(connection: ServerConnection, offersThisMac: Bool) {
        self.init(connection: connection, offersThisMac: offersThisMac, serverCheck: ServerCheck())
    }

    package init(connection: ServerConnection, offersThisMac: Bool, serverCheck: ServerCheck) {
        self.connection = connection
        self.offersThisMac = offersThisMac
        self.serverCheck = serverCheck
        let choice = Self.choice(for: connection.server, offersThisMac: offersThisMac)
        self.choice = choice
        customAddress = choice == .custom ? connection.server.url.absoluteString : ""
    }

    private static func choice(for server: ServerOrigin, offersThisMac: Bool) -> ServerChoice {
        switch server {
        case .production: .production
        case .thisMac where offersThisMac: .thisMac
        default: .custom
        }
    }

    /// The choice that matches the server in use.
    private var currentChoice: ServerChoice {
        Self.choice(for: connection.server, offersThisMac: offersThisMac)
    }

    public var canUseCustomAddress: Bool {
        !customAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isChecking
    }

    /// Picks a server: Production and This Mac are used at once (after
    /// confirming, if it signs someone out); Custom waits for an address.
    public func choose(_ newChoice: ServerChoice) {
        failure = nil
        switch newChoice {
        case .production:
            requestSwitch(to: .production)
        case .thisMac:
            guard offersThisMac else { return }
            requestSwitch(to: .thisMac)
        case .custom:
            choice = .custom
        }
    }

    /// Uses the typed address: checks this build may use it, then that it's a
    /// PuzzleQuest server, then switches (after confirming, if it signs
    /// someone out). A refusal is kept to explain, and the address can be
    /// tried again.
    public func useCustomAddress() async {
        guard canUseCustomAddress else { return }
        failure = nil
        let server: ServerOrigin
        do throws(ServerAddressRefusal) {
            server = try connection.policy.check(customAddress)
        } catch {
            failure = .refused(error)
            return
        }
        customAddress = server.url.absoluteString
        guard server != connection.server else { return }
        // PuzzleQuest's own servers need no checking.
        if server != .production && server != .thisMac {
            isChecking = true
            defer { isChecking = false }
            do throws(ServerCheckFailure) {
                try await serverCheck.check(server)
            } catch {
                failure = .checkFailed(error)
                return
            }
        }
        requestSwitch(to: server)
    }

    /// Switches now if no one would be signed out; otherwise asks first.
    /// Choosing the server in use does nothing.
    private func requestSwitch(to server: ServerOrigin) {
        guard server != connection.server else {
            choice = currentChoice
            return
        }
        if connection.switchingSignsOut {
            pendingSwitch = server
        } else {
            switchTo(server)
        }
    }

    /// The person agreed to be signed out.
    public func confirmSwitch(to server: ServerOrigin) {
        pendingSwitch = nil
        switchTo(server)
    }

    /// The person chose to stay: nothing changes.
    public func cancelSwitch() {
        pendingSwitch = nil
    }

    private func switchTo(_ server: ServerOrigin) {
        connection.switchTo(server)
        choice = currentChoice
    }
}

/// Why a custom server wasn't used.
public enum CustomServerFailure: Equatable, Sendable {
    /// This build may not use that address.
    case refused(ServerAddressRefusal)
    /// It couldn't be confirmed as a PuzzleQuest server.
    case checkFailed(ServerCheckFailure)
}

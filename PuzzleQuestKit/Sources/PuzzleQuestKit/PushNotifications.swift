import Foundation
import Observation

/// A push notification from PuzzleQuest, as the app receives it (the API's
/// `push-notifications.json`): which kind it is and the quest it's about,
/// beside the alert's title and body, which iOS shows by itself.
public struct PuzzleQuestNotification: Equatable, Sendable {
    /// The kind, such as `questStarted` or `message`. Version 1 may add
    /// kinds; an unknown one is still about its quest.
    public var category: String
    public var questName: String
    /// The puzzle it's about, where there is one.
    public var puzzleName: String?

    public init(category: String, questName: String, puzzleName: String? = nil) {
        self.category = category
        self.questName = questName
        self.puzzleName = puzzleName
    }

    /// Reads a notification's custom keys, which Apple's service delivers
    /// beside `aps`; nil for one that isn't PuzzleQuest's.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let category = userInfo["category"] as? String,
            let questName = userInfo["questName"] as? String
        else { return nil }
        self.init(
            category: category, questName: questName,
            puzzleName: userInfo["puzzleName"] as? String)
    }
}

/// Which of Apple's push services the app's token is for.
public enum PushEnvironment: String, Sendable {
    /// For apps from the App Store or TestFlight.
    case production
    /// For apps built and run from Xcode, and the simulator.
    case development

    /// This app's: development in the simulator, and when the app's
    /// provisioning profile says so (a build run from Xcode); production
    /// otherwise, as from the App Store, which has no profile in the app.
    public static var current: PushEnvironment {
        #if targetEnvironment(simulator)
            return .development
        #else
            guard
                let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
                let profile = try? Data(contentsOf: url)
            else { return .production }
            return from(provisioningProfile: profile)
        #endif
    }

    /// Reads the environment from a provisioning profile, a signed property
    /// list whose entitlements name it as `aps-environment`.
    static func from(provisioningProfile: Data) -> PushEnvironment {
        // The property list sits inside the signature as plain text.
        let text = String(decoding: provisioningProfile, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>") else { return .production }
        let after = text[key.upperBound...].prefix(100)
        return after.contains("<string>development</string>") ? .development : .production
    }
}

/// Whether the player has let the app show notifications.
public enum NotificationPermission: Equatable, Sendable {
    /// Not asked yet: iOS asks once, when the app first asks.
    case notAsked
    case allowed
    /// Refused; only the Settings app can change it now.
    case refused
}

/// What the registrar needs of iOS, so tests can stand in for it.
@MainActor
public protocol NotificationSystem {
    func permission() async -> NotificationPermission
    /// Asks the player, the one time iOS lets the app; returns whether they
    /// allowed it.
    func requestPermission() async -> Bool
    /// Asks Apple for the phone's token, which arrives through the app
    /// delegate (`received(deviceToken:)`).
    func registerForRemoteNotifications()
}

/// Gets the player's notifications to this phone: asks for permission when
/// the player chooses to, on a quest (never right after signing in), and
/// registers the phone's token with their session on each launch, since
/// tokens change. Signing out ends the session, and its notifications with
/// it. Tracks the quest on screen, whose notifications aren't shown, since
/// live updates have already shown what changed, and the quest a tapped
/// notification should open.
@MainActor
@Observable
public final class PushRegistrar {
    public private(set) var permission: NotificationPermission?
    /// The phone's token with Apple, in hexadecimal, once iOS gives it.
    public private(set) var deviceToken: String?
    /// The quest a tapped notification is about, for the home screen to open.
    public var questToOpen: String?
    /// The quest on screen, if any.
    public var questOnScreen: String?

    private let system: any NotificationSystem
    private let defaults: UserDefaults
    private let environment: PushEnvironment
    private var declined: Set<String>
    /// The token and server last registered, so it's sent once each.
    private var registered: (token: String, server: URL)?

    private static let declinedKey = "PuzzleQuest.notificationsDeclined"

    public init(
        system: any NotificationSystem, defaults: UserDefaults = .standard,
        environment: PushEnvironment = .current
    ) {
        self.system = system
        self.defaults = defaults
        self.environment = environment
        declined = Set(defaults.stringArray(forKey: Self.declinedKey) ?? [])
    }

    /// Whether to offer notifications on a quest's screen: until the player
    /// answers iOS's question, or says "Not now" on that quest.
    public func offers(onQuest questName: String) -> Bool {
        permission == .notAsked && !declined.contains(questName)
    }

    /// Checks the permission, and once allowed, asks Apple for the token
    /// again, as on each launch.
    public func refresh() async {
        permission = await system.permission()
        if permission == .allowed {
            system.registerForRemoteNotifications()
        }
    }

    /// The player chose to turn notifications on: asks iOS, then Apple for
    /// the token.
    public func turnOn() async {
        let allowed = await system.requestPermission()
        permission = allowed ? .allowed : .refused
        if allowed {
            system.registerForRemoteNotifications()
        }
    }

    /// The player said "Not now" on a quest: it isn't offered there again.
    public func notNow(onQuest questName: String) {
        declined.insert(questName)
        defaults.set(Array(declined).sorted(), forKey: Self.declinedKey)
    }

    /// Apple gave the phone's token.
    public func received(deviceToken: Data) {
        self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    /// Registers the phone's token with the signed-in session, if there is a
    /// token and it isn't registered already. Failing is fine: it's tried
    /// again on the next launch.
    public func register(with api: APIClient) async {
        guard let deviceToken, registered?.token != deviceToken || registered?.server != api.server
        else { return }
        do throws(APIError) {
            try await api.setPushTarget(token: deviceToken, environment: environment)
            registered = (deviceToken, api.server)
        } catch {}
    }

    /// Whether to show a notification that arrives while the app is open:
    /// not one about the quest on screen.
    public func shows(_ notification: PuzzleQuestNotification) -> Bool {
        notification.questName != questOnScreen
    }

    /// The player tapped a notification: its quest should open.
    public func opened(_ notification: PuzzleQuestNotification) {
        questToOpen = notification.questName
    }
}

import Foundation
import Testing

@testable import PuzzleQuestKit

@Suite("Reading a push notification")
struct PushNotificationTests {
    @Test("Its kind, quest, and puzzle are read from beside aps, as the API's push-notifications.json says")
    func reads() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Harbor walk", "body": "Your team solved The Lighthouse."]],
            "category": "stopSolved", "questName": "harbor", "puzzleName": "lighthouse",
        ]
        #expect(
            PuzzleQuestNotification(userInfo: userInfo)
                == PuzzleQuestNotification(
                    category: "stopSolved", questName: "harbor", puzzleName: "lighthouse"))
        let message = try #require(
            PuzzleQuestNotification(userInfo: ["category": "message", "questName": "harbor"]))
        #expect(message.puzzleName == nil)
    }

    @Test("A notification that isn't PuzzleQuest's isn't read")
    func notOurs() {
        #expect(PuzzleQuestNotification(userInfo: ["aps": ["alert": "Hello"]]) == nil)
        #expect(PuzzleQuestNotification(userInfo: ["category": "message"]) == nil)
    }

    @Test("Every kind the pinned API describes is read, and an unknown one too")
    func everyKind() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "api/push-notifications.json")
        let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let properties = try #require(schema?["properties"] as? [String: Any])
        let kinds = try #require((properties["category"] as? [String: Any])?["enum"] as? [String])
        #expect(kinds.contains("message"))
        for kind in kinds + ["somethingNew"] {
            #expect(
                PuzzleQuestNotification(userInfo: ["category": kind, "questName": "harbor"])?.category
                    == kind)
        }
    }
}

@Suite("Which of Apple's services the app is for")
struct PushEnvironmentTests {
    func profile(_ environment: String?) -> Data {
        let entitlement =
            environment.map { "<key>aps-environment</key>\n\t\t<string>\($0)</string>" } ?? ""
        return Data(
            "binary signature…<?xml version=\"1.0\"?><plist><dict><key>Entitlements</key><dict>\(entitlement)<key>application-identifier</key><string>X.com.thepuzzlequest.PuzzleQuest</string></dict></dict></plist>…signature"
                .utf8)
    }

    @Test("A profile from Xcode says development; one for distribution, or none, production")
    func fromProfile() {
        #expect(PushEnvironment.from(provisioningProfile: profile("development")) == .development)
        #expect(PushEnvironment.from(provisioningProfile: profile("production")) == .production)
        #expect(PushEnvironment.from(provisioningProfile: profile(nil)) == .production)
    }
}

/// Stands in for iOS's notifications.
@MainActor
final class FakeNotificationSystem: NotificationSystem {
    var current: NotificationPermission
    var allows: Bool
    var registrations = 0

    init(_ current: NotificationPermission, allows: Bool = true) {
        self.current = current
        self.allows = allows
    }

    func permission() async -> NotificationPermission { current }

    func requestPermission() async -> Bool {
        current = allows ? .allowed : .refused
        return allows
    }

    func registerForRemoteNotifications() { registrations += 1 }
}

@MainActor
@Suite("Getting a player's notifications to their phone")
struct PushRegistrarTests {
    let defaults: UserDefaults
    let suite = "PushRegistrarTests.\(UUID().uuidString)"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func registrar(_ system: FakeNotificationSystem) -> PushRegistrar {
        PushRegistrar(system: system, defaults: defaults, environment: .development)
    }

    @Test("It's offered on each quest until the player answers iOS, or says Not now there")
    func offering() async {
        let system = FakeNotificationSystem(.notAsked)
        let push = registrar(system)
        #expect(!push.offers(onQuest: "harbor"))
        await push.refresh()
        #expect(push.offers(onQuest: "harbor"))
        #expect(system.registrations == 0)

        push.notNow(onQuest: "harbor")
        #expect(!push.offers(onQuest: "harbor"))
        #expect(push.offers(onQuest: "castle"))
        // Remembered on the phone.
        let again = registrar(system)
        await again.refresh()
        #expect(!again.offers(onQuest: "harbor"))

        await push.turnOn()
        #expect(push.permission == .allowed)
        #expect(!push.offers(onQuest: "castle"))
        #expect(system.registrations == 1)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Refused, it's offered no more, and nothing is registered")
    func refused() async {
        let system = FakeNotificationSystem(.notAsked, allows: false)
        let push = registrar(system)
        await push.refresh()
        await push.turnOn()
        #expect(push.permission == .refused)
        #expect(!push.offers(onQuest: "harbor"))
        #expect(system.registrations == 0)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Once allowed, Apple is asked for the token on each launch")
    func eachLaunch() async {
        let system = FakeNotificationSystem(.allowed)
        await registrar(system).refresh()
        await registrar(system).refresh()
        #expect(system.registrations == 2)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("The token is registered with the session once, again when it or the server changes")
    func registering() async throws {
        let transport = FakeTransport { _ in json(204, "") }
        let api = api(transport, tokens: InMemoryTokenStore(token: "t"))
        let push = registrar(FakeNotificationSystem(.allowed))
        await push.register(with: api)
        #expect(transport.requests.isEmpty)

        push.received(deviceToken: Data([0x0a, 0xff, 0x01]))
        #expect(push.deviceToken == "0aff01")
        await push.register(with: api)
        await push.register(with: api)
        #expect(transport.requests.map(\.request.path) == ["/sessions/current/push-target"])
        #expect(transport.requests.first?.request.method == .put)
        let body = try #require(transport.requests.first?.body)
        let sent = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect(sent?["platform"] as? String == "ios")
        #expect(sent?["token"] as? String == "0aff01")
        #expect(sent?["environment"] as? String == "development")
        #expect(sent?["categories"] == nil)

        push.received(deviceToken: Data([0x0b]))
        await push.register(with: api)
        #expect(transport.requests.count == 2)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("A failed registration is tried again")
    func retries() async {
        let transport = FakeTransport { _ in problem(500, Problem.Types.unexpected) }
        let api = api(transport, tokens: InMemoryTokenStore(token: "t"))
        let push = registrar(FakeNotificationSystem(.allowed))
        push.received(deviceToken: Data([0x01]))
        await push.register(with: api)
        await push.register(with: api)
        #expect(transport.requests.count == 2)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("A notification about the quest on screen isn't shown; a tapped one opens its quest")
    func showingAndOpening() {
        let push = registrar(FakeNotificationSystem(.allowed))
        let harbor = PuzzleQuestNotification(category: "message", questName: "harbor")
        #expect(push.shows(harbor))
        push.questOnScreen = "harbor"
        #expect(!push.shows(harbor))
        #expect(push.shows(PuzzleQuestNotification(category: "questStarted", questName: "castle")))

        push.opened(harbor)
        #expect(push.questToOpen == "harbor")
        defaults.removePersistentDomain(forName: suite)
    }
}

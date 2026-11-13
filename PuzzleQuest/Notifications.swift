import PuzzleQuestKit
import SwiftUI
import UIKit
import UserNotifications

/// Receives what iOS tells the app about notifications: the phone's token
/// with Apple, a notification arriving while the app is open, and a
/// notification tapped. The registrar it holds is what the screens use.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let push = PushRegistrar(system: SystemNotifications())

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        push.received(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // Without a token there's nothing to register; the next launch tries
        // again. The puzzle master's messages are texted meanwhile.
    }

    /// A notification arriving while the app is open is shown, unless it's
    /// about the quest on screen, which live updates have already shown.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let received = PuzzleQuestNotification(
            userInfo: notification.request.content.userInfo)
        return await MainActor.run {
            if let received, !push.shows(received) {
                return []
            }
            return [.banner, .list, .sound]
        }
    }

    /// A tapped notification opens its quest.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard
            let tapped = PuzzleQuestNotification(
                userInfo: response.notification.request.content.userInfo)
        else { return }
        await MainActor.run { push.opened(tapped) }
    }
}

/// iOS's notification permission and registration, as the registrar uses
/// them.
struct SystemNotifications: NotificationSystem {
    func permission() async -> NotificationPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .refused
        default: .allowed
        }
    }

    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [
            .alert, .sound,
        ])) ?? false
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// Offers notifications on a quest's screen, the first time and until the
/// player answers: what they'd be told, with Turn on, which asks iOS, and
/// Not now, which stops offering on this quest.
struct NotificationsCard: View {
    let questName: String
    @Environment(PushRegistrar.self) private var push

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Get told when it matters", systemImage: "bell.badge.fill")
                .font(.headline)
            Text(
                "Notifications tell you when the quest starts, when the puzzle master pauses it or sends you a challenge, when a teammate solves a stop, and how a race ends, even with the app closed. With them on, the puzzle master's messages usually aren't texted to you as well."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            HStack {
                Button("Turn on") { Task { await push.turnOn() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("quest.notifications.turn-on")
                Button("Not now") { push.notNow(onQuest: questName) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("quest.notifications.not-now")
            }
        }
        .padding(.vertical, 6)
    }
}

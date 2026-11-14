import Foundation
import UIKit
import UserNotifications

/// Notifications from the relay: a silent hint that sealed mail is waiting,
/// and a visible one when a case's wake comes due. Either way the app only
/// refreshes; the notification itself carries nothing about the errand.
@MainActor
enum RelayPush {
    static var connection: RelayConnection?

    /// Asked when the first real errand starts, not at launch, so the owner
    /// knows why Steward wants to notify them.
    static func requestPermission() {
        guard connection != nil else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    static func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard let connection else { return }
        Task { await connection.setPushToken(token) }
    }
}

/// The few app-level events SwiftUI doesn't hand over: push registration and
/// background pushes.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Already allowed earlier: keep the relay's push token fresh.
        if RelayPush.connection != nil {
            Task {
                if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized {
                    application.registerForRemoteNotifications()
                }
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RelayPush.didRegister(deviceToken: deviceToken)
    }

    /// A silent push: mail is waiting at the relay.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let runner = CaseService.runner else { return .noData }
        await runner.refresh()
        return .newData
    }

    /// A wake notification while the app is open: show it, and catch up.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await CaseService.runner?.refresh()
        return [.banner, .sound]
    }

    /// The owner tapped a notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await CaseService.runner?.refresh()
    }
}

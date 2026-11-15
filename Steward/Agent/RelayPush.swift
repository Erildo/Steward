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
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            // Check-in and follow-up notifications are local; pushes need a relay.
            if connection != nil { UIApplication.shared.registerForRemoteNotifications() }
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

    /// A silent push: mail is waiting at the relay, so check in early.
    /// Optional: without pushes, the scheduled check-ins collect it.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard CaseService.runner != nil else { return .noData }
        await CheckIn.run(inBackground: application.applicationState != .active)
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

/// Follow-up times as notifications scheduled on the phone itself, so
/// wake-ups never depend on a server (docs/adr/0003). The notification says
/// nothing about the errand.
@MainActor
enum LocalWake {
    static func set(_ caseID: UUID, at date: Date?) {
        let center = UNUserNotificationCenter.current()
        let id = "wake-\(caseID.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let date, date > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = "Steward"
        content.body = "An errand has something to check."
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        center.add(request)
    }
}

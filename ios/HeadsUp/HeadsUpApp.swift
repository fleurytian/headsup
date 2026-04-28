import SwiftUI
import UserNotifications

@main
struct HeadsUpApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var auth = AuthService.shared
    @StateObject private var push = PushService.shared
    @StateObject private var deepLink = DeepLinkHandler.shared
    @StateObject private var loc = Localizer.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(push)
                .environmentObject(deepLink)
                .environmentObject(loc)
                .onOpenURL { url in
                    deepLink.handle(url: url)
                }
                .task {
                    if auth.isSignedIn {
                        await push.requestAuthorization()
                    }
                    // Resume a deferred-deep-link authorization left in the clipboard
                    // (e.g. user tapped invite link, installed app, then opened it).
                    deepLink.consumeClipboardIfPresent()
                }
        }
    }
}

// AppDelegate handles APNs token registration callbacks + foreground notification banners.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushService.shared.setDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushService.shared.setRegistrationError(error)
        }
    }

    // Silent push handler — backend sends one whenever an Agent's categories change.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if (userInfo["type"] as? String) == "categories_updated" {
            Task { @MainActor in
                await PushService.shared.refreshCategories()
                completionHandler(.newData)
            }
        } else {
            completionHandler(.noData)
        }
    }

    // Show notifications even when app is in foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    // Called when user taps a notification action button (or the notification body).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        guard let messageId = info["message_id"] as? String else {
            completionHandler()
            return
        }

        let actionId = response.actionIdentifier
        let buttonId = actionId == UNNotificationDefaultActionIdentifier ? "default" : actionId
        let categoryId = response.notification.request.content.categoryIdentifier

        let originalNotificationId = response.notification.request.identifier

        Task {
            let label = await Self.lookupButtonLabel(categoryId: categoryId, buttonId: buttonId)
            // Show confirmation immediately, before the network call returns,
            // so the user gets instant feedback.
            if buttonId != "default" {
                Self.postConfirmationNotification(label: label, success: true)
            }
            // Remove the original notification from notification center so it doesn't
            // sit there confusing the user about whether they responded.
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [originalNotificationId]
            )
            _ = await Self.reportAction(messageId: messageId, buttonId: buttonId, buttonLabel: label)
            completionHandler()
        }
    }

    /// Look up the button title from the currently-registered categories.
    static func lookupButtonLabel(categoryId: String, buttonId: String) async -> String {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationCategories { categories in
                if let cat = categories.first(where: { $0.identifier == categoryId }),
                   let action = cat.actions.first(where: { $0.identifier == buttonId }) {
                    cont.resume(returning: action.title)
                } else {
                    cont.resume(returning: buttonId)
                }
            }
        }
    }

    /// Show a banner-level local notification confirming the response was sent.
    /// Auto-dismisses from notification center 5 seconds later.
    static func postConfirmationNotification(label: String, success: Bool) {
        let content = UNMutableNotificationContent()
        content.title = success ? "✓ 已记录" : "⚠️ 失败"
        content.body = label
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
        }
        let id = "confirm_\(UUID().uuidString)"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err = err { print("Confirmation notification add failed: \(err)") }
        }
        // Self-dismiss after 5 seconds so notification center stays clean
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    @MainActor
    static func reportAction(messageId: String, buttonId: String, buttonLabel: String) async -> Bool {
        guard let session = AuthService.shared.session else { return false }
        let req = ActionReportRequest(messageId: messageId, buttonId: buttonId, buttonLabel: buttonLabel)
        do {
            struct Empty: Codable {}
            let _: Empty = try await APIClient.shared.post(
                "/v1/app/actions/report",
                body: req,
                sessionToken: session.sessionToken
            )
            return true
        } catch {
            print("Failed to report action: \(error)")
            return false
        }
    }
}

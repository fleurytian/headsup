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

    /// Clear the icon badge whenever the app comes to the foreground — but keep
    /// the notifications themselves in Notification Center, so the user can still
    /// scroll back to anything they haven't read.
    func applicationDidBecomeActive(_ application: UIApplication) {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0)
        } else {
            application.applicationIconBadgeNumber = 0
        }
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

    // Silent push handler — backend sends one of these for several reasons.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // 1. Category sync — agent created/updated a custom category.
        if (userInfo["type"] as? String) == "categories_updated" {
            Task { @MainActor in
                await PushService.shared.refreshCategories()
                completionHandler(.newData)
            }
            return
        }

        // 2. Agent retracted a previous push — pull it from Notification Center
        //    so the user doesn't act on a now-obsolete prompt.
        if (userInfo["delete"] as? String) == "1",
           let id = userInfo["id"] as? String {
            Task { @MainActor in
                let center = UNUserNotificationCenter.current()
                // The original notification was scheduled with the message id
                // as its identifier (or contains it in userInfo). Remove both
                // by-identifier and by-userInfo to be safe.
                center.removeDeliveredNotifications(withIdentifiers: [id])
                let delivered = await center.deliveredNotifications()
                let stragglers = delivered.compactMap { n -> String? in
                    let info = n.request.content.userInfo
                    return (info["message_id"] as? String) == id ? n.request.identifier : nil
                }
                if !stragglers.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: stragglers)
                }
                NotificationCenter.default.post(name: .headsupHistoryChanged, object: nil)
                completionHandler(.newData)
            }
            return
        }

        completionHandler(.noData)
    }

    // Show notifications even when app is in foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A new push arrived — any history view on screen should refresh now.
        NotificationCenter.default.post(name: .headsupHistoryChanged, object: nil)
        completionHandler([.banner, .sound, .badge])
    }

    // Called when user taps a notification action button (or the notification body).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier
        let categoryId = response.notification.request.content.categoryIdentifier
        let originalNotificationId = response.notification.request.identifier
        let body = response.notification.request.content.body

        // ── Local-only actions (no server report) ────────────────────────────

        // Swipe-to-dismiss — opportunistic device-token refresh so a stale token
        // gets replaced before the next push attempt. Free; doesn't talk to
        // server unless the token actually changed.
        if actionId == UNNotificationDismissActionIdentifier {
            Task { await PushService.shared.refreshDeviceToken() }
            completionHandler()
            return
        }

        // Copy action — write body (or auto_copy override) to clipboard,
        // toast the user, and don't bother the agent with a "copy" reply.
        if actionId == "copy" {
            let textToCopy = (info["auto_copy"] as? String).map { $0.isEmpty ? body : $0 } ?? body
            UIPasteboard.general.string = textToCopy
            Self.postConfirmationNotification(label: "已复制 · Copied", success: true)
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [originalNotificationId]
            )
            completionHandler()
            return
        }

        // ── Agent-bound actions ──────────────────────────────────────────────
        guard let messageId = info["message_id"] as? String else {
            completionHandler()
            return
        }
        let buttonId = actionId == UNNotificationDefaultActionIdentifier ? "default" : actionId

        Task {
            let label = await Self.lookupButtonLabel(categoryId: categoryId, buttonId: buttonId)
            if buttonId != "default" {
                Self.postConfirmationNotification(label: label, success: true)
            }
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [originalNotificationId]
            )
            _ = await Self.reportAction(messageId: messageId, buttonId: buttonId, buttonLabel: label)
            await MainActor.run {
                NotificationCenter.default.post(name: .headsupHistoryChanged, object: nil)
            }
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

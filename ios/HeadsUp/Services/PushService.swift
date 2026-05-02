import Foundation
import UIKit
import UserNotifications

struct ServerCategoryButton: Codable {
    let id: String
    let label: String
    let icon: String?
    let destructive: Bool
}

struct ServerCategory: Codable {
    let ios_id: String
    let buttons: [ServerCategoryButton]
}

@MainActor
final class PushService: NSObject, ObservableObject {
    static let shared = PushService()

    @Published private(set) var deviceTokenString: String?
    @Published private(set) var permissionGranted: Bool = false
    @Published private(set) var serverCategories: [ServerCategory] = []

    // Called from the AppDelegate when APNs returns a token
    func setDeviceToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        self.deviceTokenString = token
        Task { await syncDeviceTokenWithBackend() }
    }

    // Called from AppDelegate on registration failure
    func setRegistrationError(_ error: Error) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    /// Asks the user for notification permission and registers categories + APNs.
    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            self.permissionGranted = granted
            if granted {
                await refreshCategories()
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            print("Notification authorization error: \(error)")
        }
    }

    /// Pull custom categories from backend and register everything (built-in + custom).
    func refreshCategories() async {
        if let session = AuthService.shared.session {
            do {
                let cats: [ServerCategory] = try await APIClient.shared.get(
                    "/v1/app/categories",
                    sessionToken: session.sessionToken
                )
                self.serverCategories = cats
            } catch {
                print("Failed to fetch categories: \(error)")
            }
        }
        registerAllCategories()
    }

    /// Re-register with APNs so iOS hands us back a fresh device token on the
    /// next callback. Triggered opportunistically on swipe-to-dismiss.
    /// Cheap — usually returns the same token without round-tripping our server.
    func refreshDeviceToken() async {
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// After a successful login, send the latest token to the backend.
    func syncDeviceTokenWithBackend() async {
        guard let token = deviceTokenString,
              let session = AuthService.shared.session else { return }
        struct Body: Codable {
            let apns_device_token: String
        }
        do {
            let _: DeviceTokenResponse = try await APIClient.shared.post(
                "/v1/app/register-device",
                body: Body(apns_device_token: token),
                sessionToken: session.sessionToken
            )
        } catch {
            print("Token sync failed: \(error)")
        }
    }

    // ── Category registration ────────────────────────────────────────────────

    private func registerAllCategories() {
        var all: [UNNotificationCategory] = []

        // .customDismissAction: a swipe-to-dismiss wakes the app's didReceive
        // handler, which lets us refresh the APNs device token + bump local
        // history. Cheap and useful — Bark uses the same option.
        let baseOptions: UNNotificationCategoryOptions = [.customDismissAction]

        // info_only: notification with no agent buttons. Still attach Copy
        // so the user can grab the body without opening the app.
        all.append(UNNotificationCategory(
            identifier: "info_only",
            actions: [Self.copyAction()],
            intentIdentifiers: [],
            options: baseOptions
        ))

        // 8 built-in categories — append Later (if room) + Copy (always, last).
        for cat in NotificationCategory.allCases {
            var actions: [UNNotificationAction] = cat.builtInActions
            if actions.count < 3 {                       // leave room for Copy
                actions.append(Self.laterAction())
            }
            actions.append(Self.copyAction())
            all.append(UNNotificationCategory(
                identifier: cat.rawValue,
                actions: actions,
                intentIdentifiers: [],
                options: baseOptions
            ))
        }

        // Custom agent categories — same recipe.
        for sc in serverCategories {
            var actions: [UNNotificationAction] = sc.buttons.map { btn -> UNNotificationAction in
                var options: UNNotificationActionOptions = []
                if btn.destructive { options.insert(.destructive) }
                if let icon = btn.icon, !icon.isEmpty, #available(iOS 15.0, *) {
                    return UNNotificationAction(
                        identifier: btn.id,
                        title: btn.label,
                        options: options,
                        icon: UNNotificationActionIcon(systemImageName: icon)
                    )
                }
                return UNNotificationAction(identifier: btn.id, title: btn.label, options: options)
            }
            if actions.count < 3 {
                actions.append(Self.laterAction())
            }
            // Only have room for Copy if total < 4 — iOS hard-caps at 4 lock-screen actions.
            if actions.count < 4 {
                actions.append(Self.copyAction())
            }
            all.append(UNNotificationCategory(
                identifier: sc.ios_id,
                actions: actions,
                intentIdentifiers: [],
                options: baseOptions
            ))
        }

        UNUserNotificationCenter.current().setNotificationCategories(Set(all))
    }

    static func laterAction() -> UNNotificationAction {
        if #available(iOS 15.0, *) {
            return UNNotificationAction(
                identifier: "later",
                title: "稍后再说",
                options: [],
                icon: UNNotificationActionIcon(systemImageName: "clock.fill")
            )
        }
        return UNNotificationAction(identifier: "later", title: "稍后再说", options: [])
    }

    /// "复制 / Copy" — handled in HeadsUpApp's didReceive: writes the body (or
    /// the auto_copy override) to UIPasteboard. Always last in the list so iOS
    /// shows the agent's primary action first.
    static func copyAction() -> UNNotificationAction {
        if #available(iOS 15.0, *) {
            return UNNotificationAction(
                identifier: "copy",
                title: "复制",
                options: [],
                icon: UNNotificationActionIcon(systemImageName: "doc.on.doc")
            )
        }
        return UNNotificationAction(identifier: "copy", title: "复制", options: [])
    }
}

enum NotificationCategory: String, CaseIterable {
    case confirmReject = "confirm_reject"
    case yesNo = "yes_no"
    case approveCancel = "approve_cancel"
    case chooseAB = "choose_a_b"
    case agreeDecline = "agree_decline"
    case remindLaterSkip = "remind_later_skip"
    case actionDismiss = "action_dismiss"
    case feedback
    /// 4-button category for agent tool-call permission gates.
    /// allow_once / allow_session / allow_always / deny.
    /// Used by tools/headsup-ask when wired into agent PreToolUse hooks.
    case permissionGate = "permission_gate"

    var builtInActions: [UNNotificationAction] {
        self.actions.map { entry -> UNNotificationAction in
            if let symbol = entry.icon, #available(iOS 15.0, *) {
                return UNNotificationAction(
                    identifier: entry.id,
                    title: entry.title,
                    options: entry.options,
                    icon: UNNotificationActionIcon(systemImageName: symbol)
                )
            }
            return UNNotificationAction(identifier: entry.id, title: entry.title, options: entry.options)
        }
    }

    private typealias ActionEntry = (id: String, title: String, icon: String?, options: UNNotificationActionOptions)

    private var actions: [ActionEntry] {
        switch self {
        case .confirmReject:
            return [
                ("confirm", "确认", "checkmark.circle.fill", []),
                ("reject",  "拒绝", "xmark.circle.fill", [.destructive]),
            ]
        case .yesNo:
            return [
                ("yes", "是", "checkmark", []),
                ("no",  "否", "xmark", []),
            ]
        case .approveCancel:
            return [
                ("approve", "批准", "hand.thumbsup.fill", []),
                ("cancel",  "取消", "xmark.circle", [.destructive]),
            ]
        case .chooseAB:
            return [
                ("option_a", "选项 A", "a.circle.fill", []),
                ("option_b", "选项 B", "b.circle.fill", []),
            ]
        case .agreeDecline:
            return [
                ("agree",   "同意", "hand.thumbsup", []),
                ("decline", "婉拒", "hand.thumbsdown", []),
            ]
        case .remindLaterSkip:
            return [
                ("remind_later", "稍后提醒", "bell.badge", []),
                ("skip",         "跳过",     "forward.fill", []),
            ]
        case .actionDismiss:
            return [
                ("action",  "执行", "bolt.fill", []),
                ("dismiss", "忽略", "xmark", []),
            ]
        case .feedback:
            return [
                ("helpful",     "有帮助", "hand.thumbsup.fill", []),
                ("not_helpful", "无帮助", "hand.thumbsdown.fill", []),
            ]
        case .permissionGate:
            // 4 buttons in user-friendly order. iOS shows them in the order
            // declared. "allow_once" first as the default (Return key on
            // tvOS / safe choice on iPhone Settings flow); "deny" last as
            // the destructive option.
            return [
                ("allow_once",    "本次同意",   "checkmark", []),
                ("allow_session", "本会话同意", "checkmark.circle", []),
                ("allow_always",  "永久同意",   "checkmark.shield.fill", []),
                ("deny",          "拒绝",       "xmark",     [.destructive]),
            ]
        }
    }
}

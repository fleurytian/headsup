import Foundation
import Network
import UIKit
import UserNotifications

/// Single source of truth for "can we receive pushes right now?" UI banners.
///
/// Tracks two things HeadsUp needs continuously:
///   - notification authorization status (the user can revoke it in iOS Settings)
///   - network reachability (we can't pull bindings/history without it)
///
/// Both surface as `Issue` cases so HomeView can show one banner per active
/// problem, in priority order, without each view re-querying every system API.
@MainActor
final class StatusMonitor: ObservableObject {
    static let shared = StatusMonitor()

    enum Issue: Hashable {
        /// User has not granted notification permission, or has revoked it.
        case notificationsDenied
        /// User hasn't been asked yet (fresh install).
        case notificationsNotDetermined
        /// Device has no usable network path.
        case offline
        /// Cellular data is restricted for this app specifically.
        case cellularRestricted

        var isCritical: Bool {
            switch self {
            case .notificationsDenied, .offline: return true
            default: return false
            }
        }
    }

    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isOnline: Bool = true
    @Published private(set) var isCellularRestricted: Bool = false

    /// Active issues in priority order. Empty array = everything's fine.
    var activeIssues: [Issue] {
        var issues: [Issue] = []
        if !isOnline { issues.append(.offline) }
        switch notificationStatus {
        case .denied: issues.append(.notificationsDenied)
        case .notDetermined: issues.append(.notificationsNotDetermined)
        default: break
        }
        if isCellularRestricted && !isOnline {
            issues.append(.cellularRestricted)
        }
        return issues
    }

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "md.headsup.app.status-monitor")

    private init() {
        startNetworkMonitor()
        Task { await refreshNotificationStatus() }
        // Re-check whenever the app comes to the foreground — user might have
        // toggled iOS Settings while we were backgrounded.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refreshNotificationStatus() }
        }
    }

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOnline = path.status == .satisfied
                self?.isCellularRestricted = path.isExpensive && path.status != .satisfied
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func refreshNotificationStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        self.notificationStatus = s.authorizationStatus
    }
}


import Foundation

/// Cross-process snapshot of recently-arrived pushes — written by the
/// Notification Service Extension, read by the main app + (future) Widget.
///
/// Why a plist (UserDefaults) instead of a real DB: the extension runs in a
/// separate sandbox and shares only the App Group container. SQLite over a
/// shared container famously crashes with 0xdead10cc (Bark hit this; Apple's
/// own SwiftData docs warn against it). A small plist of the last ~30
/// messages is more than enough to back the offline history merge + lock
/// screen widget. Big content stays in the backend's `/v1/app/history`.
///
/// **App Group**: `group.md.headsup`. The container only exists if both
/// the host app and the NSE have the entitlement and the App Group is
/// registered in the developer account. If neither is set up,
/// `SharedMessageStore.shared` becomes a no-op — every method returns nil
/// or empty, and pushes still work via the network path (just without
/// offline pre-population).
public struct SharedMessageSnapshot: Codable, Equatable {
    public let messageId: String
    public let agentId: String?
    public let agentName: String?
    public let agentAvatarUrl: String?
    public let title: String
    public let body: String
    public let categoryId: String?
    public let receivedAt: Date

    public init(messageId: String, agentId: String?, agentName: String?,
                agentAvatarUrl: String?, title: String, body: String,
                categoryId: String?, receivedAt: Date) {
        self.messageId = messageId
        self.agentId = agentId
        self.agentName = agentName
        self.agentAvatarUrl = agentAvatarUrl
        self.title = title
        self.body = body
        self.categoryId = categoryId
        self.receivedAt = receivedAt
    }
}

public final class SharedMessageStore {
    public static let shared = SharedMessageStore()

    /// Bump if the JSON shape changes — older entries get dropped on read
    /// rather than misdecoded.
    private static let schemaVersion = 1
    private static let appGroupId = "group.md.headsup"
    private static let snapshotsKey = "headsup.shared.snapshots.v\(schemaVersion)"
    /// Keep the rolling window short — the host app fetches /history on
    /// foreground anyway. The shared store is just a "last few since the
    /// app died" buffer.
    private static let maxRetained = 30

    private let defaults: UserDefaults?

    private init() {
        // If the App Group isn't actually configured (e.g. dev build before
        // entitlement grants), `init(suiteName:)` returns nil. We accept
        // that — every method becomes a no-op, callers don't need to branch.
        self.defaults = UserDefaults(suiteName: Self.appGroupId)
    }

    public var isAvailable: Bool { defaults != nil }

    public func append(_ snap: SharedMessageSnapshot) {
        guard let defaults else { return }
        var current = readAll()
        // Dedupe by message_id — NSE re-runs sometimes if the host app
        // receives the same notification through multiple paths.
        current.removeAll { $0.messageId == snap.messageId }
        current.append(snap)
        // Keep most recent N — sort then trim.
        current.sort { $0.receivedAt > $1.receivedAt }
        if current.count > Self.maxRetained {
            current = Array(current.prefix(Self.maxRetained))
        }
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: Self.snapshotsKey)
        }
    }

    public func readAll() -> [SharedMessageSnapshot] {
        guard let defaults,
              let data = defaults.data(forKey: Self.snapshotsKey) else { return [] }
        return (try? JSONDecoder().decode([SharedMessageSnapshot].self, from: data)) ?? []
    }

    /// Clear messages older than `cutoff`. The host app calls this once it
    /// has merged the shared snapshots into its persistent history, so the
    /// next NSE-only window starts fresh.
    public func pruneBefore(_ cutoff: Date) {
        guard let defaults else { return }
        let kept = readAll().filter { $0.receivedAt >= cutoff }
        if let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: Self.snapshotsKey)
        }
    }
}

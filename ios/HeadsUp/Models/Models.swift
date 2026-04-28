import Foundation

// ── User session (stored in Keychain ideally; UserDefaults for MVP) ───────────

struct UserSession: Codable {
    let userKey: String
    let sessionToken: String
    let appleUserId: String
}

// ── Agent binding (shown in app) ──────────────────────────────────────────────

struct AgentBinding: Codable, Identifiable {
    let agentId: String
    let agentName: String
    let boundAt: Date

    var id: String { agentId }

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case agentName = "agent_name"
        case boundAt = "bound_at"
    }
}

// ── Sign in with Apple request/response ──────────────────────────────────────

struct AppleSignInRequest: Codable {
    let identityToken: String
    let authorizationCode: String?
    let email: String?
    let fullName: String?
    let apnsDeviceToken: String?

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
        case email
        case fullName = "full_name"
        case apnsDeviceToken = "apns_device_token"
    }
}

struct AppleSignInResponse: Codable {
    let userKey: String
    let sessionToken: String
    let appleUserId: String

    enum CodingKeys: String, CodingKey {
        case userKey = "user_key"
        case sessionToken = "session_token"
        case appleUserId = "apple_user_id"
    }
}

// ── Device token registration ────────────────────────────────────────────────

struct DeviceTokenRequest: Codable {
    let apnsDeviceToken: String

    enum CodingKeys: String, CodingKey {
        case apnsDeviceToken = "apns_device_token"
    }
}

struct DeviceTokenResponse: Codable {
    let userKey: String

    enum CodingKeys: String, CodingKey {
        case userKey = "user_key"
    }
}

// ── Authorization confirm ────────────────────────────────────────────────────

struct AuthConfirmRequest: Codable {
    let token: String
    let userKey: String

    enum CodingKeys: String, CodingKey {
        case token
        case userKey = "user_key"
    }
}

struct AuthConfirmResponse: Codable {
    let status: String
    let agentId: String

    enum CodingKeys: String, CodingKey {
        case status
        case agentId = "agent_id"
    }
}

// ── Action report (notification button tap) ──────────────────────────────────

struct ActionReportRequest: Codable {
    let messageId: String
    let buttonId: String
    let buttonLabel: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case buttonId = "button_id"
        case buttonLabel = "button_label"
    }
}

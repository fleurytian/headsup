import Foundation
import SwiftUI

/// Per-user, on-device overrides for an agent's display.
///
/// The backend stores the agent-published name + logo + accent — those are
/// what shows up by default. But the user might call their Hermes 'My
/// Hermes' or want a calmer color than the agent picked. We store those
/// preferences in UserDefaults keyed by agent_id; everything else (push
/// pipeline, history, server-side branding) remains canonical.
@MainActor
final class AgentOverrides: ObservableObject {
    static let shared = AgentOverrides()

    @Published private var nicknames: [String: String] = [:]
    @Published private var accents:   [String: String] = [:]

    private let nicknamesKey = "headsup.agent.nicknames"
    private let accentsKey   = "headsup.agent.accents"

    init() {
        if let data = UserDefaults.standard.dictionary(forKey: nicknamesKey) as? [String: String] {
            nicknames = data
        }
        if let data = UserDefaults.standard.dictionary(forKey: accentsKey) as? [String: String] {
            accents = data
        }
    }

    func nickname(for agentId: String) -> String? { nicknames[agentId] }
    func accentHex(for agentId: String) -> String? { accents[agentId] }

    func setNickname(_ value: String?, for agentId: String) {
        if let v = value, !v.isEmpty {
            nicknames[agentId] = v
        } else {
            nicknames.removeValue(forKey: agentId)
        }
        UserDefaults.standard.set(nicknames, forKey: nicknamesKey)
    }

    func setAccentHex(_ value: String?, for agentId: String) {
        if let v = value, !v.isEmpty {
            accents[agentId] = v
        } else {
            accents.removeValue(forKey: agentId)
        }
        UserDefaults.standard.set(accents, forKey: accentsKey)
    }

    /// What to actually show as the agent's name — user override wins, else
    /// fall back to whatever the server provided.
    func displayName(for binding: AgentBinding) -> String {
        nickname(for: binding.agentId) ?? binding.agentName
    }

    /// The Color to use for accent — user override > server-provided > brand fallback.
    func displayAccent(for binding: AgentBinding) -> Color {
        if let hex = accentHex(for: binding.agentId), let c = Color(hex: hex) { return c }
        if let hex = binding.agentAccentColor, let c = Color(hex: hex) { return c }
        return AgentBranding.fallback(for: binding.agentName)
    }
}

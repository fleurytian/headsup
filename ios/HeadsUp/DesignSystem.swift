import SwiftUI

/// Editorial / 日系工艺 design language. Restrained, type-driven.
/// One accent. Strict 5-level type scale. No ornamental glyphs scattered around.
enum HU {

    /// "1.0.0 (1)" — bundle short version + build, read at runtime so we never
    /// have to remember to update a constant.
    static var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    // ── Palette (5 colors only) ──────────────────────────────────────────────
    enum C {
        static let bg     = Color(red: 0.973, green: 0.953, blue: 0.929)  // #F8F3ED 纸面
        static let card   = Color(red: 1.000, green: 0.992, blue: 0.973)  // #FFFDF8
        static let ink    = Color(red: 0.102, green: 0.094, blue: 0.094)  // #1A1818 deep ink
        static let muted  = Color(red: 0.514, green: 0.498, blue: 0.475)  // #837F79
        static let line   = Color(red: 0.898, green: 0.875, blue: 0.835)  // #E5DFD5 hairline
        static let accent = Color(red: 0.420, green: 0.376, blue: 0.659)  // #6B60A8 muted aubergine
    }

    // ── Type scale (5 sizes only) ────────────────────────────────────────────
    /// 28pt — splash / hero
    static func display(_ weight: Font.Weight = .heavy) -> Font {
        .system(size: 28, weight: weight, design: .rounded)
    }
    /// 18pt — section title
    static func title(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: 18, weight: weight, design: .rounded)
    }
    /// 15pt — body
    static func body(_ weight: Font.Weight = .regular) -> Font {
        .system(size: 15, weight: weight)
    }
    /// 13pt — secondary text
    static func small(_ weight: Font.Weight = .regular) -> Font {
        .system(size: 13, weight: weight)
    }
    /// 10pt — eyebrow / mono label, used wide-tracked uppercase
    static func eyebrow() -> Font {
        .system(size: 10, weight: .semibold, design: .monospaced)
    }
}

// ── View modifiers ──────────────────────────────────────────────────────────

struct HairlineCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(HU.C.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(HU.C.line, lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View { modifier(HairlineCard()) }
}

// ── Reusable atoms ──────────────────────────────────────────────────────────

/// Wide-tracked uppercase eyebrow label. Use sparingly — at most one per section.
struct Eyebrow: View {
    let text: String
    var color: Color = HU.C.muted
    var body: some View {
        Text(text.uppercased())
            .font(HU.eyebrow())
            .tracking(2.5)
            .foregroundStyle(color)
    }
}

/// Solid ink-filled primary button. Reads `isEnabled` from the environment so
/// `.disabled(true)` produces a properly-readable inactive state instead of a
/// washed-out one (opacity dims text and bg together — bad).
struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.callout) }
                Text(title).font(HU.title()).tracking(0.3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(HU.C.bg)
            .background(Capsule().fill(isEnabled ? HU.C.ink : HU.C.muted))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isEnabled)
    }
}

/// Hairline-bordered secondary button.
struct GhostButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.callout) }
                Text(title).font(HU.title()).tracking(0.3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(HU.C.ink)
            .background(
                Capsule().strokeBorder(HU.C.ink, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Single thin horizontal rule with optional centered word.
struct HairRule: View {
    var label: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(HU.C.line).frame(height: 1)
            if let label {
                Eyebrow(text: label)
                Rectangle().fill(HU.C.line).frame(height: 1)
            }
        }
    }
}

// ── Hex color parsing ───────────────────────────────────────────────────────

extension Color {
    /// "#RRGGBB" or "#RGB" or "RRGGBB". Returns nil for unparseable input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >>  8) & 0xFF) / 255.0,
            blue:  Double( v        & 0xFF) / 255.0
        )
    }
}

// ── Agent avatar + branding fallback ────────────────────────────────────────

/// Defaults for agents whose `accent_color` was never explicitly set.
/// Mirrors backend/services/agent_branding.py — keep both lists in sync if
/// you add a known name. iOS uses this only when the server-provided color is
/// missing (older detail-view payloads).
enum AgentBranding {
    private static let known: [(String, String)] = [
        ("claude code", "#D97757"),
        ("claude",      "#D97757"),
        ("codex",       "#10A37F"),
        ("hermes",      "#5B8DEE"),
        ("openclaw",    "#E8A33D"),
        ("gpt",         "#10A37F"),
        ("gemini",      "#4C8DF6"),
        ("kimi",        "#7C5CFC"),
    ]
    private static let palette: [Color] = [
        HU.C.accent,
        Color(hex: "#D97757")!,
        Color(hex: "#10A37F")!,
        Color(hex: "#5B8DEE")!,
        Color(hex: "#E8A33D")!,
        Color(hex: "#7C5CFC")!,
        Color(hex: "#C04E7E")!,
        Color(hex: "#3FA9A1")!,
    ]

    static func fallback(for name: String?) -> Color {
        guard let raw = name?.lowercased(), !raw.isEmpty else { return palette[0] }
        for (key, hex) in known {
            if raw.contains(key), let c = Color(hex: hex) { return c }
        }
        var hash = 5381
        for byte in raw.utf8 { hash = ((hash &<< 5) &+ hash) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }
}

/// Round avatar that prefers `logoUrl`, else falls back to a tinted circle
/// with the first letter of the agent's name.
struct AgentAvatar: View {
    let name: String
    let logoUrl: String?
    let accent: Color
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(accent.opacity(0.15))
            if let s = logoUrl, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        initial
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
    }

    private var initial: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
            .foregroundStyle(accent)
    }
}

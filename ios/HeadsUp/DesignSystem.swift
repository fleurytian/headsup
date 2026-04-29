import SwiftUI

/// Editorial / 日系工艺 design language. Restrained, type-driven.
/// One accent. Strict 5-level type scale. No ornamental glyphs scattered around.
enum HU {

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
            .foregroundStyle(isEnabled ? HU.C.bg : HU.C.muted)
            .background(Capsule().fill(isEnabled ? HU.C.ink : HU.C.line))
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

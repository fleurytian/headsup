import SwiftUI

/// 日系复古蒸汽波 design tokens — Showa-citypop / VHS aesthetics, kept restrained
/// so it doesn't fight functionality.
enum HU {

    // ── Palette ──────────────────────────────────────────────────────────────
    enum C {
        static let bg          = Color(red: 0.961, green: 0.937, blue: 0.906)  // #F5EFE7 米色暖底
        static let card        = Color(red: 0.996, green: 0.984, blue: 0.965)  // #FEFBF6 纸面白
        static let ink         = Color(red: 0.173, green: 0.157, blue: 0.263)  // #2C2843 深紫黑
        static let muted       = Color(red: 0.608, green: 0.588, blue: 0.690)  // #9B96B0
        static let lavender    = Color(red: 0.545, green: 0.435, blue: 0.788)  // #8B6FC9 柔紫
        static let pink        = Color(red: 1.000, green: 0.541, blue: 0.722)  // #FF8AB8 樱粉
        static let mint        = Color(red: 0.435, green: 0.788, blue: 0.753)  // #6FC9C0 薄荷青
        static let butter      = Color(red: 1.000, green: 0.890, blue: 0.624)  // #FFE39F 奶油黄
        static let dotted      = Color(red: 0.541, green: 0.502, blue: 0.604)  // #8A809A
    }

    // ── Gradients ────────────────────────────────────────────────────────────
    static let pastelGradient = LinearGradient(
        colors: [C.lavender, C.pink, C.mint],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let sunsetGradient = LinearGradient(
        colors: [C.pink.opacity(0.85), C.butter.opacity(0.9)],
        startPoint: .top, endPoint: .bottom
    )

    // ── Typography helpers ───────────────────────────────────────────────────
    /// Retro-monospace for tag-like labels and small caps
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Rounded for friendly headers
    static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // ── Decorative chars ─────────────────────────────────────────────────────
    static let bullet = "・"
    static let star   = "✦"
    static let mark   = "※"
    static let diamond = "◇"
}

// ── View modifiers ──────────────────────────────────────────────────────────

struct VaporCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(HU.C.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(HU.C.dotted.opacity(0.3),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .shadow(color: HU.C.lavender.opacity(0.06), radius: 12, x: 0, y: 6)
    }
}

struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()
            // Faint scanline texture (repeating soft horizontal lines)
            ScanlineOverlay().opacity(0.05).ignoresSafeArea()
            content
        }
    }
}

extension View {
    func vaporCard() -> some View { modifier(VaporCard()) }
    func screenBackground() -> some View { modifier(ScreenBackground()) }
}

// ── Decorative elements ─────────────────────────────────────────────────────

private struct ScanlineOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            for y in stride(from: 0.0, through: size.height, by: 3) {
                ctx.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                    with: .color(HU.C.ink)
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Retro section header — capitalized + wide letter-spacing + side bullets
struct RetroLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Text(HU.bullet).foregroundStyle(HU.C.muted.opacity(0.6))
            Text(text.uppercased())
                .font(HU.mono(11, weight: .semibold))
                .tracking(2.5)
                .foregroundStyle(HU.C.muted)
            Text(HU.bullet).foregroundStyle(HU.C.muted.opacity(0.6))
        }
    }
}

/// Pill-style button matching the aesthetic
struct VaporButton: View {
    let title: String
    var icon: String? = nil
    var primary: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title).font(HU.rounded(15, weight: .semibold)).tracking(0.5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(primary ? .white : HU.C.ink)
            .background(
                Group {
                    if primary {
                        Capsule().fill(HU.pastelGradient)
                    } else {
                        Capsule().fill(HU.C.card)
                            .overlay(
                                Capsule().strokeBorder(HU.C.dotted.opacity(0.4),
                                    style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                            )
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }
}

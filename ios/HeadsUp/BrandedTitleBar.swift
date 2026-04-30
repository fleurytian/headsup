import SwiftUI

/// Brand lockup used as the principal toolbar item on every top-level page.
/// Icon + "headsup.md" so screenshots are self-identifying when shared.
///
/// Usage:
///   .toolbar {
///       ToolbarItem(placement: .principal) { BrandedTitleBar() }
///   }
struct BrandedTitleBar: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("BrandLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text("headsup.md")
                .font(HU.title(.bold))
                .foregroundStyle(HU.C.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("headsup.md")
    }
}

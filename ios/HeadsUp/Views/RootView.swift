import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var deepLink: DeepLinkHandler

    var body: some View {
        Group {
            if auth.isSignedIn {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .sheet(item: $deepLink.pendingAuthorize) { pending in
            AuthorizeView(pending: pending)
                .interactiveDismissDisabled()
        }
    }
}

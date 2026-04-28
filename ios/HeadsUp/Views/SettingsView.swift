import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var push: PushService
    @State private var copied = false

    var body: some View {
        Form {
            Section("Account") {
                if let session = auth.session {
                    HStack {
                        Text("User Key")
                        Spacer()
                        Text(session.userKey)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        UIPasteboard.general.string = session.userKey
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy User Key", systemImage: "doc.on.doc")
                    }
                }
            }

            Section("Notifications") {
                HStack {
                    Text("Permission")
                    Spacer()
                    Text(push.permissionGranted ? "Granted" : "Not granted")
                        .foregroundStyle(push.permissionGranted ? .green : .secondary)
                }
                if let token = push.deviceTokenString {
                    HStack {
                        Text("Device Token")
                        Spacer()
                        Text(token.prefix(8) + "…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    auth.signOut()
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

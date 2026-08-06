import BeckitKit
import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library

    var body: some View {
        TabView {
            AccountSettings()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 460)
    }
}

private struct AccountSettings: View {
    @Environment(Library.self) private var library

    var body: some View {
        Form {
            if let account = library.account {
                LabeledContent("Signed in as", value: account.login)
                Section {
                    Button("Sign Out", role: .destructive) {
                        Task { await library.signOut() }
                    }
                } footer: {
                    Text("""
                        Your GitHub token is stored in the macOS keychain, not \
                        in a settings file.
                        """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                SignInView()
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

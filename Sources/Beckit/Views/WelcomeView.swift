import BeckitGit
import BeckitKit
import SwiftUI

/// First run, and the screen you come back to between books.
struct WelcomeView: View {
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 0) {
            introduction
            Divider()
            sidebar
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "book.closed")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)

            Text("Beckit")
                .font(.system(size: 34, weight: .semibold, design: .serif))

            Text("Write a book. Keep every version. Sync it to GitHub.")
                .font(.title3)
                .foregroundStyle(.secondary)

            Spacer()

            if let account = library.account {
                Label("Signed in as \(account.login)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(36)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Opening a book never requires GitHub. Beckit 3.x demanded a
            // sign-in before it would show you anything, which meant no
            // offline first run and no way to try it at all without an
            // account. Sync is a feature of a book, not a gate in front of one.
            Button {
                library.promptToOpenBook()
            } label: {
                Label("Open or Create a Book…", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)

            if !library.isSignedIn {
                Divider()
                Text("Connect GitHub to sync and back up your work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SignInView()
            }

            if !library.recentBooks.isEmpty {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(library.recentBooks, id: \.self) { url in
                    Button {
                        library.open(url)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(url.deletingLastPathComponent().path(percentEncoded: false))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.accessoryBar)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 320)
        .background(.quaternary.opacity(0.25))
    }
}

/// GitHub device flow. The writer sees a short code, types it into their
/// browser, and the app notices when they are done.
struct SignInView: View {
    @Environment(Library.self) private var library

    @State private var device: GitHubClient.DeviceCode?
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let device {
                Text("Enter this code on GitHub")
                    .font(.callout.weight(.medium))

                HStack {
                    Text(device.userCode)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(device.userCode, forType: .string)
                    } label: {
                        Image(systemName: "document.on.document")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy code")
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))

                Link("Open github.com/login/device", destination: device.verificationURI)

                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to authorise…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(action: start) {
                    Label("Sign in with GitHub", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.large)
                .disabled(isWorking)
            }

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func start() {
        isWorking = true
        failure = nil

        Task {
            defer { isWorking = false }
            do {
                let client = GitHubClient()
                let device = try await client.requestDeviceCode()
                self.device = device

                // Open the browser for them; the code is on screen either way.
                NSWorkspace.shared.open(device.verificationURI)

                let token = try await client.pollForToken(device)
                try await Credentials.shared.set(token)
                library.signedIn(as: try await client.account(token: token))
                self.device = nil
            } catch {
                self.device = nil
                failure = error.localizedDescription
            }
        }
    }
}

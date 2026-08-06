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
        VStack(alignment: .leading, spacing: 16) {
            Spacer()

            AppMark(size: 76)

            VStack(alignment: .leading, spacing: 8) {
                Text("Beckit")
                    .font(.system(size: 40, weight: .semibold, design: .serif))

                Text("Write a book. Keep every version. Sync it to GitHub.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if let account = library.account {
                Label("Signed in as \(account.login)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(40)
        // Lets the wash behind the mark run under the window's translucent
        // chrome instead of stopping at the content edge.
        .backgroundExtensionEffect()
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
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            if !library.isSignedIn {
                Text("Connect GitHub to sync and back up your work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SignInView()
            }

            if !library.recentBooks.isEmpty {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

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
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.accessoryBar)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 330)
        // No opaque panel colour. The pane is a glass layer over the wash on
        // the left, so it takes its tone from what is behind it — which is the
        // point of the material, and something a flat fill would defeat.
        .glassEffect(
            .regular,
            in: ConcentricRectangle(uniformLeadingCorners: .concentric))
        .padding(.vertical, 12)
        .padding(.trailing, 12)
    }
}

/// The app mark, drawn rather than loaded, so it stays crisp at any size and
/// there is no second copy of the artwork to keep in step with the icon.
struct AppMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.38, green: 0.43, blue: 1.00),
                            Color(red: 0.11, green: 0.12, blue: 0.42),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))

            // The same receding stack as the app icon: a bookmark, and the
            // versions behind it.
            ZStack {
                bookmark.opacity(0.24).offset(x: -size * 0.082, y: -size * 0.070)
                bookmark.opacity(0.50).offset(x: -size * 0.041, y: -size * 0.035)
                bookmark
            }
            .offset(x: size * 0.02, y: size * 0.012)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.22), radius: size * 0.06, y: size * 0.03)
    }

    private var bookmark: some View {
        BookmarkShape()
            .fill(Color(red: 1.0, green: 0.97, blue: 0.92))
            .frame(width: size * 0.25, height: size * 0.45)
    }
}

/// A bookmark ribbon: rounded shoulders, symmetric notch.
struct BookmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulder = rect.width * 0.115
        let notch = rect.height * 0.185

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + shoulder),
            control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - notch))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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
                .padding(12)
                .glassEffect(
                    .regular,
                    in: ConcentricRectangle(corners: .concentric, isUniform: true))

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
                .buttonStyle(.glass)
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

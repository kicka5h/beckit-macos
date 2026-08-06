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
/// there is no image asset to keep in step with the window.
///
/// The geometry mirrors `Scripts/make-icon.swift` — same 1024-unit design
/// space, same numbers — so the mark in the window and the icon in the Dock are
/// the same drawing. The icon generator is a standalone script and cannot
/// import this file, so the two are kept in step by hand; changing one means
/// changing the other.
struct AppMark: View {
    var size: CGFloat

    static let ink = Color(red: 0.839, green: 0.278, blue: 0.608)
    static let groundTop = Color(red: 1.000, green: 0.980, blue: 0.990)
    static let groundBottom = Color(red: 0.988, green: 0.914, blue: 0.953)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Self.groundTop, Self.groundBottom],
                    startPoint: .top, endPoint: .bottom))

            BookAndPencil(includeGraphite: size >= 64)
                .stroke(Self.ink, style: StrokeStyle(
                    lineWidth: size * 46 / 1024, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.10), radius: size * 0.05, y: size * 0.02)
    }
}

/// An open book whose spine is a pencil.
///
/// Drawn in the same 1024-unit space as the icon and scaled to `rect`. SwiftUI
/// shapes already run top-left down, which is the space the geometry is written
/// in, so unlike the Core Graphics version there is no flip here.
struct BookAndPencil: Shape {
    var includeGraphite = true

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 1024
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + (y + 15) * unit)
        }

        let outerLeft: CGFloat = 210, outerRight: CGFloat = 814, centerX: CGFloat = 512
        let coverTop: CGFloat = 283, coverBottom: CGFloat = 645
        let pencilLeft: CGFloat = 467, pencilRight: CGFloat = 557
        let pencilTop: CGFloat = 343, shoulder: CGFloat = 568, tip: CGFloat = 673
        let graphite: CGFloat = 608

        var path = Path()

        // Covers and base as one line: down the left, across the bottom, up the
        // right. The bottom's controls are inset from the corners so the sides
        // do not bow outward.
        path.move(to: at(outerLeft, coverTop))
        path.addLine(to: at(outerLeft, coverBottom))
        path.addCurve(
            to: at(outerRight, coverBottom),
            control1: at(outerLeft + 74, 754),
            control2: at(outerRight - 74, 754))
        path.addLine(to: at(outerRight, coverTop))

        // Each page's top edge flows into that side of the pencil and down to
        // the point — page and pencil share one contour, which is the idea of
        // the mark.
        for mirrored in [false, true] {
            func x(_ value: CGFloat) -> CGFloat {
                mirrored ? 2 * centerX - value : value
            }
            path.move(to: at(x(outerLeft), coverTop))
            path.addCurve(
                to: at(x(pencilLeft), pencilTop),
                control1: at(x(272), 251),
                control2: at(x(382), 305))
            path.addLine(to: at(x(pencilLeft), shoulder))
            path.addLine(to: at(centerX, tip))
        }

        // The line across the sharpened end. Left off at small sizes, where the
        // taper is a few pixels wide and this becomes a blot.
        if includeGraphite {
            let inset = (graphite - shoulder) / (tip - shoulder) * (centerX - pencilLeft)
            path.move(to: at(pencilLeft + inset, graphite))
            path.addLine(to: at(pencilRight - inset, graphite))
        }

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

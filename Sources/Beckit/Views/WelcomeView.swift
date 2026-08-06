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

    /// Mirrors `strokePixels(for:)` in the icon generator: the mark is drawn at
    /// 34/1024 of its box, floored below 192pt so a small mark thickens instead
    /// of fading into antialiased grey.
    static func strokeWidth(for size: CGFloat) -> CGFloat {
        let natural = 34 / 1024 * size
        let minimum: CGFloat = switch size {
        case ..<24: 1.6
        case ..<48: 2.2
        case ..<96: 3.0
        case ..<192: 4.2
        default: 0
        }
        return max(natural, minimum)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Self.groundTop, Self.groundBottom],
                    startPoint: .top, endPoint: .bottom))

            BookAndPencil(includeGraphite: size >= 64, includePageStack: size >= 32)
                .stroke(Self.ink, style: StrokeStyle(
                    lineWidth: Self.strokeWidth(for: size),
                    lineCap: .round, lineJoin: .round))
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
    var includePageStack = true

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 1024
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + (y + 25) * unit)
        }

        let outerLeft: CGFloat = 205, centerX: CGFloat = 512
        let topOuter: CGFloat = 300, bottomOuter: CGFloat = 570
        let pageLineOuter: CGFloat = 498, pageLineInner: CGFloat = 512
        let pencilLeft: CGFloat = 452, pencilRight: CGFloat = 572
        let pencilTop: CGFloat = 366, shoulder: CGFloat = 578, tip: CGFloat = 700
        let graphite: CGFloat = 612

        var path = Path()

        // Two mirrored halves, each its own page block. A single silhouette
        // running under the spine would read as a container rather than as a
        // book with two sides.
        for mirrored in [false, true] {
            func x(_ value: CGFloat) -> CGFloat {
                mirrored ? 2 * centerX - value : value
            }
            /// A curve from the fore edge in to the spine, bellying by `sag`.
            /// Shared by every horizontal so they stay parallel.
            func leaf(from outer: CGFloat, to inner: CGFloat, sag: CGFloat) {
                path.move(to: at(x(outerLeft), outer))
                path.addCurve(
                    to: at(x(pencilLeft), inner),
                    control1: at(x(outerLeft + 96), outer + sag),
                    control2: at(x(pencilLeft - 104), inner + sag * 0.7))
            }

            // Page surface, flowing into that side of the pencil and down to
            // the point — one unbroken contour.
            leaf(from: topOuter, to: pencilTop, sag: -6)
            path.addLine(to: at(x(pencilLeft), shoulder))
            path.addLine(to: at(centerX, tip))

            // Fore edge, then the block's bottom, closing onto the pencil at
            // the shoulder so the point protrudes below the book.
            path.move(to: at(x(outerLeft), topOuter))
            path.addLine(to: at(x(outerLeft), bottomOuter))
            leaf(from: bottomOuter, to: shoulder, sag: 20)

            // The page stack: one sheet lifted off the block. Dropped at small
            // sizes, where it merges with the other two horizontals.
            if includePageStack {
                leaf(from: pageLineOuter, to: pageLineInner, sag: 20)
            }
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

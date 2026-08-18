import AppKit
import BeckitGit
import BeckitKit
import Foundation
import Observation

/// App-level state that outlives any one book: which book is open, who is
/// signed in, and the sheets the window is presenting.
@MainActor
@Observable
final class Library {
    private(set) var workspace: Workspace?
    private(set) var account: GitHubClient.Account?
    private(set) var recentBooks: [URL] = []

    var isExporting = false
    var pendingImport: PendingImport?
    var error: PresentedError?

    private let defaults = UserDefaults.standard
    private static let recentsKey = "recentBooks"

    struct PendingImport: Identifiable {
        let id = UUID()
        var root: URL
        var plan: LegacyImporter.Plan
    }

    struct PresentedError: Identifiable {
        let id = UUID()
        var message: String
    }

    init() {
        recentBooks = (defaults.array(forKey: Self.recentsKey) as? [String] ?? [])
            .map { URL(filePath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    var isSignedIn: Bool { account != nil }

    // MARK: - Opening books

    /// Opens a directory as a book, offering to convert it first when it turns
    /// out to be a Beckit 3.x repository.
    func open(_ root: URL) {
        if LegacyImporter.isLegacyRepository(at: root) {
            do {
                pendingImport = PendingImport(root: root, plan: try LegacyImporter.plan(at: root))
            } catch {
                present(error)
            }
            return
        }

        do {
            let store = BookStore(root: root)
            if !store.hasManifest {
                // A folder with no book in it becomes one. Choosing a directory
                // is the only "new book" gesture there needs to be.
                try store.initializeBook(title: root.lastPathComponent)
                _ = try? SystemGitRepository.initialize(at: root)
            }

            let workspace = try Workspace.open(at: root)
            self.workspace = workspace
            remember(root)
            Task { await workspace.pull() }
        } catch {
            present(error)
        }
    }

    func promptToOpenBook() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Book"
        panel.message = "Choose the folder holding your book."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func close() {
        workspace = nil
    }

    /// The book a just-finished conversion produced, waiting for the import
    /// sheet to finish dismissing.
    private var convertedRoot: URL?

    /// Called by the import sheet once the conversion has succeeded. Only
    /// records the result; opening happens in `openConvertedBook`.
    func importDidFinish(at root: URL) {
        convertedRoot = root
        pendingImport = nil
    }

    /// Called from the sheet's `onDismiss`, once it has actually gone.
    ///
    /// Opening swaps the root view from the welcome screen to the writing
    /// window, which installs a window toolbar for the first time. Doing that
    /// in the same update that dismisses the sheet means tearing down one view
    /// tree and standing up another mid-transition, and SwiftUI's toolbar
    /// machinery is where that bill comes due.
    func openConvertedBook() {
        guard let root = convertedRoot else { return }
        convertedRoot = nil
        open(root)
    }

    private func remember(_ root: URL) {
        recentBooks.removeAll { $0 == root }
        recentBooks.insert(root, at: 0)
        recentBooks = Array(recentBooks.prefix(8))
        defaults.set(recentBooks.map { $0.path(percentEncoded: false) }, forKey: Self.recentsKey)
    }

    // MARK: - Account

    func restoreSession() async {
        guard let token = await Credentials.shared.token() else { return }
        account = try? await GitHubClient().account(token: token)
    }

    func signOut() async {
        try? await Credentials.shared.set(nil)
        account = nil
    }

    func signedIn(as account: GitHubClient.Account) {
        self.account = account
    }

    // MARK: - Errors

    func present(_ error: any Error) {
        self.error = PresentedError(message: error.localizedDescription)
    }
}

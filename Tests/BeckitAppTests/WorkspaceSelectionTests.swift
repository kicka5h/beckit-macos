import BeckitGit
import BeckitKit
import Foundation
import Testing
@testable import Beckit

/// Covers what happens when the writer picks a different section.
///
/// This is the bug that shipped: the sidebar bound its list straight to
/// `Workspace.selection`, so clicking a chapter wrote the stored property and
/// nothing else. The editor kept showing whichever section had been loaded at
/// open — for a converted book, the Dedication — and every other chapter looked
/// empty. Selection has to run through `select(_:)`, which is what loads the
/// text, and the tests below assert that from the outside.
@Suite("Workspace selection")
@MainActor
struct WorkspaceSelectionTests {

    /// A book on disk with three sections whose contents differ, plus a git
    /// stand-in so no repository is needed.
    private func makeWorkspace() throws -> (Workspace, [BookSection]) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "beckit-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = BookStore(root: root)
        var book = Book(title: "Test")
        let sections = [
            BookSection(kind: .frontMatter, title: "Dedication", fileName: "dedication.md"),
            BookSection(kind: .chapter, title: "", fileName: "chapter-1.md"),
            BookSection(kind: .chapter, title: "", fileName: "chapter-2.md"),
        ]
        book.sections = sections
        for section in sections {
            try store.write("contents of \(section.fileName)", to: section)
        }
        try store.save(book)

        return (Workspace(store: store, git: SilentGit(root: root), book: book), sections)
    }

    @Test("Opening a book loads the first section")
    func opensOnFirstSection() throws {
        let (workspace, sections) = try makeWorkspace()
        #expect(workspace.selection == sections[0].id)
        #expect(workspace.text == "contents of dedication.md")
    }

    @Test("Selecting a section loads that section's text")
    func selectLoadsText() throws {
        let (workspace, sections) = try makeWorkspace()

        workspace.select(sections[1].id)
        #expect(workspace.selection == sections[1].id)
        #expect(workspace.text == "contents of chapter-1.md")

        workspace.select(sections[2].id)
        #expect(workspace.text == "contents of chapter-2.md")
    }

    /// The regression test proper. The sidebar drives selection through this
    /// binding, so it has to do everything `select(_:)` does — writing the
    /// stored property alone leaves the editor on the previous section.
    @Test("Selecting through the list binding loads the text too")
    func selectionBindingLoadsText() throws {
        let (workspace, sections) = try makeWorkspace()

        workspace.selectionBinding.wrappedValue = sections[2].id

        #expect(workspace.selection == sections[2].id)
        #expect(workspace.text == "contents of chapter-2.md",
                "the binding wrote selection without loading the section")
    }

    @Test("Word count follows the selection")
    func wordCountFollowsSelection() throws {
        let (workspace, sections) = try makeWorkspace()
        workspace.select(sections[1].id)
        #expect(workspace.documentWordCount == WordCount.count(in: "contents of chapter-1.md"))
    }

    @Test("Switching away from an edited section saves it first")
    func savesBeforeSwitching() throws {
        let (workspace, sections) = try makeWorkspace()

        workspace.select(sections[1].id)
        workspace.textChanged("a rewritten chapter, considerably longer than before")
        #expect(workspace.isDirty)

        workspace.selectionBinding.wrappedValue = sections[2].id

        #expect(!workspace.isDirty)
        #expect(try workspace.store.read(sections[1])
            == "a rewritten chapter, considerably longer than before")
    }

    @Test("Selecting the section already open changes nothing")
    func reselectingIsANoOp() throws {
        let (workspace, sections) = try makeWorkspace()
        workspace.select(sections[1].id)
        workspace.textChanged("edited but not saved")

        workspace.select(sections[1].id)

        #expect(workspace.text == "edited but not saved")
    }
}

/// A `GitRepository` that does nothing, for tests about the model rather than
/// about git. Every operation succeeds and reports no history and no remote.
private struct SilentGit: GitRepository {
    let root: URL

    func remoteURL() throws -> URL { throw GitError.noRemote }
    func hasUncommittedChanges() throws -> Bool { false }
    func commit(message: String, paths: [String]) throws -> GitCommit? { nil }
    func pull(credentials: GitCredentials?) throws -> Bool { false }
    func push(credentials: GitCredentials?) throws { throw GitError.noRemote }
    func history(forPath path: String, limit: Int) throws -> [GitCommit] { [] }
    func contents(ofPath path: String, at commit: GitCommit.ID) throws -> String { "" }
    func createTag(named name: String, at commit: GitCommit.ID) throws {}
    func tags(withPrefix prefix: String) throws -> [(name: String, commit: GitCommit.ID)] { [] }
}

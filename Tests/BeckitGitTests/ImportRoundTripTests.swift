import BeckitKit
import Foundation
import Testing
@testable import BeckitGit

/// End-to-end cover for the path a real book takes: a Beckit 3.x repository is
/// converted, opened, edited, versioned, and then read back out of git history.
///
/// These run against a real git repository in a temporary directory rather than
/// a stub, because the thing worth proving is that the *actual* commands work
/// on the *actual* layout — the plan being correct in isolation says nothing
/// about whether the writer's book survives.
@Suite("Import round trip", .serialized)
struct ImportRoundTripTests {

    /// A Beckit 3.x book, committed, with two versions of its first chapter.
    private func makeLegacyRepository() throws -> (URL, SystemGitRepository) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "beckit-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func write(_ path: String, _ contents: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }

        try write("Chapters/Chapter 1/v1.0.0/v1.0.0.md", "# The Crossing\n\nfirst draft\n")
        try write("Chapters/Chapter 1/v1.1.0/v1.1.0.md", "# The Crossing\n\nsecond draft\n")
        try write("Chapters/Chapter 2 - The Ferry/v1.0.0/v1.0.0.md", "the ferry was late\n")
        try write("FrontMatter/Dedication/v1.0.0/v1.0.0.md", "For everyone.\n")

        let git = try SystemGitRepository.initialize(at: root)
        try configureIdentity(at: root)
        try git.commit(message: "Legacy book", paths: ["."])
        return (root, git)
    }

    /// Commits need an author; CI machines have no global git identity.
    private func configureIdentity(at root: URL) throws {
        for (key, value) in [("user.email", "test@beckit.invalid"), ("user.name", "Test")] {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/git")
            process.arguments = ["config", key, value]
            process.currentDirectoryURL = root
            try process.run()
            process.waitUntilExit()
        }
    }

    @Test("Converting a 3.x book collapses it and keeps every version in git")
    func fullConversion() throws {
        let (root, git) = try makeLegacyRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try LegacyImporter.plan(at: root)
        let book = LegacyImporter.book(for: plan)
        try LegacyImportRunner(root: root, git: git)
            .run(try LegacyImporter.steps(for: plan, book: book))

        let manager = FileManager.default

        // The old version folders are gone from the working tree...
        #expect(!manager.fileExists(
            atPath: root.appending(path: "Chapters/Chapter 1").path(percentEncoded: false)))

        // ...and each section is now one file.
        let store = BookStore(root: root)
        let reloaded = try store.loadBook()
        #expect(reloaded.sections.count == 3)

        let crossing = try #require(reloaded.sections.first { $0.kind == .chapter })
        #expect(try store.read(crossing).contains("second draft"))
        #expect(crossing.version == SemanticVersion(1, 1, 0))

        // The version that is no longer on disk is still readable from history.
        let history = try git.history(forPath: crossing.relativePath, limit: 50)
        #expect(history.count >= 2)

        // Read through the commit, not the current path: before the import that
        // prose lived at "Chapters/Chapter 1/v1.0.0/v1.0.0.md".
        let earliest = try #require(history.last)
        #expect(earliest.path != crossing.relativePath)
        #expect(try git.contents(of: earliest).contains("first draft"))
    }

    @Test("Saving a chapter records a version tag that history can read back")
    func versionTagging() throws {
        let (root, git) = try makeLegacyRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try LegacyImporter.plan(at: root)
        var book = LegacyImporter.book(for: plan)
        try LegacyImportRunner(root: root, git: git)
            .run(try LegacyImporter.steps(for: plan, book: book))

        let store = BookStore(root: root)
        book = try store.loadBook()
        var chapter = try #require(book.sections.first { $0.kind == .chapter })

        // Rewrite it substantially enough to earn a bump, the way a save would.
        let revised = "# The Crossing\n\n"
            + String(repeating: "She waited for Marlow by the door.\n\n", count: 20)
        let significance = try #require(
            ChangeClassifier.classify(from: try store.read(chapter), to: revised))

        chapter.version = chapter.version.bumped(significance)
        book[chapter.id] = chapter
        try store.write(revised, to: chapter)
        try store.save(book)

        let tag = "beckit/\(chapter.id.uuidString.lowercased())/\(chapter.version)"
        let commit = try #require(
            try git.commit(message: "save", paths: [chapter.relativePath, "book.json"]))
        try git.createTag(named: tag, at: commit.id)

        let tags = try git.tags(
            withPrefix: "beckit/\(chapter.id.uuidString.lowercased())/")
        #expect(tags.count == 1)
        #expect(tags.first?.name == tag)
        #expect(tags.first?.commit == commit.id)

        // And the tagged commit really holds the revised prose.
        #expect(try git.contents(ofPath: chapter.relativePath, at: commit.id)
            .contains("Marlow"))
    }

    @Test("A save with nothing changed does not create an empty commit")
    func noOpSaveIsNotACommit() throws {
        let (root, git) = try makeLegacyRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = try git.history(forPath: ".", limit: 50).count
        #expect(try git.commit(message: "nothing", paths: ["."]) == nil)
        #expect(try git.history(forPath: ".", limit: 50).count == before)
    }

    @Test("A book with no remote reports that rather than failing")
    func localOnlyBook() throws {
        let (root, git) = try makeLegacyRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: (any Error).self) { try git.remoteURL() }
        // Pull is a no-op rather than an error the writer has to dismiss.
        #expect(try git.pull(credentials: nil) == false)
    }
}

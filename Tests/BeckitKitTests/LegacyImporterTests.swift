import Foundation
import Testing
@testable import BeckitKit

/// The importer runs once per book and is destructive to the old layout, so it
/// gets tested against a real directory tree rather than mocks.
@Suite("Legacy import")
struct LegacyImporterTests {

    /// Builds a Beckit 3.x repository in a temporary directory.
    private func makeLegacyBook() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "beckit-import-\(UUID().uuidString)")

        func write(_ path: String, _ contents: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }

        try write("Chapters/Chapter 1/v1.0.0/v1.0.0.md", "# Opening\n\nfirst draft")
        try write("Chapters/Chapter 1/v1.1.0/v1.1.0.md", "# Opening\n\nsecond draft")
        try write("Chapters/Chapter 2 - The Ferry/v1.0.0/v1.0.0.md", "the ferry was late")
        // Out of numeric order on disk, to prove ordering is by number not name.
        try write("Chapters/Chapter 10/v1.0.0/v1.0.0.md", "much later")
        try write("FrontMatter/Dedication/v1.0.0/v1.0.0.md", "For everyone.")
        try write("BackMatter/Epilogue/v2.0.0/v2.0.0.md", "And then.")

        return root
    }

    @Test("Recognises the old layout")
    func detection() throws {
        let root = try makeLegacyBook()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(LegacyImporter.isLegacyRepository(at: root))
    }

    @Test("A book already converted is left alone")
    func doesNotReimport() throws {
        let root = try makeLegacyBook()
        defer { try? FileManager.default.removeItem(at: root) }

        try BookStore(root: root).save(Book(title: "Already Converted"))
        #expect(!LegacyImporter.isLegacyRepository(at: root))
    }

    @Test("Sections come out in reading order")
    func readingOrder() throws {
        let root = try makeLegacyBook()
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try LegacyImporter.plan(at: root)
        #expect(plan.sections.map(\.kind) == [
            .frontMatter, .chapter, .chapter, .chapter, .backMatter,
        ])
        // Chapter 10 sorts after Chapter 2, which a plain name sort would not do.
        #expect(plan.sections.filter { $0.kind == .chapter }.map(\.title)
            == ["", "The Ferry", ""])
    }

    @Test("Every version becomes a commit, and the last one sets the version")
    func versionsBecomeCommits() throws {
        let root = try makeLegacyBook()
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try LegacyImporter.plan(at: root)
        #expect(plan.revisionCount == 6)

        let opening = try #require(plan.sections.first { $0.destination.contains("Chapters/") })
        #expect(opening.revisions.map(\.version) == [SemanticVersion(1, 0, 0),
                                                     SemanticVersion(1, 1, 0)])
        #expect(opening.finalVersion == SemanticVersion(1, 1, 0))

        let epilogue = try #require(plan.sections.first { $0.title == "Epilogue" })
        #expect(epilogue.finalVersion == SemanticVersion(2, 0, 0))
    }

    @Test("Each pass writes one commit, and the last one deletes the old folders")
    func stepsAreCommitSized() throws {
        let root = try makeLegacyBook()
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try LegacyImporter.plan(at: root)
        let steps = try LegacyImporter.steps(for: plan, book: LegacyImporter.book(for: plan))

        // Deepest section has two versions, so two passes plus the final step.
        #expect(steps.count == 3)
        #expect(steps[0].copies.count == 5)  // every section's v1 except the v2 epilogue
        #expect(steps[1].copies.count == 1)  // only Chapter 1 has a second version
        #expect(steps.last?.writes.keys.contains("book.json") == true)
        #expect(steps.last?.deletions.count == 5)
    }

    @Test("Destination file names are unique and slugged")
    func fileNaming() throws {
        let root = try makeLegacyBook()
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try LegacyImporter.plan(at: root)
        let destinations = plan.sections.map(\.destination)

        #expect(Set(destinations).count == destinations.count)
        #expect(destinations.contains("Chapters/the-ferry.md"))
        #expect(destinations.contains("FrontMatter/dedication.md"))
        #expect(destinations.allSatisfy { !$0.contains(" ") })
    }

    @Test("Chapter directory names are read correctly", arguments: [
        ("Chapter 1", 1, ""),
        ("Chapter 12", 12, ""),
        ("chapter 3", 3, ""),
        ("Chapter 7 - The Ferry", 7, "The Ferry"),
        ("Chapter 4: Nightfall", 4, "Nightfall"),
    ])
    func chapterNaming(name: String, number: Int, title: String) {
        #expect(LegacyImporter.chapterNumber(from: name) == number)
        #expect(LegacyImporter.chapterTitle(from: name) == title)
    }

    @Test("A folder that is not a numbered chapter keeps its whole name")
    func unnumberedDirectory() {
        #expect(LegacyImporter.chapterNumber(from: "Interlude") == nil)
        #expect(LegacyImporter.chapterTitle(from: "Interlude") == "Interlude")
    }
}

@Suite("Word count")
struct WordCountTests {

    @Test("Markdown punctuation does not count as words")
    func ignoresSyntax() {
        // "Chapter", "One", "item" — the #, --- and * contribute nothing.
        #expect(WordCount.count(in: "# Chapter One\n\n---\n\n* item") == 3)
    }

    @Test("Contractions and hyphenated words count once")
    func joiners() {
        #expect(WordCount.count(in: "don't half-empty well-worn it's") == 4)
        #expect(WordCount.count(in: "don\u{2019}t") == 1)
    }

    @Test("A trailing apostrophe does not extend the word")
    func trailingJoiner() {
        #expect(WordCount.count(in: "the horses' reins") == 3)
    }

    @Test("Empty text counts nothing")
    func empty() {
        #expect(WordCount.count(in: "") == 0)
        #expect(WordCount.count(in: "\n\n   \n") == 0)
    }
}

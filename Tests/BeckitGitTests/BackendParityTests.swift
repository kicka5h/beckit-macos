import BeckitKit
import Foundation
import Testing
@testable import BeckitGit

/// Runs one suite against both `GitRepository` implementations.
///
/// The point is parity. `SystemGitRepository` is the reference — it is git
/// itself — and `LibGit2Repository` is the one that ships, because bundling
/// libgit2 is what keeps a clean Mac from being asked to install the Xcode
/// command line tools on first sync. Anything the two disagree about is a bug
/// in the new one, so every test here runs twice and the parameter says which
/// backend is on the stand.
@Suite("Git backend parity", .serialized)
struct BackendParityTests {

    enum Backend: String, CaseIterable, CustomStringConvertible {
        case process, libgit2
        var description: String { rawValue }
    }

    /// A fresh repository with a committed file, plus a helper to write more.
    private func makeRepository(_ backend: Backend) throws -> (any GitRepository, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "beckit-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let repository: any GitRepository = switch backend {
        case .process: try SystemGitRepository.initialize(at: root)
        case .libgit2: try LibGit2Repository.initialize(at: root)
        }
        try configureIdentity(at: root)
        return (repository, root)
    }

    /// Commits need an author, and a CI runner has no global git identity.
    /// Written into the repository's own config so both backends see it.
    private func configureIdentity(at root: URL) throws {
        let config = root.appending(path: ".git/config")
        var text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        text += "\n[user]\n\tname = Test\n\temail = test@beckit.invalid\n"
        try text.write(to: config, atomically: true, encoding: .utf8)
    }

    private func write(_ contents: String, to path: String, in root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    // MARK: - Tests

    @Test("A fresh repository is clean and has no remote", arguments: Backend.allCases)
    func freshRepository(backend: Backend) throws {
        let (git, root) = try makeRepository(backend)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try !git.hasUncommittedChanges())
        #expect(throws: (any Error).self) { try git.remoteURL() }
        // No remote is a supported state, not a failure.
        #expect(try git.pull(credentials: nil) == false)
    }

    @Test("Committing a file records it", arguments: Backend.allCases)
    func commitRecordsAFile(backend: Backend) throws {
        let (git, root) = try makeRepository(backend)
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Chapter 1\n\nthe tide came in", to: "Chapters/chapter-1.md", in: root)
        let commit = try #require(
            try git.commit(message: "Add chapter 1", paths: ["Chapters/chapter-1.md"]))

        #expect(commit.summary == "Add chapter 1")
        #expect(commit.id.count == 40)
        #expect(!commit.authorName.isEmpty)
        #expect(try !git.hasUncommittedChanges())
    }

    @Test("An empty save is not a commit", arguments: Backend.allCases)
    func emptySaveIsNotACommit(backend: Backend) throws {
        let (git, root) = try makeRepository(backend)
        defer { try? FileManager.default.removeItem(at: root) }

        try write("first", to: "Chapters/chapter-1.md", in: root)
        _ = try git.commit(message: "first", paths: ["."])

        #expect(try git.commit(message: "nothing changed", paths: ["."]) == nil)
    }

    @Test("An edit is uncommitted until it is committed", arguments: Backend.allCases)
    func dirtyDetection(backend: Backend) throws {
        let (git, root) = try makeRepository(backend)
        defer { try? FileManager.default.removeItem(at: root) }

        try write("first", to: "Chapters/chapter-1.md", in: root)
        _ = try git.commit(message: "first", paths: ["."])
        #expect(try !git.hasUncommittedChanges())

        try write("second", to: "Chapters/chapter-1.md", in: root)
        #expect(try git.hasUncommittedChanges())
    }

    @Test("History reads back newest first", arguments: Backend.allCases)
    func history(backend: Backend) throws {
        let (git, root) = try makeRepository(backend)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = "Chapters/chapter-1.md"
        for version in ["first draft", "second draft", "third draft"] {
            try write(version, to: path, in: root)
            _ = try git.commit(message: version, paths: [path])
        }

        let commits = try git.history(forPath: path, limit: 50)
        #expect(commits.count == 3)
        #expect(commits.first?.summary == "third draft")
        #expect(commits.last?.summary == "first draft")
    }

    @Test("A past version can be read out of history", arguments: Backend.allCases)
    func contentsAtACommit(backend: Backend) throws {
        let (git, root) = try makeRepository(backend)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = "Chapters/chapter-1.md"
        try write("first draft", to: path, in: root)
        _ = try git.commit(message: "first", paths: [path])
        try write("second draft", to: path, in: root)
        _ = try git.commit(message: "second", paths: [path])

        let commits = try git.history(forPath: path, limit: 50)
        let earliest = try #require(commits.last)
        #expect(try git.contents(of: earliest) == "first draft")
    }

    /// The case that matters for a converted book: the 3.x import renames every
    /// file, so history that stops at a rename shows nothing before the import.
    @Test("History follows a file across a rename", arguments: Backend.allCases)
    func historyFollowsRenames(backend: Backend) throws {
        let (git, root) = try makeRepository(backend)
        defer { try? FileManager.default.removeItem(at: root) }

        try write("the tide came in slowly and left again", to: "Chapters/old-name.md", in: root)
        _ = try git.commit(message: "before the rename", paths: ["."])

        try FileManager.default.moveItem(
            at: root.appending(path: "Chapters/old-name.md"),
            to: root.appending(path: "Chapters/new-name.md"))
        _ = try git.commit(message: "rename", paths: ["."])

        let commits = try git.history(forPath: "Chapters/new-name.md", limit: 50)
        #expect(commits.count == 2, "history stopped at the rename")

        // And the older version reads back through the name it had at the time.
        let earliest = try #require(commits.last)
        #expect(try git.contents(of: earliest).contains("the tide"))
    }

    @Test("Tags are namespaced and read back with their commit", arguments: Backend.allCases)
    func tagging(backend: Backend) throws {
        let (git, root) = try makeRepository(backend)
        defer { try? FileManager.default.removeItem(at: root) }

        try write("first", to: "Chapters/chapter-1.md", in: root)
        let commit = try #require(try git.commit(message: "first", paths: ["."]))

        try git.createTag(named: "beckit/abc-123/v1.0.0", at: commit.id)
        try git.createTag(named: "beckit/def-456/v2.0.0", at: commit.id)

        let mine = try git.tags(withPrefix: "beckit/abc-123/")
        #expect(mine.count == 1)
        #expect(mine.first?.name == "beckit/abc-123/v1.0.0")
        #expect(mine.first?.commit == commit.id)

        #expect(try git.tags(withPrefix: "beckit/").count == 2)
        #expect(try git.tags(withPrefix: "nothing/").isEmpty)
    }

    @Test("Pushing without a remote reports no remote", arguments: Backend.allCases)
    func pushWithoutRemote(backend: Backend) throws {
        let (git, root) = try makeRepository(backend)
        defer { try? FileManager.default.removeItem(at: root) }

        try write("first", to: "Chapters/chapter-1.md", in: root)
        _ = try git.commit(message: "first", paths: ["."])

        #expect(throws: GitError.self) { try git.push(credentials: nil) }
    }

    /// Sync is exercised against a local bare repository rather than GitHub, so
    /// the test is offline and deterministic while still going through the real
    /// fetch, merge-analysis and push paths.
    @Test("Push and pull against a real remote", arguments: Backend.allCases)
    func pushAndPull(backend: Backend) throws {
        let bare = FileManager.default.temporaryDirectory
            .appending(path: "beckit-bare-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: bare) }
        try runGit(["init", "--bare", "-b", "main", bare.path(percentEncoded: false)])

        let (author, authorRoot) = try makeRepository(backend)
        defer { try? FileManager.default.removeItem(at: authorRoot) }
        try runGit(["remote", "add", "origin", bare.path(percentEncoded: false)],
                   in: authorRoot)

        try write("first draft", to: "Chapters/chapter-1.md", in: authorRoot)
        _ = try author.commit(message: "first draft", paths: ["."])
        #expect(try author.remoteURL().path.contains("beckit-bare"))
        try author.push(credentials: nil)

        // A second checkout of the same book, as if from another machine.
        let readerRoot = FileManager.default.temporaryDirectory
            .appending(path: "beckit-reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readerRoot) }
        try runGit(["clone", bare.path(percentEncoded: false),
                    readerRoot.path(percentEncoded: false)])
        try configureIdentity(at: readerRoot)

        let reader: any GitRepository = switch backend {
        case .process: try SystemGitRepository(root: readerRoot)
        case .libgit2: try LibGit2Repository(root: readerRoot)
        }
        #expect(try reader.pull(credentials: nil) == false, "already up to date")

        // The author writes again and pushes; the reader fast-forwards onto it.
        try write("second draft", to: "Chapters/chapter-1.md", in: authorRoot)
        _ = try author.commit(message: "second draft", paths: ["."])
        try author.push(credentials: nil)

        #expect(try reader.pull(credentials: nil) == true, "should have fast-forwarded")
        let landed = try String(
            contentsOf: readerRoot.appending(path: "Chapters/chapter-1.md"), encoding: .utf8)
        #expect(landed == "second draft")
        #expect(try reader.history(forPath: "Chapters/chapter-1.md", limit: 10).count == 2)
    }

    // MARK: - Helpers

    /// Only for arranging the fixture — never for the behaviour under test.
    private func runGit(_ arguments: [String], in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }
}

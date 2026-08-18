import Foundation

/// `GitRepository` backed by the `git` executable.
///
/// This is the development backend. It depends on the Xcode command line tools
/// being installed, which is fine on a developer's Mac but not something to ask
/// of a writer downloading a book app — on a clean machine the first sync would
/// pop the "install command line developer tools" dialog. The shipping backend
/// is `LibGit2Repository`, which bundles libgit2 and has no external
/// dependency; see Scripts/build-libgit2.sh.
///
/// Keeping both behind `GitRepository` means the swap is a one-line change at
/// the call site, and this implementation stays useful for tests and CI.
public struct SystemGitRepository: GitRepository {
    public let root: URL
    private let executable: URL

    public init(root: URL, executable: URL = URL(filePath: "/usr/bin/git")) throws {
        guard FileManager.default.fileExists(
            atPath: root.appending(path: ".git").path(percentEncoded: false))
        else { throw GitError.notARepository(root) }
        self.root = root
        self.executable = executable
    }

    /// Clones a repository and returns a handle to it.
    public static func clone(
        from remote: URL,
        to destination: URL,
        credentials: GitCredentials?
    ) throws -> SystemGitRepository {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        try run(
            ["clone", remote.absoluteString, destination.path(percentEncoded: false)],
            in: parent, credentials: credentials)
        return try SystemGitRepository(root: destination)
    }

    /// Creates a repository in an existing directory.
    @discardableResult
    public static func initialize(at root: URL, remote: URL? = nil) throws -> SystemGitRepository {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try run(["init", "-b", "main"], in: root, credentials: nil)
        if let remote {
            try run(["remote", "add", "origin", remote.absoluteString], in: root, credentials: nil)
        }
        return try SystemGitRepository(root: root)
    }

    // MARK: - GitRepository

    public func hasUncommittedChanges() throws -> Bool {
        !(try git(["status", "--porcelain", "--untracked-files=no"]))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    public func commit(message: String, paths: [String]) throws -> GitCommit? {
        try git(["add", "--all", "--"] + paths)

        // --cached against HEAD tells us whether anything actually staged, so
        // an empty save does not produce an empty commit.
        let staged = try? git(["diff", "--cached", "--name-only"])
        guard let staged, !staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        try git(["commit", "--message", message])
        return try headCommit()
    }

    /// The commit at HEAD. Separate from `history(forPath:)` because that one
    /// uses `--follow`, which only accepts a single file path and is meaningless
    /// for "whatever was just committed".
    public func headCommit() throws -> GitCommit? {
        let output = try git(
            ["log", "--max-count=1", "--format=%H%x1f%an%x1f%aI%x1f%B"], trimming: false)
        let fields = output.split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard fields.count >= 4,
              let date = ISO8601DateFormatter().date(from: String(fields[2]))
        else { return nil }

        return GitCommit(
            id: String(fields[0]),
            message: String(fields[3]).trimmingCharacters(in: .whitespacesAndNewlines),
            authorName: String(fields[1]),
            date: date)
    }

    @discardableResult
    public func pull(credentials: GitCredentials?) throws -> Bool {
        // A local-only book is a supported way to work, not a failure. Checking
        // here rather than in every caller means no code path can turn "you
        // haven't connected GitHub" into an error the writer has to dismiss.
        guard (try? remoteURL()) != nil else { return false }
        guard try !hasUncommittedChanges() else { return false }

        let branch = try currentBranch()
        try git(["fetch", "origin"], credentials: credentials)

        let before = try revParse("HEAD")
        guard let remote = try? revParse("origin/\(branch)"), remote != before else {
            return false
        }

        do {
            try git(["merge", "--ff-only", "origin/\(branch)"])
        } catch {
            // Diverged — replay local commits on top of the remote instead.
            do {
                try git(["rebase", "origin/\(branch)"])
            } catch {
                try? git(["rebase", "--abort"])
                throw GitError.diverged
            }
        }
        return try revParse("HEAD") != before
    }

    public func push(credentials: GitCredentials?) throws {
        guard (try? remoteURL()) != nil else { throw GitError.noRemote }
        let branch = try currentBranch()
        do {
            try git(["push", "origin", branch, "refs/tags/*:refs/tags/*"],
                    credentials: credentials)
        } catch {
            // The remote moved ahead. Rebase onto it and try once more.
            try git(["fetch", "origin"], credentials: credentials)
            do {
                try git(["rebase", "origin/\(branch)"])
            } catch {
                try? git(["rebase", "--abort"])
                throw GitError.diverged
            }
            try git(["push", "origin", branch, "refs/tags/*:refs/tags/*"],
                    credentials: credentials)
        }
    }

    public func history(forPath path: String, limit: Int) throws -> [GitCommit] {
        // Record separator leads each commit and a unit separator ends every
        // field, so a commit message containing newlines — which they do —
        // still parses, and `--name-only` output lands cleanly in the last
        // field rather than bleeding into the next record.
        //
        // `--follow` is what makes history survive the 3.x import and any later
        // rename: the file moved, and the writer still wants their versions.
        let output = try git([
            "log", "--follow", "--name-only", "--max-count=\(limit)",
            "--format=%x1e%H%x1f%an%x1f%aI%x1f%B%x1f", "--", path,
        ], trimming: false)

        return output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 4,
                  let date = ISO8601DateFormatter().date(from: String(fields[2]))
            else { return nil }

            // The path this file had *in this commit*, which is not the current
            // path once a rename is in the history.
            let pathAtCommit = fields.count > 4
                ? fields[4].split(whereSeparator: \.isNewline).first.map(String.init)
                : nil

            return GitCommit(
                id: String(fields[0]),
                message: String(fields[3]).trimmingCharacters(in: .whitespacesAndNewlines),
                authorName: String(fields[1]),
                date: date,
                path: pathAtCommit ?? path)
        }
    }

    public func contents(ofPath path: String, at commit: GitCommit.ID) throws -> String {
        try git(["show", "\(commit):\(path)"], trimming: false)
    }

    public func createTag(named name: String, at commit: GitCommit.ID) throws {
        try git(["tag", "--force", name, commit])
    }

    public func tags(withPrefix prefix: String) throws -> [(name: String, commit: GitCommit.ID)] {
        // Every tag, filtered here rather than by a ref pattern. git's globs
        // are path-component based, so `refs/tags/beckit/*` matches
        // `refs/tags/beckit/x` but not `refs/tags/beckit/<id>/v1.0.0` — and
        // Beckit's tags are two components deep.
        //
        // `for-each-ref` spells a literal byte `%1f`; `%x1f` is `git log`'s
        // syntax and comes back as the four characters "%x1f".
        let output = try git([
            "for-each-ref", "--format=%(refname:strip=2)%1f%(objectname)",
            "refs/tags/",
        ])
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\u{1f}")
            guard fields.count == 2, fields[0].hasPrefix(prefix) else { return nil }
            return (String(fields[0]), String(fields[1]))
        }
    }

    // MARK: - Plumbing

    public func currentBranch() throws -> String {
        try git(["rev-parse", "--abbrev-ref", "HEAD"])
    }

    public func remoteURL() throws -> URL {
        guard let url = URL(string: try git(["remote", "get-url", "origin"])) else {
            throw GitError.noRemote
        }
        return url
    }

    @discardableResult
    private func revParse(_ reference: String) throws -> String {
        try git(["rev-parse", reference])
    }

    @discardableResult
    private func git(
        _ arguments: [String],
        credentials: GitCredentials? = nil,
        trimming: Bool = true
    ) throws -> String {
        try Self.run(arguments, in: root, credentials: credentials,
                     executable: executable, trimming: trimming)
    }

    @discardableResult
    private static func run(
        _ arguments: [String],
        in directory: URL,
        credentials: GitCredentials?,
        executable: URL = URL(filePath: "/usr/bin/git"),
        trimming: Bool = true
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        // Never let git open a GUI or terminal prompt; a hung prompt inside an
        // app with no console is unrecoverable for the user.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"

        if let credentials {
            // Supply the token over a header rather than embedding it in the
            // remote URL, so it never lands in .git/config or in a crash log.
            let pair = Data("\(credentials.username):\(credentials.token)".utf8)
                .base64EncodedString()
            process.arguments = ["-c", "http.extraHeader=Authorization: Basic \(pair)"] + arguments
        }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw GitError.gitUnavailable
        }

        // Drain both pipes before waiting; a chatty `git log` can otherwise
        // fill the buffer and deadlock the child.
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: outputData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GitError.commandFailed(
                command: arguments.first ?? "",
                status: process.terminationStatus,
                output: String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return trimming
            ? output.trimmingCharacters(in: .whitespacesAndNewlines)
            : output
    }
}

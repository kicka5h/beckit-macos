import Foundation

/// Everything Beckit needs from git, and nothing more.
///
/// The app is written entirely against this protocol so that the backing
/// implementation — currently a process-based one for development, libgit2 for
/// shipping — is invisible above this layer.
public protocol GitRepository: Sendable {
    var root: URL { get }

    /// The `origin` URL. Throws `GitError.noRemote` for a local-only book,
    /// which is a supported state rather than an error condition.
    func remoteURL() throws -> URL

    /// True when tracked files differ from HEAD.
    func hasUncommittedChanges() throws -> Bool

    /// Stages `paths` (repo-relative) and commits them. Returns the new commit,
    /// or nil when there was nothing staged to commit.
    @discardableResult
    func commit(message: String, paths: [String]) throws -> GitCommit?

    /// Fetches origin and fast-forwards, falling back to rebase when the
    /// branches have diverged. Returns whether the working tree changed.
    @discardableResult
    func pull(credentials: GitCredentials?) throws -> Bool

    /// Pushes the current branch, rebasing and retrying once if the remote has
    /// moved ahead.
    func push(credentials: GitCredentials?) throws

    /// Commits touching `path`, newest first.
    func history(forPath path: String, limit: Int) throws -> [GitCommit]

    /// The contents of `path` as of `commit`.
    func contents(ofPath path: String, at commit: GitCommit.ID) throws -> String

    /// Marks a commit, e.g. `beckit/<section-id>/v1.2.0`.
    func createTag(named name: String, at commit: GitCommit.ID) throws

    /// Tags beginning with `prefix`, paired with the commit they point at.
    func tags(withPrefix prefix: String) throws -> [(name: String, commit: GitCommit.ID)]
}

public extension GitRepository {
    /// Reads a commit's version of the file it was found through, using the
    /// path it had *then*. Always prefer this over `contents(ofPath:at:)` when
    /// you have the commit from `history`, or reads will fail for every commit
    /// made before the file was renamed.
    func contents(of commit: GitCommit) throws -> String {
        try contents(ofPath: commit.path, at: commit.id)
    }
}

public struct GitCommit: Sendable, Hashable, Identifiable {
    public typealias ID = String  // full SHA

    public var id: ID
    public var message: String
    public var authorName: String
    public var date: Date
    /// The path the queried file had *at this commit*. Not necessarily its
    /// current path: history follows renames, and the 3.x import renames every
    /// file in the book exactly once.
    public var path: String

    public init(
        id: ID, message: String, authorName: String, date: Date, path: String = ""
    ) {
        self.id = id
        self.message = message
        self.authorName = authorName
        self.date = date
        self.path = path
    }

    public var shortID: String { String(id.prefix(7)) }

    /// First line of the message, which is what the history list shows.
    public var summary: String {
        message.prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
    }
}

/// HTTPS credentials for a remote. Beckit only ever uses a GitHub token, sent
/// as the password with a placeholder username.
public struct GitCredentials: Sendable, Hashable {
    public var username: String
    public var token: String

    public init(username: String = "x-access-token", token: String) {
        self.username = username
        self.token = token
    }
}

public enum GitError: Error, LocalizedError {
    case commandFailed(command: String, status: Int32, output: String)
    case notARepository(URL)
    case noRemote
    case diverged
    case gitUnavailable

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, _, let output):
            "git \(command) failed: \(output)"
        case .notARepository(let url):
            "\(url.lastPathComponent) is not a git repository."
        case .noRemote:
            "This book has no GitHub remote configured."
        case .diverged:
            """
            Your local changes and GitHub have diverged and could not be \
            reconciled automatically.
            """
        case .gitUnavailable:
            "git is not available on this system."
        }
    }
}

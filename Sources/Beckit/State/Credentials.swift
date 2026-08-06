import BeckitGit
import Foundation

/// Process-wide access to the GitHub token.
///
/// An actor rather than a plain global because the keychain is hit from
/// background sync tasks as well as the main actor, and the cache must not be
/// read while it is being replaced.
actor Credentials {
    static let shared = Credentials()

    private let store = TokenStore()
    private var cached: String??

    /// The stored token, or nil when the writer has not signed in.
    func token() -> String? {
        if let cached { return cached }
        let token = try? store.load()
        cached = .some(token)
        return token
    }

    func set(_ token: String?) throws {
        if let token {
            try store.save(token)
        } else {
            try store.delete()
        }
        cached = .some(token)
    }

    /// Convenience for the sync paths, which want credentials or nothing.
    static func current() async -> GitCredentials? {
        await shared.token().map { GitCredentials(token: $0) }
    }
}

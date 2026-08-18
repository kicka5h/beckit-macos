import Clibgit2
import Foundation

/// One-time libgit2 initialisation.
///
/// `git_libgit2_init` is reference counted and must run before anything else in
/// the library. Doing it from a `let` means it happens exactly once, whichever
/// thread gets there first.
enum LibGit2 {
    private static let initialized: Bool = {
        git_libgit2_init()
        return true
    }()

    static func start() {
        _ = initialized
    }

    /// Turns libgit2's last error into something throwable.
    ///
    /// libgit2 reports failure as a negative return code and stashes the detail
    /// in thread-local state, so the message has to be collected immediately
    /// after the failing call.
    static func check(_ code: Int32, _ operation: String) throws {
        guard code < 0 else { return }

        let message = git_error_last().map { String(cString: $0.pointee.message) }
            ?? "unknown libgit2 error"

        switch code {
        case GIT_ENOTFOUND.rawValue: throw LibGit2Error.notFound(operation, message)
        case GIT_EAUTH.rawValue, GIT_ECERTIFICATE.rawValue:
            throw LibGit2Error.authentication(message)
        case GIT_ECONFLICT.rawValue, GIT_EMERGECONFLICT.rawValue:
            throw GitError.diverged
        default: throw LibGit2Error.failed(operation, code, message)
        }
    }

    /// Runs `body`, guaranteeing the libgit2 object it produced is freed.
    ///
    /// Nearly every libgit2 call hands back an owned pointer that has to be
    /// freed with a type-specific function, and the error paths are where those
    /// leaks hide. This puts the free in a `defer` at the point of creation so
    /// there is only one place to get it right.
    static func withObject<Pointer, Result>(
        _ create: (inout Pointer?) -> Int32,
        free: (Pointer?) -> Void,
        operation: String,
        _ body: (Pointer) throws -> Result
    ) throws -> Result {
        var pointer: Pointer?
        try check(create(&pointer), operation)
        defer { free(pointer) }
        guard let pointer else { throw LibGit2Error.failed(operation, 0, "null result") }
        return try body(pointer)
    }
}

public enum LibGit2Error: Error, LocalizedError {
    case failed(String, Int32, String)
    case notFound(String, String)
    case authentication(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let operation, _, let message):
            "git \(operation) failed: \(message)"
        case .notFound(let operation, let message):
            "git \(operation): \(message)"
        case .authentication(let message):
            """
            GitHub rejected the sign-in: \(message). Sign out and back in from \
            Settings.
            """
        }
    }
}

// MARK: - String bridging

/// A `git_strarray` built from Swift strings, valid for the duration of `body`.
///
/// libgit2 takes path lists this way and does not copy them, so the backing
/// buffers have to outlive the call — which is what the nesting here is for.
func withStrArray<Result>(
    _ strings: [String], _ body: (inout git_strarray) throws -> Result
) rethrows -> Result {
    let cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer { cStrings.forEach { free($0) } }

    var buffer = cStrings
    return try buffer.withUnsafeMutableBufferPointer { pointer in
        var array = git_strarray(strings: pointer.baseAddress, count: strings.count)
        return try body(&array)
    }
}

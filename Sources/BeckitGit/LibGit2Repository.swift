import Clibgit2
import Foundation

/// `GitRepository` backed by libgit2, linked into the app.
///
/// This is the shipping backend. `SystemGitRepository` needs `/usr/bin/git`,
/// which on a Mac without the Xcode command line tools is a stub that pops the
/// "install command line developer tools" dialog — not something to put in
/// front of someone who just wants to write. Nothing here shells out.
public final class LibGit2Repository: GitRepository, @unchecked Sendable {
    public let root: URL

    /// libgit2 objects are not thread-safe for concurrent use on one
    /// repository, and Beckit drives this from detached tasks (a save commits
    /// while a pull may still be running). One lock per repository is plenty:
    /// the operations are short and already serialised by the UI.
    private let lock = NSLock()
    private let repository: OpaquePointer

    public init(root: URL) throws {
        LibGit2.start()
        self.root = root

        var pointer: OpaquePointer?
        try LibGit2.check(
            git_repository_open(&pointer, root.path(percentEncoded: false)), "open")
        guard let pointer else { throw GitError.notARepository(root) }
        self.repository = pointer
    }

    deinit { git_repository_free(repository) }

    private func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Creating repositories

    @discardableResult
    public static func initialize(at root: URL, remote: URL? = nil) throws -> LibGit2Repository {
        LibGit2.start()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var pointer: OpaquePointer?
        var options = git_repository_init_options()
        git_repository_init_options_init(
            &options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        options.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue
        let head = strdup("main")
        defer { free(head) }
        options.initial_head = UnsafePointer(head)

        try LibGit2.check(
            git_repository_init_ext(&pointer, root.path(percentEncoded: false), &options),
            "init")
        git_repository_free(pointer)

        let repository = try LibGit2Repository(root: root)
        if let remote {
            try repository.locked {
                var remotePointer: OpaquePointer?
                try LibGit2.check(
                    git_remote_create(
                        &remotePointer, repository.repository, "origin",
                        remote.absoluteString),
                    "remote add")
                git_remote_free(remotePointer)
            }
        }
        return repository
    }

    public static func clone(
        from remote: URL, to destination: URL, credentials: GitCredentials?
    ) throws -> LibGit2Repository {
        LibGit2.start()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var options = git_clone_options()
        git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION))

        return try withCredentials(credentials) { callbacks in
            options.fetch_opts.callbacks = callbacks
            var pointer: OpaquePointer?
            try LibGit2.check(
                git_clone(&pointer, remote.absoluteString,
                          destination.path(percentEncoded: false), &options),
                "clone")
            git_repository_free(pointer)
            return try LibGit2Repository(root: destination)
        }
    }

    // MARK: - Inspection

    public func remoteURL() throws -> URL {
        try locked {
            var pointer: OpaquePointer?
            guard git_remote_lookup(&pointer, repository, "origin") == 0, let pointer else {
                throw GitError.noRemote
            }
            defer { git_remote_free(pointer) }
            guard let url = git_remote_url(pointer).map({ String(cString: $0) }),
                  let parsed = URL(string: url)
            else { throw GitError.noRemote }
            return parsed
        }
    }

    public func hasUncommittedChanges() throws -> Bool {
        try locked {
            var options = git_status_options()
            git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
            // Tracked files only, matching `git status --untracked-files=no`:
            // a stray file in the book folder is not a reason to refuse a pull.
            options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
            options.flags = GIT_STATUS_OPT_EXCLUDE_SUBMODULES.rawValue

            var list: OpaquePointer?
            try LibGit2.check(git_status_list_new(&list, repository, &options), "status")
            defer { git_status_list_free(list) }

            for index in 0..<git_status_list_entrycount(list) {
                guard let entry = git_status_byindex(list, index) else { continue }
                let status = entry.pointee.status.rawValue
                let untracked = GIT_STATUS_WT_NEW.rawValue | GIT_STATUS_IGNORED.rawValue
                if status & ~untracked != 0 { return true }
            }
            return false
        }
    }

    // MARK: - Committing

    @discardableResult
    public func commit(message: String, paths: [String]) throws -> GitCommit? {
        try locked {
            var index: OpaquePointer?
            try LibGit2.check(git_repository_index(&index, repository), "index")
            defer { git_index_free(index) }

            // `add_all` stages modifications, additions *and* deletions under
            // the given paths, which is what the caller means by "commit these".
            try withStrArray(paths) { pathspec in
                try LibGit2.check(
                    git_index_add_all(index, &pathspec,
                                      GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil),
                    "index add")
            }
            try LibGit2.check(git_index_write(index), "index write")

            var treeID = git_oid()
            try LibGit2.check(git_index_write_tree(&treeID, index), "write tree")

            var tree: OpaquePointer?
            try LibGit2.check(git_tree_lookup(&tree, repository, &treeID), "tree lookup")
            defer { git_tree_free(tree) }

            let parent = try? headCommitPointer()
            defer { if let parent { git_commit_free(parent) } }

            // Nothing staged: the tree is identical to the parent's. Reported as
            // nil rather than an empty commit, matching the other backend.
            if let parent {
                var parentTree: OpaquePointer?
                try LibGit2.check(git_commit_tree(&parentTree, parent), "parent tree")
                defer { git_tree_free(parentTree) }
                if git_oid_cmp(git_tree_id(tree), git_tree_id(parentTree)) == 0 {
                    return nil
                }
            }

            let signature = try makeSignature()
            defer { git_signature_free(signature) }

            var commitID = git_oid()
            var parents: [OpaquePointer?] = parent.map { [$0] } ?? []
            try parents.withUnsafeMutableBufferPointer { buffer in
                try LibGit2.check(
                    git_commit_create(
                        &commitID, repository, "HEAD", signature, signature,
                        nil, message, tree, buffer.count,
                        buffer.count == 0 ? nil : buffer.baseAddress),
                    "commit")
            }

            return try readCommit(id: commitID, path: paths.first ?? "")
        }
    }

    public func createTag(named name: String, at commit: GitCommit.ID) throws {
        try locked {
            var oid = try objectID(from: commit)
            var object: OpaquePointer?
            try LibGit2.check(
                git_object_lookup(&object, repository, &oid, GIT_OBJECT_COMMIT),
                "tag target")
            defer { git_object_free(object) }

            var tagID = git_oid()
            try LibGit2.check(
                git_tag_create_lightweight(&tagID, repository, name, object, 1),
                "tag")
        }
    }

    /// Tag names, without taking the lock — for callers that already hold it.
    /// `NSLock` is not recursive, so `push` cannot call `tags(withPrefix:)`.
    private func unlockedTagNames() -> [String] {
        var names = git_strarray()
        guard git_tag_list(&names, repository) == 0 else { return [] }
        defer { git_strarray_dispose(&names) }
        return (0..<names.count).compactMap { index in
            names.strings[index].map { String(cString: $0) }
        }
    }

    public func tags(withPrefix prefix: String) throws -> [(name: String, commit: GitCommit.ID)] {
        try locked {
            var names = git_strarray()
            try LibGit2.check(git_tag_list(&names, repository), "tag list")
            defer { git_strarray_dispose(&names) }

            var result: [(name: String, commit: GitCommit.ID)] = []
            for index in 0..<names.count {
                guard let raw = names.strings[index] else { continue }
                let name = String(cString: raw)
                guard name.hasPrefix(prefix) else { continue }

                var oid = git_oid()
                guard git_reference_name_to_id(&oid, repository, "refs/tags/" + name) == 0
                else { continue }

                // A lightweight tag points straight at the commit; an annotated
                // one points at a tag object that has to be peeled first.
                var object: OpaquePointer?
                if git_object_lookup(&object, repository, &oid, GIT_OBJECT_ANY) == 0,
                   let object {
                    defer { git_object_free(object) }
                    var peeled: OpaquePointer?
                    if git_object_peel(&peeled, object, GIT_OBJECT_COMMIT) == 0, let peeled {
                        defer { git_object_free(peeled) }
                        result.append((name, Self.string(from: git_object_id(peeled))))
                        continue
                    }
                }
                result.append((name, Self.string(from: &oid)))
            }
            return result
        }
    }

    // MARK: - Reading

    public func contents(ofPath path: String, at commit: GitCommit.ID) throws -> String {
        try locked {
            var oid = try objectID(from: commit)
            var commitPointer: OpaquePointer?
            try LibGit2.check(
                git_commit_lookup(&commitPointer, repository, &oid), "commit lookup")
            defer { git_commit_free(commitPointer) }

            var tree: OpaquePointer?
            try LibGit2.check(git_commit_tree(&tree, commitPointer), "commit tree")
            defer { git_tree_free(tree) }

            var entry: OpaquePointer?
            try LibGit2.check(git_tree_entry_bypath(&entry, tree, path), "path in commit")
            defer { git_tree_entry_free(entry) }

            var blob: OpaquePointer?
            try LibGit2.check(
                git_blob_lookup(&blob, repository, git_tree_entry_id(entry)), "blob")
            defer { git_blob_free(blob) }

            guard let bytes = git_blob_rawcontent(blob) else { return "" }
            let size = Int(git_blob_rawsize(blob))
            return String(decoding: Data(bytes: bytes, count: size), as: UTF8.self)
        }
    }

    /// Commits touching `path`, newest first, following the file across renames.
    ///
    /// libgit2 has no equivalent of `git log --follow`, so the walk carries the
    /// path with it: at each commit the diff against its parent is checked for a
    /// rename of the file being tracked, and the path being looked for changes
    /// to the older name before the walk continues. Without this, history for
    /// any book converted from the 3.x layout would stop at the import, because
    /// that is where every file was renamed.
    public func history(forPath path: String, limit: Int) throws -> [GitCommit] {
        try locked {
            var walker: OpaquePointer?
            try LibGit2.check(git_revwalk_new(&walker, repository), "revwalk")
            defer { git_revwalk_free(walker) }

            git_revwalk_sorting(walker, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
            guard git_revwalk_push_head(walker) == 0 else { return [] }  // no commits yet

            var commits: [GitCommit] = []
            var tracked = path
            var oid = git_oid()

            while commits.count < limit, git_revwalk_next(&oid, walker) == 0 {
                var commitPointer: OpaquePointer?
                guard git_commit_lookup(&commitPointer, repository, &oid) == 0,
                      let commitPointer else { continue }
                defer { git_commit_free(commitPointer) }

                let (touched, renamedFrom) = try pathChange(
                    in: commitPointer, tracking: tracked)
                guard touched else { continue }

                commits.append(try readCommit(id: oid, path: tracked))
                if let renamedFrom { tracked = renamedFrom }
            }
            return commits
        }
    }

    /// Whether `path` changed in this commit, and the name it had before if the
    /// change was a rename.
    private func pathChange(
        in commit: OpaquePointer, tracking path: String
    ) throws -> (touched: Bool, renamedFrom: String?) {
        var tree: OpaquePointer?
        try LibGit2.check(git_commit_tree(&tree, commit), "commit tree")
        defer { git_tree_free(tree) }

        var parentTree: OpaquePointer?
        if git_commit_parentcount(commit) > 0 {
            var parent: OpaquePointer?
            if git_commit_parent(&parent, commit, 0) == 0, let parent {
                defer { git_commit_free(parent) }
                git_commit_tree(&parentTree, parent)
            }
        }
        defer { if let parentTree { git_tree_free(parentTree) } }

        var diff: OpaquePointer?
        try LibGit2.check(
            git_diff_tree_to_tree(&diff, repository, parentTree, tree, nil), "diff")
        defer { git_diff_free(diff) }

        // Rename detection is what makes following the file possible at all.
        var findOptions = git_diff_find_options()
        git_diff_find_options_init(&findOptions, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
        findOptions.flags = GIT_DIFF_FIND_RENAMES.rawValue
        git_diff_find_similar(diff, &findOptions)

        for index in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, index) else { continue }
            let newPath = delta.pointee.new_file.path.map { String(cString: $0) }
            let oldPath = delta.pointee.old_file.path.map { String(cString: $0) }
            guard newPath == path else { continue }

            let renamed = delta.pointee.status == GIT_DELTA_RENAMED
                && oldPath != nil && oldPath != path
            return (true, renamed ? oldPath : nil)
        }
        return (false, nil)
    }

    // MARK: - Syncing

    @discardableResult
    public func pull(credentials: GitCredentials?) throws -> Bool {
        // A local-only book is a supported way to work, not a failure.
        guard (try? remoteURL()) != nil else { return false }
        guard try !hasUncommittedChanges() else { return false }

        let branch = try currentBranch()

        return try locked {
            try withCredentials(credentials) { callbacks in
                var remote: OpaquePointer?
                try LibGit2.check(
                    git_remote_lookup(&remote, repository, "origin"), "remote lookup")
                defer { git_remote_free(remote) }

                var options = git_fetch_options()
                git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
                options.callbacks = callbacks
                try LibGit2.check(git_remote_fetch(remote, nil, &options, nil), "fetch")

                var upstream = git_oid()
                guard git_reference_name_to_id(
                    &upstream, repository, "refs/remotes/origin/\(branch)") == 0
                else { return false }  // no remote-tracking branch yet

                var head = git_oid()
                guard git_reference_name_to_id(&head, repository, "HEAD") == 0 else {
                    return false
                }
                if git_oid_cmp(&head, &upstream) == 0 { return false }  // up to date

                var annotated: OpaquePointer?
                try LibGit2.check(
                    git_annotated_commit_lookup(&annotated, repository, &upstream),
                    "annotated commit")
                defer { git_annotated_commit_free(annotated) }

                var analysis = GIT_MERGE_ANALYSIS_NONE
                var preference = GIT_MERGE_PREFERENCE_NONE
                var heads: [OpaquePointer?] = [annotated]
                try heads.withUnsafeMutableBufferPointer { buffer in
                    try LibGit2.check(
                        git_merge_analysis(&analysis, &preference, repository,
                                           buffer.baseAddress, 1),
                        "merge analysis")
                }

                if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
                    return false
                }
                if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 {
                    try fastForward(to: upstream, branch: branch)
                    return true
                }

                // Diverged: replay the local commits on top of the remote, the
                // same shape as the process backend's rebase fallback.
                try rebase(onto: annotated!)
                return true
            }
        }
    }

    public func push(credentials: GitCredentials?) throws {
        guard (try? remoteURL()) != nil else { throw GitError.noRemote }
        let branch = try currentBranch()

        try locked {
            try withCredentials(credentials) { callbacks in
                var remote: OpaquePointer?
                try LibGit2.check(
                    git_remote_lookup(&remote, repository, "origin"), "remote lookup")
                defer { git_remote_free(remote) }

                var options = git_push_options()
                git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
                options.callbacks = callbacks

                // Tags travel with the branch so the version history the
                // sidebar reads is the same on every machine. Named one by one
                // because libgit2 rejects a wildcard refspec on push — it wants
                // references that resolve, not a pattern.
                var refspecs = ["refs/heads/\(branch):refs/heads/\(branch)"]
                for tag in unlockedTagNames() {
                    refspecs.append("refs/tags/\(tag):refs/tags/\(tag)")
                }
                try withStrArray(refspecs) { specs in
                    try LibGit2.check(git_remote_push(remote, &specs, &options), "push")
                }
            }
        }
    }

    // MARK: - Plumbing

    public func currentBranch() throws -> String {
        try locked {
            var head: OpaquePointer?
            guard git_repository_head(&head, repository) == 0, let head else {
                // An empty repository has an unborn HEAD; report what it will be.
                return "main"
            }
            defer { git_reference_free(head) }
            guard let name = git_reference_shorthand(head) else { return "main" }
            return String(cString: name)
        }
    }

    private func headCommitPointer() throws -> OpaquePointer {
        var oid = git_oid()
        try LibGit2.check(
            git_reference_name_to_id(&oid, repository, "HEAD"), "head")
        var commit: OpaquePointer?
        try LibGit2.check(git_commit_lookup(&commit, repository, &oid), "head commit")
        guard let commit else { throw GitError.notARepository(root) }
        return commit
    }

    private func fastForward(to target: git_oid, branch: String) throws {
        var target = target
        var object: OpaquePointer?
        try LibGit2.check(
            git_object_lookup(&object, repository, &target, GIT_OBJECT_COMMIT), "ff target")
        defer { git_object_free(object) }

        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try LibGit2.check(git_checkout_tree(repository, object, &options), "checkout")

        var reference: OpaquePointer?
        try LibGit2.check(
            git_reference_lookup(&reference, repository, "refs/heads/\(branch)"),
            "branch ref")
        defer { git_reference_free(reference) }

        var updated: OpaquePointer?
        try LibGit2.check(
            git_reference_set_target(&updated, reference, &target, "pull: fast-forward"),
            "fast-forward")
        git_reference_free(updated)
    }

    /// Replays local commits on top of `upstream`.
    ///
    /// Aborts and reports divergence on the first conflict rather than leaving
    /// a half-finished rebase in the working tree — a writer should never open
    /// their book to find it mid-operation.
    private func rebase(onto upstream: OpaquePointer) throws {
        var options = git_rebase_options()
        git_rebase_options_init(&options, UInt32(GIT_REBASE_OPTIONS_VERSION))

        var rebase: OpaquePointer?
        try LibGit2.check(
            git_rebase_init(&rebase, repository, nil, upstream, nil, &options), "rebase")
        defer { git_rebase_free(rebase) }

        let signature = try makeSignature()
        defer { git_signature_free(signature) }

        var operation: UnsafeMutablePointer<git_rebase_operation>?
        while git_rebase_next(&operation, rebase) == 0 {
            var commitID = git_oid()
            let result = git_rebase_commit(&commitID, rebase, nil, signature, nil, nil)
            if result == GIT_EAPPLIED.rawValue { continue }  // already upstream
            guard result >= 0 else {
                git_rebase_abort(rebase)
                throw GitError.diverged
            }
        }
        try LibGit2.check(git_rebase_finish(rebase, signature), "rebase finish")
    }

    /// The identity commits are made under.
    ///
    /// Falls back to a Beckit identity when git is not configured, because a
    /// writer who has never set `user.name` should still be able to save.
    private func makeSignature() throws -> UnsafeMutablePointer<git_signature> {
        var signature: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&signature, repository) == 0, let signature {
            return signature
        }
        try LibGit2.check(
            git_signature_now(&signature, "Beckit", "beckit@localhost"), "signature")
        guard let signature else { throw GitError.notARepository(root) }
        return signature
    }

    private func readCommit(id: git_oid, path: String) throws -> GitCommit {
        var id = id
        var commit: OpaquePointer?
        try LibGit2.check(git_commit_lookup(&commit, repository, &id), "commit lookup")
        defer { git_commit_free(commit) }

        let message = git_commit_message(commit).map { String(cString: $0) } ?? ""
        let author = git_commit_author(commit)
        let name = author?.pointee.name.map { String(cString: $0) } ?? ""
        let time = TimeInterval(git_commit_time(commit))

        return GitCommit(
            id: Self.string(from: &id),
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            authorName: name,
            date: Date(timeIntervalSince1970: time),
            path: path)
    }

    private func objectID(from string: String) throws -> git_oid {
        var oid = git_oid()
        try LibGit2.check(git_oid_fromstr(&oid, string), "parse object id")
        return oid
    }

    private static func string(from oid: UnsafePointer<git_oid>?) -> String {
        guard let oid else { return "" }
        var buffer = [CChar](repeating: 0, count: 41)
        git_oid_fmt(&buffer, oid)
        buffer[40] = 0
        return String(cString: buffer)
    }

    private static func string(from oid: inout git_oid) -> String {
        withUnsafePointer(to: &oid) { string(from: $0) }
    }
}

// MARK: - Credentials

/// Carries the token to libgit2's C credential callback, which cannot capture.
private final class CredentialBox {
    let credentials: GitCredentials
    init(_ credentials: GitCredentials) { self.credentials = credentials }
}

/// Runs `body` with remote callbacks that answer libgit2's credential request.
///
/// The callback is C, so the token reaches it through the payload pointer
/// rather than a closure capture. It is a class box so its lifetime is explicit
/// and it is freed on the way out rather than leaking per call.
private func withCredentials<Result>(
    _ credentials: GitCredentials?,
    _ body: (git_remote_callbacks) throws -> Result
) throws -> Result {
    var callbacks = git_remote_callbacks()
    git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))

    guard let credentials else { return try body(callbacks) }

    let box = Unmanaged.passRetained(CredentialBox(credentials))
    defer { box.release() }

    callbacks.payload = box.toOpaque()
    callbacks.credentials = { output, _, _, allowed, payload in
        guard let payload else { return -1 }
        let box = Unmanaged<CredentialBox>.fromOpaque(payload).takeUnretainedValue()

        guard allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 else { return -1 }
        return git_credential_userpass_plaintext_new(
            output, box.credentials.username, box.credentials.token)
    }

    return try body(callbacks)
}

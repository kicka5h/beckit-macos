import BeckitGit
import BeckitKit
import Foundation
import Observation

/// The open book: its manifest, the document being edited, and everything the
/// window needs to render.
///
/// Main-actor isolated because it is UI state. Anything that touches disk or
/// the network is pushed into a detached task and hops back here to publish the
/// result — the Python app did all of this inline, which is why saving a
/// chapter froze the window until GitHub answered.
@MainActor
@Observable
final class Workspace {
    let store: BookStore
    let git: any GitRepository

    private(set) var book: Book
    private(set) var planning: [PlanningTree.Node] = []

    var selection: BookSection.ID?
    /// Live text of the open section.
    var text: String = ""

    private(set) var isDirty = false
    private(set) var documentWordCount = 0
    private(set) var bookWordCount = 0
    private(set) var syncState: SyncState = .idle
    private(set) var history: [Revision] = []

    /// The section's contents as of the last save, used to decide how big the
    /// next version bump should be.
    private var baseline: String = ""
    private var wordCountTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?

    enum SyncState: Equatable {
        case idle
        case syncing(String)
        case failed(String)

        var message: String? {
            switch self {
            case .idle: nil
            case .syncing(let text): text
            case .failed(let text): text
            }
        }
    }

    /// One entry in the version history pane.
    struct Revision: Identifiable, Hashable {
        var id: String { commit.id }
        var commit: GitCommit
        var version: SemanticVersion?
    }

    init(store: BookStore, git: any GitRepository, book: Book) {
        self.store = store
        self.git = git
        self.book = book
        self.planning = PlanningTree.load(in: store.root)
        select(book.sections.first?.id)
        recountBook()
    }

    // MARK: - Opening a book

    static func open(at root: URL) throws -> Workspace {
        let store = BookStore(root: root)
        guard store.hasManifest else { throw BookStoreError.notABook(root) }

        // A book folder restored from a backup can have lost its .git; make it
        // a repository again rather than refusing to open the writing.
        let git = try (try? SystemGitRepository(root: root))
            ?? SystemGitRepository.initialize(at: root)

        return Workspace(store: store, git: git, book: try store.loadBook())
    }

    // MARK: - Selection

    var currentSection: BookSection? {
        selection.flatMap { book[$0] }
    }

    func select(_ id: BookSection.ID?) {
        guard id != selection else { return }
        if isDirty { saveNow() }

        selection = id
        guard let section = id.flatMap({ book[$0] }) else {
            text = ""
            baseline = ""
            history = []
            documentWordCount = 0
            return
        }

        text = store.readIfPresent(section)
        baseline = text
        isDirty = false
        documentWordCount = WordCount.count(in: text)
        loadHistory(for: section)
    }

    // MARK: - Editing

    /// Called on every keystroke. Cheap work happens now; anything expensive is
    /// debounced.
    func textChanged(_ newText: String) {
        text = newText
        isDirty = newText != baseline
        documentWordCount = WordCount.count(in: newText)
        scheduleAutosave()
    }

    /// Writes to disk a few seconds after typing stops. Committing is separate
    /// and explicit — a writer should not generate a version per pause, but
    /// they should also never lose work to a crash.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard let section = currentSection else { return }
        let contents = text

        autosaveTask = Task { [store] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? store.write(contents, to: section)
        }
    }

    // MARK: - Saving

    /// Writes, versions, commits and pushes the open section.
    ///
    /// The version bump is derived from how much the prose actually changed —
    /// see `ChangeClassifier` — so the writer never has to decide between major
    /// and minor.
    func saveNow() {
        guard var section = currentSection else { return }
        autosaveTask?.cancel()

        let contents = text
        let significance = ChangeClassifier.classify(from: baseline, to: contents)

        if let significance {
            section.version = section.version.bumped(significance)
            book[section.id] = section
        }

        do {
            try store.write(contents, to: section)
            try store.save(book)
        } catch {
            syncState = .failed(error.localizedDescription)
            return
        }

        baseline = contents
        isDirty = false
        recountBook()

        let message = commitMessage(for: section, significance: significance)
        let paths = [section.relativePath, "book.json"]
        let tag = significance == nil ? nil : Self.tagName(for: section)

        commitAndPush(message: message, paths: paths, tag: tag, section: section)
    }

    private func commitMessage(
        for section: BookSection, significance: ChangeSignificance?
    ) -> String {
        let name = displayName(for: section)
        guard let significance else { return "\(name): revisions" }
        return "\(name): \(section.version) (\(significance.rawValue))"
    }

    /// Tags are namespaced per section so a chapter's own history survives a
    /// reorder, which repository-wide version tags could never do.
    static func tagName(for section: BookSection) -> String {
        "beckit/\(section.id.uuidString.lowercased())/\(section.version)"
    }

    private func commitAndPush(
        message: String, paths: [String], tag: String?, section: BookSection
    ) {
        syncState = .syncing("Saving…")

        Task { [git] in
            do {
                let commit = try await Task.detached(priority: .userInitiated) {
                    let commit = try git.commit(message: message, paths: paths)
                    if let commit, let tag {
                        try? git.createTag(named: tag, at: commit.id)
                    }
                    return commit
                }.value

                guard commit != nil else {
                    syncState = .idle
                    return
                }
                loadHistory(for: section)
                await push()
            } catch {
                syncState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Sync

    /// True once the book has somewhere to sync to. A local-only book is a
    /// perfectly good book, so every sync path checks this and stays quiet
    /// rather than reporting "no remote" as a failure over and over.
    var hasRemote: Bool {
        (try? git.remoteURL()) != nil
    }

    func push() async {
        guard hasRemote else { return }
        syncState = .syncing("Pushing to GitHub…")
        let credentials = await Credentials.current()
        do {
            try await Task.detached(priority: .utility) { [git] in
                try git.push(credentials: credentials)
            }.value
            syncState = .idle
        } catch {
            syncState = .failed(error.localizedDescription)
        }
    }

    /// Pulls before the writer starts, so two machines do not diverge silently.
    func pull() async {
        guard hasRemote else { return }
        syncState = .syncing("Checking GitHub…")
        let credentials = await Credentials.current()
        do {
            let changed = try await Task.detached(priority: .utility) { [git] in
                try git.pull(credentials: credentials)
            }.value

            if changed {
                book = (try? store.loadBook()) ?? book
                planning = PlanningTree.load(in: store.root)
                // Reload the open section from disk; the remote may have moved
                // it underneath us.
                let current = selection
                selection = nil
                select(current)
                recountBook()
            }
            syncState = .idle
        } catch {
            syncState = .failed(error.localizedDescription)
        }
    }

    func clearError() {
        if case .failed = syncState { syncState = .idle }
    }

    // MARK: - History

    private func loadHistory(for section: BookSection) {
        Task { [git] in
            let path = section.relativePath
            let prefix = "beckit/\(section.id.uuidString.lowercased())/"

            let revisions = await Task.detached(priority: .utility) { () -> [Revision] in
                let commits = (try? git.history(forPath: path, limit: 200)) ?? []
                let tags = (try? git.tags(withPrefix: prefix)) ?? []

                var versionsByCommit: [GitCommit.ID: SemanticVersion] = [:]
                for tag in tags {
                    guard let version = SemanticVersion(
                        tag.name.split(separator: "/").last ?? "") else { continue }
                    versionsByCommit[tag.commit] = version
                }
                return commits.map {
                    Revision(commit: $0, version: versionsByCommit[$0.id])
                }
            }.value

            guard selection == section.id else { return }  // writer moved on
            history = revisions
        }
    }

    /// Loads a past version into the editor without committing anything, so the
    /// writer can read it, take what they want, and save if they choose to.
    func restore(_ revision: Revision) {
        guard let section = currentSection else { return }
        guard let contents = try? git.contents(of: revision.commit)
        else {
            syncState = .failed("That version could not be read.")
            return
        }
        text = contents
        isDirty = contents != baseline
        documentWordCount = WordCount.count(in: contents)
    }

    func contents(of revision: Revision) -> String? {
        guard let section = currentSection else { return nil }
        return try? git.contents(of: revision.commit)
    }

    // MARK: - Sections

    func displayName(for section: BookSection) -> String {
        guard section.kind == .chapter else {
            return section.title.isEmpty ? "Untitled" : section.title
        }
        let number = book.chapterNumber(of: section.id) ?? 0
        return section.title.isEmpty ? "Chapter \(number)" : "Chapter \(number): \(section.title)"
    }

    @discardableResult
    func addChapter(title: String = "") -> BookSection? {
        let number = book.sections(ofKind: .chapter).count + 1
        let section = BookSection(
            kind: .chapter,
            title: title,
            fileName: store.uniqueFileName(
                for: title.isEmpty ? "Chapter \(number)" : title, in: book))

        // Insert after the last chapter, so back matter stays at the end.
        let index = book.sections.lastIndex { $0.kind == .chapter }
            .map { $0 + 1 }
            ?? book.sections.firstIndex { $0.kind == .backMatter }
            ?? book.sections.count
        book.sections.insert(section, at: index)

        return persistStructure(message: "Add \(displayName(for: section))", section: section)
    }

    @discardableResult
    func addMatter(named name: String, kind: BookSection.Kind) -> BookSection? {
        let section = BookSection(
            kind: kind, title: name, fileName: store.uniqueFileName(for: name, in: book))

        // Slot it into the canonical running order rather than appending.
        let canonical = kind.canonicalSectionNames
        let rank = canonical.firstIndex(of: name) ?? canonical.count
        let peers = book.sections.enumerated().filter { $0.element.kind == kind }
        let index = peers.first {
            (canonical.firstIndex(of: $0.element.title) ?? canonical.count) > rank
        }?.offset
            ?? peers.last.map { $0.offset + 1 }
            ?? (kind == .frontMatter ? 0 : book.sections.count)

        book.sections.insert(section, at: index)
        return persistStructure(message: "Add \(name)", section: section)
    }

    func rename(_ id: BookSection.ID, to title: String) {
        guard var section = book[id], section.title != title else { return }
        section.title = title
        book[id] = section
        // The file keeps its original name on purpose: renaming it would break
        // the git history that the version pane is built from.
        persistStructure(message: "Rename to \(displayName(for: section))", section: nil)
    }

    func delete(_ id: BookSection.ID) {
        guard let section = book[id] else { return }
        let name = displayName(for: section)

        try? store.delete(section)
        book.sections.removeAll { $0.id == id }
        if selection == id {
            selection = nil
            select(book.sections.first?.id)
        }
        persistStructure(message: "Delete \(name)", section: nil)
        recountBook()
    }

    /// Reordering only rewrites the manifest — no files move, so git history
    /// stays attached to every chapter.
    func move(fromOffsets source: IndexSet, toOffset destination: Int, kind: BookSection.Kind) {
        var group = book.sections(ofKind: kind)
        group.move(fromOffsets: source, toOffset: destination)

        var reordered: [BookSection] = []
        var iterator = group.makeIterator()
        for section in book.sections {
            reordered.append(section.kind == kind ? (iterator.next() ?? section) : section)
        }
        book.sections = reordered
        persistStructure(message: "Reorder chapters", section: nil)
    }

    @discardableResult
    private func persistStructure(message: String, section: BookSection?) -> BookSection? {
        do {
            if let section { try store.write("", to: section) }
            try store.save(book)
        } catch {
            syncState = .failed(error.localizedDescription)
            return nil
        }

        var paths = ["book.json"]
        if let section { paths.append(section.relativePath) }
        commitAndPush(message: message, paths: paths, tag: nil,
                      section: section ?? currentSection ?? book.sections[0])
        return section
    }

    // MARK: - Word count

    /// Recounts the whole book off the main actor. A long manuscript is a few
    /// hundred thousand characters of disk reads; the old app did this inline
    /// and dropped frames on every save.
    private func recountBook() {
        wordCountTask?.cancel()
        let store = store
        let sections = book.sections

        wordCountTask = Task {
            let total = await Task.detached(priority: .background) {
                sections.reduce(0) { $0 + WordCount.count(in: store.readIfPresent($1)) }
            }.value
            guard !Task.isCancelled else { return }
            bookWordCount = total
        }
    }

    func refreshPlanning() {
        planning = PlanningTree.load(in: store.root)
    }
}

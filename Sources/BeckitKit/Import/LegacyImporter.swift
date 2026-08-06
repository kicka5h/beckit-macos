import Foundation

/// Converts a Beckit 3.x repository into the git-native layout.
///
/// The old format stored every version as its own directory —
/// `Chapters/Chapter 3/v1.2.0/v1.2.0.md` — so a book carried its entire history
/// as duplicated files in the working tree. Here each section collapses to a
/// single markdown file, and the versions it passed through are replayed as
/// commits so nothing is lost: the history moves from the filesystem into git,
/// where it belongs.
///
/// The importer is deliberately split in two. `plan` inspects the repository
/// and returns exactly what would happen, changing nothing; `apply` performs
/// it. That lets the app show the writer the full conversion before they agree
/// to it, and makes the interesting logic testable without touching a repo.
public enum LegacyImporter {

    // MARK: - Plan

    public struct Plan: Sendable, Equatable {
        public var sections: [PlannedSection]
        /// Directories that will be removed once their contents are collapsed.
        public var directoriesToRemove: [String]
        public var bookTitle: String

        public var isEmpty: Bool { sections.isEmpty }

        /// Every version across every section, oldest first — one commit each.
        public var revisionCount: Int {
            sections.reduce(0) { $0 + $1.revisions.count }
        }
    }

    public struct PlannedSection: Sendable, Equatable {
        public var kind: BookSection.Kind
        public var title: String
        /// Where the collapsed file will live, relative to the repo root.
        public var destination: String
        /// Every version found, oldest first.
        public var revisions: [Revision]

        public var finalVersion: SemanticVersion { revisions.last?.version ?? .initial }
    }

    public struct Revision: Sendable, Equatable {
        public var version: SemanticVersion
        /// Source file in the old layout, relative to the repo root.
        public var source: String
    }

    /// Returns true when `root` looks like a Beckit 3.x book: a `Chapters/`
    /// directory holding at least one `Chapter N/vX.Y.Z/` folder.
    public static func isLegacyRepository(at root: URL) -> Bool {
        guard !BookStore(root: root).hasManifest else { return false }
        let chapters = root.appending(path: BookSection.Kind.chapter.directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: chapters, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return false }
        return entries.contains { !versionDirectories(in: $0).isEmpty }
    }

    public static func plan(at root: URL) throws -> Plan {
        var sections: [PlannedSection] = []
        var removals: [String] = []
        var usedNames: Set<String> = []

        // Front matter, chapters, back matter — in reading order, which is also
        // the order the sections will appear in the new manifest.
        for kind in [BookSection.Kind.frontMatter, .chapter, .backMatter] {
            let directory = root.appending(path: kind.directory)
            guard FileManager.default.fileExists(
                atPath: directory.path(percentEncoded: false)) else { continue }

            let sectionDirectories = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []

            let ordered = order(sectionDirectories, kind: kind)

            for sectionDirectory in ordered {
                let revisions = versionDirectories(in: sectionDirectory)
                    .sorted { $0.version < $1.version }
                    .compactMap { candidate -> Revision? in
                        guard let markdown = markdownFile(in: candidate.url) else { return nil }
                        return Revision(
                            version: candidate.version,
                            source: relativePath(of: markdown, from: root))
                    }
                guard !revisions.isEmpty else { continue }

                let rawName = sectionDirectory.lastPathComponent
                let title = kind == .chapter ? chapterTitle(from: rawName) : rawName

                var fileName = "\(BookStore.slug(title.isEmpty ? rawName : title)).md"
                var suffix = 2
                while usedNames.contains("\(kind.directory)/\(fileName)") {
                    fileName = "\(BookStore.slug(title.isEmpty ? rawName : title))-\(suffix).md"
                    suffix += 1
                }
                let destination = "\(kind.directory)/\(fileName)"
                usedNames.insert(destination)

                sections.append(PlannedSection(
                    kind: kind, title: title, destination: destination, revisions: revisions))
                removals.append(relativePath(of: sectionDirectory, from: root))
            }
        }

        return Plan(
            sections: sections,
            directoriesToRemove: removals,
            bookTitle: root.lastPathComponent)
    }

    // MARK: - Apply

    /// A single step of the conversion. The caller commits after each one so
    /// the writer's version history lands in git as real, dated commits.
    public struct Step: Sendable {
        public var message: String
        /// Destination path → source path to copy from, both relative to the
        /// repository root. Used to lift an old version file into place.
        public var copies: [String: String]
        /// Destination path → literal contents. Used for the manifest.
        public var writes: [String: String]
        /// Paths to delete, relative to the repository root.
        public var deletions: [String]

        public init(
            message: String,
            copies: [String: String] = [:],
            writes: [String: String] = [:],
            deletions: [String] = []
        ) {
            self.message = message
            self.copies = copies
            self.writes = writes
            self.deletions = deletions
        }
    }

    /// Turns a plan into an ordered list of commit-sized steps.
    ///
    /// Version *n* of every section is written before version *n+1* of any of
    /// them, so the resulting history reads as the book growing in passes
    /// rather than one chapter at a time. The final step removes the old
    /// version directories and writes the manifest.
    public static func steps(for plan: Plan, book: Book) throws -> [Step] {
        let depth = plan.sections.map(\.revisions.count).max() ?? 0
        var steps: [Step] = []

        for pass in 0..<depth {
            var copies: [String: String] = [:]
            var versions: [String] = []

            for section in plan.sections where pass < section.revisions.count {
                let revision = section.revisions[pass]
                copies[section.destination] = revision.source
                versions.append("\(section.title) \(revision.version)")
            }
            guard !copies.isEmpty else { continue }

            steps.append(Step(
                message: pass == 0
                    ? "Import: initial versions"
                    : "Import: \(versions.joined(separator: ", "))",
                copies: copies))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifest = String(decoding: try encoder.encode(book), as: UTF8.self) + "\n"

        steps.append(Step(
            message: "Import: collapse version folders into git history",
            writes: ["book.json": manifest],
            deletions: plan.directoriesToRemove))

        return steps
    }

    /// The manifest describing the imported book, at its final versions.
    public static func book(for plan: Plan, author: String = "") -> Book {
        Book(
            title: plan.bookTitle,
            author: author,
            sections: plan.sections.map { planned in
                BookSection(
                    kind: planned.kind,
                    title: planned.title,
                    fileName: URL(filePath: planned.destination).lastPathComponent,
                    version: planned.finalVersion)
            })
    }

    // MARK: - Reading the old layout

    struct VersionDirectory: Sendable, Equatable {
        var version: SemanticVersion
        var url: URL
    }

    /// Every `vX.Y.Z` subdirectory of a chapter or matter folder.
    static func versionDirectories(in sectionDirectory: URL) -> [VersionDirectory] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: sectionDirectory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let version = SemanticVersion(url.lastPathComponent)
            else { return nil }
            return VersionDirectory(version: version, url: url)
        }
    }

    /// The single markdown file inside a version directory. Old repos are
    /// supposed to hold exactly one; if a stray file crept in, the one matching
    /// the directory name wins.
    static func markdownFile(in versionDirectory: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: versionDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        let markdown = entries.filter { $0.pathExtension.lowercased() == "md" }
        if markdown.count <= 1 { return markdown.first }
        let expected = "\(versionDirectory.lastPathComponent).md"
        return markdown.first { $0.lastPathComponent == expected } ?? markdown.first
    }

    /// `Chapter 7` → 7. Returns nil when the name is not a numbered chapter.
    static func chapterNumber(from directoryName: String) -> Int? {
        let lowered = directoryName.lowercased()
        guard lowered.hasPrefix("chapter") else { return nil }
        let rest = lowered.dropFirst("chapter".count).drop(while: \.isWhitespace)
        let digits = rest.prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Any title trailing the chapter number, e.g. `Chapter 3 - The Ferry`.
    static func chapterTitle(from directoryName: String) -> String {
        guard chapterNumber(from: directoryName) != nil else { return directoryName }
        let afterDigits = directoryName.drop { !$0.isNumber }.drop(while: \.isNumber)
        return String(afterDigits.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_:.")))
    }

    private static func order(_ directories: [URL], kind: BookSection.Kind) -> [URL] {
        let existing = directories.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard kind != .chapter else {
            // Chapters sort by their number; anything unnumbered goes last.
            return existing.sorted { lhs, rhs in
                let left = chapterNumber(from: lhs.lastPathComponent) ?? .max
                let right = chapterNumber(from: rhs.lastPathComponent) ?? .max
                if left != right { return left < right }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
                    == .orderedAscending
            }
        }
        // Matter follows the canonical running order, then anything unexpected.
        let canonical = kind.canonicalSectionNames
        return existing.sorted {
            let left = canonical.firstIndex(of: $0.lastPathComponent) ?? canonical.count
            let right = canonical.firstIndex(of: $1.lastPathComponent) ?? canonical.count
            if left != right { return left < right }
            return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
    }
}

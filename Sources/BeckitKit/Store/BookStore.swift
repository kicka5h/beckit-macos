import Foundation

/// Reads and writes a book repository's working tree.
///
/// Deliberately knows nothing about git: it moves bytes between disk and the
/// model, and callers decide when that becomes a commit. Every method is
/// synchronous and `nonisolated` so it can be driven from a background actor.
public struct BookStore: Sendable {
    public let root: URL

    private static let manifestName = "book.json"

    public init(root: URL) {
        self.root = root
    }

    public var manifestURL: URL { root.appending(path: Self.manifestName) }

    public func url(for section: BookSection) -> URL {
        root.appending(path: section.relativePath)
    }

    // MARK: - Manifest

    public func loadBook() throws -> Book {
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        let book = try decoder.decode(Book.self, from: data)
        guard book.schemaVersion <= Book.currentSchemaVersion else {
            throw BookStoreError.manifestTooNew(book.schemaVersion)
        }
        return book
    }

    public func save(_ book: Book) throws {
        let encoder = JSONEncoder()
        // Sorted keys and pretty printing keep the manifest diffable, which is
        // the whole point of putting it under version control.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(book)
        data.append(0x0A)  // trailing newline, so the file is POSIX-clean
        try data.write(to: manifestURL, options: .atomic)
    }

    public var hasManifest: Bool {
        FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false))
    }

    // MARK: - BookSection contents

    public func read(_ section: BookSection) throws -> String {
        let url = url(for: section)
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false))
        else { throw BookStoreError.missingFile(section.relativePath) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a section that may legitimately not exist yet, e.g. immediately
    /// after it was added to the manifest.
    public func readIfPresent(_ section: BookSection) -> String {
        (try? read(section)) ?? ""
    }

    public func write(_ text: String, to section: BookSection) throws {
        let url = url(for: section)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public func delete(_ section: BookSection) throws {
        let url = url(for: section)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Creating a book

    /// Lays out an empty book in an existing (possibly empty) directory.
    @discardableResult
    public func initializeBook(title: String, author: String = "") throws -> Book {
        for kind in BookSection.Kind.allCases {
            try FileManager.default.createDirectory(
                at: root.appending(path: kind.directory), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: root.appending(path: PlanningTree.directoryName),
            withIntermediateDirectories: true)

        var book = Book(title: title, author: author)
        let opening = BookSection(
            kind: .chapter, title: "", fileName: uniqueFileName(for: "Chapter 1", in: book))
        book.sections.append(opening)
        try write("", to: opening)
        try save(book)
        return book
    }

    // MARK: - File naming

    /// Turns a title into a stable, collision-free file name.
    ///
    /// Called once when a section is created. Retitling later does *not* rename
    /// the file — that is what keeps git history attached to the chapter.
    public func uniqueFileName(for title: String, in book: Book) -> String {
        let base = Self.slug(title).isEmpty ? "untitled" : Self.slug(title)
        let taken = Set(book.sections.map(\.fileName))

        var candidate = "\(base).md"
        var suffix = 2
        while taken.contains(candidate)
            || FileManager.default.fileExists(
                atPath: root.appending(path: candidate).path(percentEncoded: false)) {
            candidate = "\(base)-\(suffix).md"
            suffix += 1
        }
        return candidate
    }

    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: .current)
        var result = ""
        var pendingHyphen = false
        for character in folded {
            if character.isLetter || character.isNumber {
                if pendingHyphen, !result.isEmpty { result.append("-") }
                pendingHyphen = false
                result.append(character)
            } else {
                pendingHyphen = true
            }
        }
        return String(result.prefix(60))
    }
}

public enum BookStoreError: Error, LocalizedError, Equatable {
    case missingFile(String)
    case manifestTooNew(Int)
    case notABook(URL)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            "The file \(path) is missing from this book."
        case .manifestTooNew(let version):
            """
            This book was created by a newer version of Beckit \
            (manifest v\(version)). Update Beckit to open it.
            """
        case .notABook(let url):
            "\(url.lastPathComponent) does not contain a Beckit book."
        }
    }
}

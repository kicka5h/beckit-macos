import Foundation

/// The manifest at the root of a book repository (`book.json`).
///
/// Beckit 3.x inferred structure from directory names, which meant reordering a
/// chapter renamed every folder after it and version history restarted from
/// scratch. Here the manifest owns order and titles, so files keep stable names
/// and git keeps following them across a reorder.
public struct Book: Sendable, Codable, Equatable {
    /// Bumped only for changes that older builds cannot read.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var title: String
    public var author: String
    /// Every section of the book in reading order — front matter, chapters and
    /// back matter in one list, because that is the order the PDF wants and the
    /// order the sidebar shows.
    public var sections: [BookSection]

    public init(
        schemaVersion: Int = Book.currentSchemaVersion,
        title: String,
        author: String = "",
        sections: [BookSection] = []
    ) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.author = author
        self.sections = sections
    }

    public func sections(ofKind kind: BookSection.Kind) -> [BookSection] {
        sections.filter { $0.kind == kind }
    }

    public subscript(id: BookSection.ID) -> BookSection? {
        get { sections.first { $0.id == id } }
        set {
            guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
            if let newValue { sections[index] = newValue } else { sections.remove(at: index) }
        }
    }

    /// Chapters numbered by their position among chapters, which is what the
    /// writer sees as "Chapter 7" regardless of how much matter sits in front.
    public func chapterNumber(of id: BookSection.ID) -> Int? {
        sections(ofKind: .chapter).firstIndex { $0.id == id }.map { $0 + 1 }
    }
}

/// One editable document in the book.
public struct BookSection: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case frontMatter, chapter, backMatter

        /// Directory this kind lives in, relative to the repository root.
        public var directory: String {
            switch self {
            case .frontMatter: "FrontMatter"
            case .chapter: "Chapters"
            case .backMatter: "BackMatter"
            }
        }
    }

    public typealias ID = UUID

    public var id: ID
    public var kind: Kind
    /// Display name. For chapters this is the chapter title, shown after the
    /// auto-derived number; it is free to be empty.
    public var title: String
    /// File name within `kind.directory`, including the `.md` extension. Stable
    /// across reorders and retitles so git history survives both.
    public var fileName: String
    public var version: SemanticVersion

    public init(
        id: ID = UUID(),
        kind: Kind,
        title: String,
        fileName: String,
        version: SemanticVersion = .initial
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.fileName = fileName
        self.version = version
    }

    /// Path relative to the repository root, e.g. `Chapters/the-ferry.md`.
    public var relativePath: String { "\(kind.directory)/\(fileName)" }
}

// MARK: - Canonical matter sections

public extension BookSection.Kind {
    /// The conventional running order for matter sections. Offered in the "add
    /// section" menu and used to place a new section sensibly without asking.
    var canonicalSectionNames: [String] {
        switch self {
        case .frontMatter:
            ["Copyright", "Dedication", "Epigraph", "Foreword", "Preface",
             "Prologue", "Acknowledgements"]
        case .backMatter:
            ["Epilogue", "Afterword", "Appendix", "Sources", "Glossary",
             "Index", "Acknowledgements", "About the Author", "Preview",
             "Call to Action"]
        case .chapter:
            []
        }
    }
}

/// Sections whose body is centred on the page in the exported PDF. The source
/// markdown stays plain — this is presentation, applied at render time.
public let centeredMatterSections: Set<String> = ["Dedication", "Epigraph"]

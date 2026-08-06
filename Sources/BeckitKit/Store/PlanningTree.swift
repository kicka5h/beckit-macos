import Foundation

/// The `Planning/` side of the repository: outlines, research, character
/// sheets. Free-form, unversioned, and never part of the exported book.
public enum PlanningTree {
    public static let directoryName = "Planning"

    /// A file or folder under `Planning/`.
    public struct Node: Sendable, Identifiable, Equatable {
        public var id: URL { url }
        public var url: URL
        public var name: String
        public var children: [Node]?

        public var isFolder: Bool { children != nil }
    }

    /// Locates the planning directory, tolerating the lowercase `planning/`
    /// that Beckit 3.x created on case-sensitive filesystems.
    public static func directory(in root: URL) -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        let matches = contents.filter {
            $0.lastPathComponent.lowercased() == directoryName.lowercased()
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        // Prefer the canonical spelling when a repo somehow has both.
        return matches.first { $0.lastPathComponent == directoryName }
            ?? matches.first
            ?? root.appending(path: directoryName)
    }

    /// Builds the tree, folders first then alphabetical, skipping hidden
    /// entries and anything that is not markdown.
    public static func load(in root: URL) -> [Node] {
        children(of: directory(in: root))
    }

    private static func children(of directory: URL) -> [Node] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        var nodes: [Node] = []
        for url in contents {
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                nodes.append(Node(url: url, name: url.lastPathComponent,
                                  children: children(of: url)))
            } else if url.pathExtension.lowercased() == "md" {
                nodes.append(Node(url: url,
                                  name: url.deletingPathExtension().lastPathComponent,
                                  children: nil))
            }
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Mutation

    @discardableResult
    public static func createFile(named name: String, in parent: URL) throws -> URL {
        let fileName = name.hasSuffix(".md") ? name : "\(name).md"
        let url = parent.appending(path: fileName)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return url
        }
        let stem = url.deletingPathExtension().lastPathComponent
        try Data("# \(stem)\n\n".utf8).write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    public static func createFolder(named name: String, in parent: URL) throws -> URL {
        let url = parent.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

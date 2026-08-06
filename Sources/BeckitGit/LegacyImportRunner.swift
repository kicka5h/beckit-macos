import BeckitKit
import Foundation

/// Executes a `LegacyImporter.Plan` against a working tree, one commit per step.
///
/// `LegacyImporter` decides *what* should happen without touching anything;
/// this is the half that moves bytes and makes commits. Keeping them apart is
/// what lets the conversion be shown to the writer in full before they agree
/// to it.
public struct LegacyImportRunner: Sendable {
    public let root: URL
    public let git: any GitRepository

    public init(root: URL, git: any GitRepository) {
        self.root = root
        self.git = git
    }

    public func run(_ steps: [LegacyImporter.Step]) throws {
        for step in steps {
            var paths: [String] = []

            for (destination, source) in step.copies {
                let from = root.appending(path: source)
                let to = root.appending(path: destination)
                try FileManager.default.createDirectory(
                    at: to.deletingLastPathComponent(), withIntermediateDirectories: true)

                // Write the *contents* across rather than copying the file, so
                // the destination keeps its identity from one step to the next
                // and git records each version as a modification of the same
                // file instead of a delete-and-add pair.
                let contents = (try? Data(contentsOf: from)) ?? Data()
                try contents.write(to: to, options: .atomic)
                paths.append(destination)
            }

            for (destination, contents) in step.writes {
                let url = root.appending(path: destination)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url, options: .atomic)
                paths.append(destination)
            }

            for path in step.deletions {
                let url = root.appending(path: path)
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: url)
                }
                paths.append(path)
            }

            try git.commit(message: step.message, paths: paths)
        }
    }
}

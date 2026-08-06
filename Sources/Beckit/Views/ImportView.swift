import BeckitGit
import BeckitKit
import SwiftUI

/// Shown when the folder you opened turns out to be a Beckit 3.x book.
///
/// The conversion is destructive to the old layout, so it is laid out in full
/// before anything happens: what will be collapsed, how many versions become
/// commits, and the fact that older Beckit will no longer read the result.
struct ImportView: View {
    let pending: Library.PendingImport

    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var progress: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            sectionList
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Convert this book")
                .font(.title2.weight(.semibold))

            Text("""
                \(pending.root.lastPathComponent) uses the old version-folder \
                layout. Beckit will collapse each section to a single file and \
                replay its \(pending.plan.revisionCount) versions as git \
                commits, so nothing is lost — the history moves into git rather \
                than sitting in the folder.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "Beckit 3.x will no longer be able to open this book afterwards.",
                systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        .padding(20)
    }

    private var sectionList: some View {
        List(Array(pending.plan.sections.enumerated()), id: \.offset) { _, section in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title.isEmpty ? section.destination : section.title)
                    Text(section.destination)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(section.revisions.count) versions → \(section.finalVersion.description)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            if let failure {
                Label(failure, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let progress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Cancel") { dismiss() }
                .disabled(progress != nil)

            Button("Convert") { convert() }
                .keyboardShortcut(.defaultAction)
                .disabled(progress != nil || pending.plan.isEmpty)
        }
        .padding(20)
    }

    private func convert() {
        progress = "Converting…"
        failure = nil

        Task {
            do {
                let root = pending.root
                let plan = pending.plan
                let book = LegacyImporter.book(for: plan)
                let steps = try LegacyImporter.steps(for: plan, book: book)

                try await Task.detached(priority: .userInitiated) {
                    let git = try Self.repository(at: root)
                    try LegacyImportRunner(root: root, git: git).run(steps)
                }.value

                progress = nil
                dismiss()
                library.open(root)
            } catch {
                progress = nil
                failure = error.localizedDescription
            }
        }
    }

    /// The old layout was always a git clone, but a folder copied off a backup
    /// might not be — so create a repository if there isn't one.
    nonisolated private static func repository(at root: URL) throws -> any GitRepository {
        if let existing = try? SystemGitRepository(root: root) { return existing }
        return try SystemGitRepository.initialize(at: root)
    }
}


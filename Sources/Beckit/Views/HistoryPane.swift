import BeckitKit
import SwiftUI

/// Every commit that touched the open section, with the version it produced.
///
/// In Beckit 3.x this list came from reading version folders off disk. Here it
/// comes from git, so it shows *when* and *who* as well as *what* — and reading
/// an old version costs one object lookup instead of a duplicated file sitting
/// in the working tree forever.
struct HistoryPane: View {
    @Bindable var workspace: Workspace
    @State private var previewing: Workspace.Revision?

    var body: some View {
        Group {
            if workspace.history.isEmpty {
                ContentUnavailableView(
                    "No versions yet",
                    systemImage: "clock",
                    description: Text("Saving this section will record its first version."))
            } else {
                list
            }
        }
        .sheet(item: $previewing) { revision in
            RevisionPreview(
                revision: revision,
                load: { workspace.contents(of: revision) ?? "" },
                onRestore: {
                    workspace.restore(revision)
                    previewing = nil
                })
        }
    }

    private var list: some View {
        List(workspace.history) { revision in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if let version = revision.version {
                        Text(version.description)
                            .font(.callout.monospacedDigit().weight(.medium))
                    } else {
                        Text(revision.commit.shortID)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(revision.commit.date, format: .relative(presentation: .numeric))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(revision.commit.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
            .onTapGesture { previewing = revision }
            .contextMenu {
                Button("Preview…") { previewing = revision }
                Button("Load into Editor") { workspace.restore(revision) }
            }
        }
        .listStyle(.inset)
    }
}

/// Read-only look at a past version, with the option to bring it back.
struct RevisionPreview: View {
    let revision: Workspace.Revision
    /// Reads the version's contents out of git. Deferred rather than passed in:
    /// evaluating it in the sheet's content builder ran `git show` on the main
    /// thread every time SwiftUI rebuilt the sheet.
    let load: () -> String
    let onRestore: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(revision.version?.description ?? revision.commit.shortID)
                        .font(.headline.monospacedDigit())
                    Text("\(revision.commit.authorName) · \(revision.commit.date.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(WordCount.count(in: text).formatted()) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            MarkdownEditor(text: $text, isEditable: false)

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Load into Editor", action: onRestore)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 640, height: 560)
        .task { text = load() }
    }
}

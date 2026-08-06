import BeckitKit
import BeckitPDF
import SwiftUI
import UniformTypeIdentifiers

/// PDF export. Everything happens locally with TextKit — there is no pandoc and
/// no TeX distribution to install, bundle, or have fail on a missing package.
struct ExportView: View {
    @Bindable var workspace: Workspace

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var author = ""
    @State private var destination: URL?
    @State private var includeTitlePage = true
    @State private var includeContents = true
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Book title", text: $title)
                    TextField("Author", text: $author)
                }

                Section {
                    Toggle("Title page", isOn: $includeTitlePage)
                    Toggle("Table of contents", isOn: $includeContents)
                }

                Section {
                    LabeledContent("Save to") {
                        HStack {
                            Text(destination?.lastPathComponent ?? defaultFileName)
                                .foregroundStyle(destination == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose…", action: chooseDestination)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let failure {
                    Label(failure, systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isWorking ? "Generating…" : "Export PDF") { export(open: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
            .padding(16)
        }
        .frame(width: 480)
        .onAppear {
            title = workspace.book.title
            author = workspace.book.author
        }
    }

    private var defaultFileName: String {
        let stem = BookStore.slug(title.isEmpty ? workspace.book.title : title)
        return "\(stem.isEmpty ? "book" : stem).pdf"
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultFileName
        guard panel.runModal() == .OK else { return }
        destination = panel.url
    }

    private func export(open: Bool) {
        isWorking = true
        failure = nil

        let url = destination ?? workspace.store.root.appending(path: defaultFileName)
        let bookTitle = title
        let bookAuthor = author

        // Read every section on the main actor (it owns the model), then hand
        // plain values to a background task to typeset.
        let documents = workspace.book.sections.map { section in
            BookPDFRenderer.Document(
                title: section.kind == .chapter ? section.title : section.title,
                kind: section.kind,
                markdown: workspace.store.readIfPresent(section),
                number: section.kind == .chapter
                    ? workspace.book.chapterNumber(of: section.id)
                    : nil)
        }

        let configuration: BookPDFRenderer.Configuration = {
            var configuration = BookPDFRenderer.Configuration()
            configuration.includeTitlePage = includeTitlePage
            configuration.includeContents = includeContents
            return configuration
        }()

        Task {
            defer { isWorking = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try BookPDFRenderer(configuration: configuration).render(
                        documents: documents,
                        title: bookTitle,
                        author: bookAuthor,
                        to: url)
                }.value

                NSWorkspace.shared.activateFileViewerSelecting([url])
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

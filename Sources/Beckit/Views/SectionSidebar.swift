import BeckitKit
import SwiftUI

/// The book's structure. Front matter, chapters and back matter in reading
/// order, with the planning tree tucked underneath when it is showing.
struct SectionSidebar: View {
    @Bindable var workspace: Workspace
    @Binding var showsPlanning: Bool

    @State private var renaming: BookSection.ID?
    @State private var draftTitle = ""

    var body: some View {
        List(selection: $workspace.selection) {
            matterSection(.frontMatter, title: "Front Matter")
            chapters
            matterSection(.backMatter, title: "Back Matter")

            if showsPlanning {
                Section("Planning") {
                    PlanningOutline(nodes: workspace.planning)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                if let section = workspace.addChapter() { workspace.select(section.id) }
            } label: {
                Label("New Chapter", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.accessoryBar)
            .padding(8)
        }
    }

    private var chapters: some View {
        Section("Chapters") {
            ForEach(workspace.book.sections(ofKind: .chapter)) { section in
                row(for: section)
            }
            .onMove { workspace.move(fromOffsets: $0, toOffset: $1, kind: .chapter) }
        }
    }

    @ViewBuilder
    private func matterSection(_ kind: BookSection.Kind, title: String) -> some View {
        let sections = workspace.book.sections(ofKind: kind)
        let unused = kind.canonicalSectionNames.filter { name in
            !sections.contains { $0.title == name }
        }

        Section {
            ForEach(sections) { row(for: $0) }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Menu {
                    ForEach(unused, id: \.self) { name in
                        Button(name) {
                            if let section = workspace.addMatter(named: name, kind: kind) {
                                workspace.select(section.id)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(unused.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func row(for section: BookSection) -> some View {
        Group {
            if renaming == section.id {
                TextField("Title", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        workspace.rename(section.id, to: draftTitle)
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                HStack(spacing: 6) {
                    Text(workspace.displayName(for: section))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(section.version.description)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .tag(section.id)
        .contextMenu {
            Button("Rename…") {
                draftTitle = section.title
                renaming = section.id
            }
            Divider()
            Button("Delete", role: .destructive) { workspace.delete(section.id) }
        }
    }
}

/// Recursive outline of `Planning/`.
struct PlanningOutline: View {
    let nodes: [PlanningTree.Node]

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup {
                    PlanningOutline(nodes: children)
                } label: {
                    Label(node.name, systemImage: "folder")
                }
            } else {
                Label(node.name, systemImage: "doc.text")
            }
        }
    }
}

import BeckitKit
import SwiftUI

struct RootView: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library

        Group {
            if let workspace = library.workspace {
                BookWindow(workspace: workspace)
            } else {
                WelcomeView()
            }
        }
        .task { await library.restoreSession() }
        .sheet(item: $library.pendingImport, onDismiss: library.openConvertedBook) {
            ImportView(pending: $0)
        }
        .alert(item: $library.error) { error in
            Alert(title: Text("Something went wrong"), message: Text(error.message))
        }
    }
}

/// The writing window: sections on the left, prose in the middle, versions on
/// the right.
struct BookWindow: View {
    @Bindable var workspace: Workspace
    @Environment(Library.self) private var library

    @State private var showsHistory = false
    @State private var showsPlanning = false
    @SceneStorage("sidebarWidth") private var sidebarWidth: Double = 260

    var body: some View {
        NavigationSplitView {
            SectionSidebar(workspace: workspace, showsPlanning: $showsPlanning)
                .navigationSplitViewColumnWidth(
                    min: 200, ideal: sidebarWidth, max: 380)
        } detail: {
            Group {
                if workspace.currentSection != nil {
                    MarkdownEditor(text: $workspace.text) { workspace.textChanged($0) }
                } else {
                    ContentUnavailableView(
                        "No section selected",
                        systemImage: "text.book.closed",
                        description: Text("Pick a chapter on the left, or add a new one."))
                }
            }
            // The pill floats over the prose at the trailing edge, and the
            // inset keeps the text from running underneath it.
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    StatusBar(workspace: workspace)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .inspector(isPresented: $showsHistory) {
                HistoryPane(workspace: workspace)
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
            }
        }
        .navigationTitle(workspace.book.title)
        .navigationSubtitle(workspace.currentSection.map(workspace.displayName) ?? "")
        .toolbar { toolbar }
        .sheet(isPresented: Bindable(library).isExporting) {
            ExportView(workspace: workspace)
        }
    }

    // Toolbar items sit in glass capsules that group adjacent items together.
    // `ToolbarSpacer(.fixed)` breaks the run, so actions that *do* something to
    // the book read as one control and the view toggles as another, instead of
    // all four running together in a single undifferentiated capsule.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Read once. Toolbar content is rebuilt often, and every read of
        // workspace state from here happens inside SwiftUI's update pass.
        let hasRemote = workspace.hasRemote

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.saveNow()
            } label: {
                Label("Save Version", systemImage: "arrow.down.document")
            }
            .disabled(!workspace.isDirty)
            .help("Write a new version and push it to GitHub")

            Button {
                Task { await workspace.pull() }
            } label: {
                Label("Sync", systemImage: "arrow.trianglehead.2.clockwise")
            }
            .disabled(!hasRemote)
            .help(hasRemote
                ? "Pull the latest changes from GitHub"
                : "This book is not connected to GitHub")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $showsPlanning) {
                Label("Planning", systemImage: "list.bullet.clipboard")
            }
            .help("Show planning notes")

            Toggle(isOn: $showsHistory) {
                Label("Versions", systemImage: "clock.arrow.circlepath")
            }
            .help("Show version history")
        }
    }
}

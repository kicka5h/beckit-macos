import BeckitKit
import SwiftUI

@main
struct BeckitApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { BeckitCommands(library: library) }

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}

struct BeckitCommands: Commands {
    let library: Library

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chapter") { library.workspace?.addChapter() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(library.workspace == nil)

            Button("Open Book…") { library.promptToOpenBook() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Version") { library.workspace?.saveNow() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(library.workspace?.isDirty != true)

            Button("Sync with GitHub") {
                Task { await library.workspace?.pull() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(library.workspace == nil)

            Divider()

            Button("Export PDF…") { library.isExporting = true }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(library.workspace == nil)
        }
    }
}

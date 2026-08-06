import BeckitKit
import SwiftUI

/// Word counts, unsaved state, and whatever sync is doing — the quiet strip a
/// writer glances at without looking away from the prose.
struct StatusBar: View {
    @Bindable var workspace: Workspace

    var body: some View {
        HStack(spacing: 12) {
            if workspace.isDirty {
                Label("Unsaved", systemImage: "circle.fill")
                    .labelStyle(DotLabelStyle())
                    .foregroundStyle(.orange)
            }

            if let version = workspace.currentSection?.version {
                Text(version.description)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if let message = workspace.syncState.message {
                syncIndicator(message)
            }

            Text("\(workspace.documentWordCount.formatted()) words")
                .monospacedDigit()
            Text("·").foregroundStyle(.quaternary)
            Text("\(workspace.bookWordCount.formatted()) in book")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder
    private func syncIndicator(_ message: String) -> some View {
        if case .failed = workspace.syncState {
            Button {
                workspace.clearError()
            } label: {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("\(message) — click to dismiss")
        } else {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(message)
            }
            .transition(.opacity)
        }
    }
}

/// A small filled dot instead of a full-size SF Symbol, so the unsaved marker
/// sits at the same visual weight as the text beside it.
private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}

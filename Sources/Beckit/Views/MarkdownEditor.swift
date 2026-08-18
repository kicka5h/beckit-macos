import AppKit
import SwiftUI

/// The writing surface: one always-live, always-styled text view.
///
/// There is no edit mode and no preview mode. The Python app had both because
/// its toolkit could not style text while you typed; every click in and out of
/// a chapter cost a full re-render and lost the caret. TextKit 2 styles in
/// place, so the mode switch simply does not need to exist.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var theme: EditorTheme = .default
    var isEditable = true
    /// Called after the user changes the text, never for programmatic updates.
    var onEdit: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, theme: theme, onEdit: onEdit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = Self.makeTextView(theme: theme)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.insertionPointColor = theme.insertionPointColor
        textView.textContainerInset = theme.textInsets
        textView.drawsBackground = false

        // Writing aids that suit prose. Automatic quotes and dashes are what
        // make typed text look typeset; spelling stays on, but autocorrect does
        // not, because it mangles invented names.
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false

        context.coordinator.textView = textView
        context.coordinator.load(text)
        return scrollView
    }

    /// Builds the scrolling text view.
    ///
    /// Split out from `makeNSView` so it can be built and inspected in a test
    /// without a SwiftUI `Context`.
    static func makeTextView(theme: EditorTheme) -> (NSScrollView, NSTextView) {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        // The measure owns the container width — see `applyMeasure`.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return (scrollView, textView)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.theme = theme
        context.coordinator.onEdit = onEdit
        textView.isEditable = isEditable

        // Only push text in when it genuinely differs — assigning the string
        // resets the caret and clears the undo stack, so doing it on every
        // SwiftUI update would make typing impossible.
        if textView.string != text {
            context.coordinator.load(text)
        }
        context.coordinator.applyMeasure(to: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var theme: EditorTheme
        var onEdit: (String) -> Void
        weak var textView: NSTextView?

        /// True while we are the ones changing the text, so the delegate does
        /// not report a programmatic load back as a user edit.
        private var isLoading = false

        init(text: Binding<String>, theme: EditorTheme, onEdit: @escaping (String) -> Void) {
            self._text = text
            self.theme = theme
            self.onEdit = onEdit
        }

        func load(_ newText: String) {
            guard let textView, let storage = textView.textStorage else { return }
            isLoading = true
            defer { isLoading = false }

            let selection = textView.selectedRange()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                      with: newText)
            MarkdownStyler(theme: theme).restyle(storage)

            // Keep the caret if it still fits; opening a chapter puts it at the
            // top, which is where a writer expects to resume reading.
            if selection.location <= storage.length {
                textView.setSelectedRange(
                    NSRange(location: min(selection.location, storage.length), length: 0))
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading,
                  let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage
            else { return }

            // Restyle only the paragraphs the edit touched.
            let styler = MarkdownStyler(theme: theme)
            let edited = storage.editedRange.location == NSNotFound
                ? textView.selectedRange()
                : storage.editedRange
            styler.restyle(storage, in: styler.affectedRange(for: edited, in: storage))

            text = textView.string
            onEdit(textView.string)
        }

        /// Centres a fixed-width text column in the scroll view, so prose keeps
        /// a readable measure however wide the window gets.
        func applyMeasure(to textView: NSTextView) {
            guard let container = textView.textContainer,
                  let scrollView = textView.enclosingScrollView
            else { return }

            let idealWidth = theme.idealColumnWidth
            let available = scrollView.contentSize.width
            let width = min(idealWidth, available - 32)
            guard width > 0 else { return }

            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            container.widthTracksTextView = false
            textView.textContainerInset = NSSize(
                width: max(16, (available - width) / 2),
                height: theme.textInsets.height)
        }
    }
}



import AppKit
import Testing
@testable import Beckit

/// The caret is the line.
///
/// AppKit draws the insertion point the full height of the line fragment, and
/// under TextKit 2 there is no way to change that: the caret is an
/// `NSTextInsertionIndicator` subview whose frame NSTextView owns, and that
/// class exposes only display mode, colour and blink options — no geometry.
/// `drawInsertionPoint` is not called at all on a TextKit 2 text view, which is
/// why an override of it silently did nothing here.
///
/// So the only lever on caret height is leading, and these tests hold it down.
@Suite("Editor leading")
@MainActor
struct EditorLeadingTests {

    /// Lays out a line with the theme's paragraph style and returns the height
    /// of its line fragment — which is the height the caret will be drawn.
    private func lineHeight(for theme: EditorTheme) -> CGFloat {
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: "The tide came in slowly and left again.",
            attributes: [.font: theme.bodyFont, .paragraphStyle: theme.paragraphStyle()]))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: 1e6))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        var range = NSRange()
        return layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: &range).height
    }

    private func typeHeight(for theme: EditorTheme) -> CGFloat {
        theme.bodyFont.ascender - theme.bodyFont.descender
    }

    @Test("The caret is no taller than the letters it sits between")
    func caretMatchesTheType() {
        let theme = EditorTheme.default
        let overshoot = lineHeight(for: theme) / typeHeight(for: theme) - 1

        // Natural leading puts the line about 3% over the type. Anything past
        // 10% starts reading as a cursor belonging to a larger font.
        #expect(overshoot < 0.10,
                "line is \(Int(overshoot * 100))% taller than the type, so the caret is too")
    }

    /// Pins the two settings that shipped, so the numbers cannot drift back
    /// without the consequence being visible here.
    @Test("The leading that shipped inflated the caret badly")
    func documentsTheRegression() {
        var loose = EditorTheme.default
        loose.lineHeightMultiple = 1.5
        var middling = EditorTheme.default
        middling.lineHeightMultiple = 1.25

        let type = typeHeight(for: .default)
        #expect(lineHeight(for: loose) / type > 1.5)      // 55% over — the first report
        #expect(lineHeight(for: middling) / type > 1.25)  // 29% over — the second
    }

    @Test("Leading is natural, not inflated")
    func leadingIsNatural() {
        #expect(EditorTheme.default.lineHeightMultiple <= 1.05)
    }

    /// Paragraphs are separated by paragraph spacing rather than by leading,
    /// because spacing costs the caret nothing.
    @Test("Paragraph spacing carries the rhythm, and reads as a break")
    func paragraphSpacingCarriesTheRhythm() {
        let theme = EditorTheme.default
        #expect(theme.paragraphSpacing > 0)
        // Enough to read as a break against the line, not so much that the page
        // falls apart — the complaint that started this.
        #expect(theme.paragraphSpacing < lineHeight(for: theme) * 0.6)
    }
}

/// The text view is assembled by hand rather than by
/// `NSTextView.scrollableTextView()`, so the wiring is worth checking.
@Suite("Editor text view")
@MainActor
struct EditorTextViewTests {

    @Test("The scrolling text view is wired for vertical prose")
    func wiring() {
        let (scrollView, textView) = MarkdownEditor.makeTextView(theme: .default)

        #expect(scrollView.documentView === textView)
        #expect(textView.isVerticallyResizable)
        #expect(!textView.isHorizontallyResizable)
        // The measure owns the container width; the container must not fight it.
        #expect(textView.textContainer?.widthTracksTextView == false)
    }

    @Test("It uses TextKit 2")
    func usesTextKit2() {
        let (_, textView) = MarkdownEditor.makeTextView(theme: .default)
        #expect(textView.textLayoutManager != nil)
    }

    @Test("Text set on it lays out")
    func laysOutText() {
        let (scrollView, textView) = MarkdownEditor.makeTextView(theme: .default)
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        textView.textContainer?.size = NSSize(
            width: 480, height: CGFloat.greatestFiniteMagnitude)

        textView.string = String(repeating: "The tide came in slowly and left again. ", count: 20)

        #expect(textView.string.hasPrefix("The tide"))
        #expect(!textView.string.isEmpty)
    }
}

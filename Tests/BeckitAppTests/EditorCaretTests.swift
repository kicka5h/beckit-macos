import AppKit
import Testing
@testable import Beckit

/// The caret used to be drawn the full height of the line fragment, which with
/// prose leading made it markedly taller than the letters around it.
@Suite("Editor caret")
@MainActor
struct EditorCaretTests {

    private let font = NSFont.systemFont(ofSize: 14)

    /// The height of the type itself — what the caret should match.
    private var typeHeight: CGFloat { (font.ascender - font.descender).rounded() }

    @Test("The caret is the height of the type, not of the line")
    func caretMatchesTheType() {
        // A 14pt line with the theme's leading; the fragment is taller than the
        // typeface by the leading.
        let fragment = NSRect(x: 10, y: 100, width: 1, height: 21)
        let caret = ProseTextView.caretRect(inFragment: fragment, font: font)

        #expect(caret.height == typeHeight)
        #expect(caret.height < fragment.height)
    }

    @Test("The caret is centred in the line")
    func caretIsCentred() {
        let fragment = NSRect(x: 10, y: 100, width: 1, height: 21)
        let caret = ProseTextView.caretRect(inFragment: fragment, font: font)

        let above = caret.minY - fragment.minY
        let below = fragment.maxY - caret.maxY
        #expect(abs(above - below) <= 1, "the caret should sit evenly in the line")
    }

    @Test("A line with no extra leading is left alone")
    func tightLineIsUnchanged() {
        // Nothing to trim when the fragment is already the height of the type.
        let fragment = NSRect(x: 0, y: 0, width: 1, height: typeHeight)
        #expect(ProseTextView.caretRect(inFragment: fragment, font: font) == fragment)
    }

    @Test("The caret keeps its position and width")
    func geometryIsPreserved() {
        let fragment = NSRect(x: 42, y: 100, width: 2, height: 25)
        let caret = ProseTextView.caretRect(inFragment: fragment, font: font)
        #expect(caret.minX == fragment.minX)
        #expect(caret.width == fragment.width)
    }

    /// At the leading that shipped, the caret overshot the type by half its own
    /// height above and below. This pins how far off that was, so the numbers
    /// in `EditorTheme` cannot drift back without the reason being visible.
    @Test("The shipped leading made the caret half again as tall as the type")
    func documentsTheRegression() {
        let theme = EditorTheme.default
        let shippedFragment = (14 * 1.5 * 1.21).rounded()   // 14pt at the old 1.5 multiple
        let caret = ProseTextView.caretRect(
            inFragment: NSRect(x: 0, y: 0, width: 1, height: shippedFragment), font: font)

        #expect(shippedFragment > typeHeight * 1.4)
        #expect(caret.height == typeHeight)
        #expect(theme.lineHeightMultiple < 1.4, "leading is what inflates the caret")
    }
}

/// The text view is now assembled by hand rather than by
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

    @Test("Text set on it lays out")
    func laysOutText() {
        let (scrollView, textView) = MarkdownEditor.makeTextView(theme: .default)
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        textView.textContainer?.size = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)

        textView.string = String(repeating: "The tide came in slowly and left again. ", count: 20)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        #expect(textView.string.hasPrefix("The tide"))
        #expect(!textView.string.isEmpty)
    }

    @Test("It falls back to the theme's face when the caret sits on unstyled text")
    func fallbackFont() {
        let (_, textView) = MarkdownEditor.makeTextView(theme: .default)
        #expect(textView.fallbackFont.fontName == EditorTheme.default.bodyFont.fontName)
    }
}

import AppKit
import Testing
@testable import Beckit

/// Guards the two things that were wrong with the writing surface's type.
@Suite("Editor typography")
@MainActor
struct EditorThemeTests {

    @Test("Body text is set in the same face as the rest of the app")
    func bodyMatchesTheApp() {
        let theme = EditorTheme.default
        #expect(theme.bodyFont.fontName == NSFont.systemFont(ofSize: theme.bodySize).fontName,
                "prose was set in New York, which read as a different app from its own chrome")
    }

    @Test("Headings match the body face")
    func headingsMatchBody() {
        let theme = EditorTheme.default
        for level in 1...4 {
            let heading = theme.heading(level: level)
            #expect(heading.fontName
                == NSFont.systemFont(ofSize: heading.pointSize, weight: .semibold).fontName)
        }
    }

    /// The regression that mattered most, because it was silent: the column was
    /// sized with `maximumAdvancement`, the widest glyph in the font, which put
    /// the ideal width past any real window. It always lost the `min` against
    /// the available width, so prose ran edge to edge however wide the display
    /// and the measure never did anything.
    @Test("A line is a readable measure, not the width of the window")
    func columnIsAReadableMeasure() {
        let theme = EditorTheme.default

        // 45–75 characters is the usual range for continuous prose; the theme
        // asks for 68, so the column should be about that many characters wide
        // and nowhere near a full-screen window.
        #expect(theme.idealColumnWidth > 380)
        #expect(theme.idealColumnWidth < 640)

        // Sizing off the widest glyph is what broke it. Assert the two are not
        // the same, so reintroducing it fails here rather than in the window.
        let widestGlyphWidth = theme.measure * theme.bodyFont.maximumAdvancement.width
        #expect(widestGlyphWidth > theme.idealColumnWidth * 1.5)
    }

    @Test("Body type is sized for reading, not for an accessibility setting")
    func bodyIsNotOversized() {
        #expect(EditorTheme.default.bodySize <= 15)
    }

    @Test("Paragraph spacing scales with the type")
    func spacingFollowsSize() {
        var small = EditorTheme.default
        small.bodySize = 12
        var large = EditorTheme.default
        large.bodySize = 24
        #expect(large.paragraphSpacing > small.paragraphSpacing)
    }
}

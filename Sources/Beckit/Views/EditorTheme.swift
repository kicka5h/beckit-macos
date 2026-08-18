import AppKit
import SwiftUI

/// Typography and colour for the writing surface.
///
/// The old app rendered a styled *preview* and swapped in a plain text box when
/// you clicked, because its toolkit could not style text as you typed. Here
/// there is one surface that is always both, so this theme has to work for
/// reading and for editing at the same time: syntax marks are dimmed rather
/// than hidden, and nothing reflows when the caret arrives.
struct EditorTheme: Sendable {
    var bodySize: CGFloat = 14
    var lineHeightMultiple: CGFloat = 1.5
    /// Measure, in characters. Prose is unreadable across a 27-inch display, so
    /// the text column stays narrow and centred no matter how wide the window.
    var measure: CGFloat = 68

    static let `default` = EditorTheme()

    /// The same face as the rest of the app — the system font. Prose used to be
    /// set in New York, the system serif, which read as a different application
    /// from the one around it.
    var bodyFont: NSFont {
        .systemFont(ofSize: bodySize)
    }

    /// Space between paragraphs, in proportion to the type. Fixed values look
    /// right at one size and wrong at every other.
    var paragraphSpacing: CGFloat { (bodySize * 0.6).rounded() }

    /// Width of one character of body text, averaged across the lowercase
    /// alphabet.
    ///
    /// Not `maximumAdvancement`, which is the *widest* glyph in the font and
    /// close to double the average for a proportional face. Sizing the column
    /// with it made the ideal width about 1150pt, which always lost against the
    /// available width — so the measure never applied and prose ran the full
    /// width of the window however wide it got.
    var averageCharacterWidth: CGFloat {
        let sample = "abcdefghijklmnopqrstuvwxyz" as NSString
        return sample.size(withAttributes: [.font: bodyFont]).width
            / CGFloat(sample.length)
    }

    /// How wide the text column wants to be: `measure` characters of body text.
    var idealColumnWidth: CGFloat { measure * averageCharacterWidth }

    func heading(level: Int) -> NSFont {
        let scale: CGFloat = switch level {
        case 1: 1.6
        case 2: 1.35
        case 3: 1.18
        default: 1.06
        }
        let size = (bodySize * scale).rounded()
        return .systemFont(ofSize: size, weight: .semibold)
    }

    var monospaceFont: NSFont {
        .monospacedSystemFont(ofSize: bodySize - 2, weight: .regular)
    }

    func emphasised(_ font: NSFont, italic: Bool, bold: Bool) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        if italic { traits.insert(.italic) }
        if bold { traits.insert(.bold) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: - Colour

    /// Slightly warmer and softer than pure label colour; long sessions on a
    /// bright display are easier when the text is not maximum contrast.
    var textColor: NSColor { .textColor.withAlphaComponent(0.92) }
    /// Markdown punctuation: present, so the writer can see and edit it, but
    /// receded so it does not compete with the prose.
    var syntaxColor: NSColor { .tertiaryLabelColor }
    var quoteColor: NSColor { .secondaryLabelColor }
    var linkColor: NSColor { .linkColor }
    var insertionPointColor: NSColor { .controlAccentColor }

    var textInsets: NSSize { NSSize(width: 0, height: 28) }

    func paragraphStyle(
        firstLineIndent: CGFloat = 0, headIndent: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = paragraphSpacing
        style.firstLineHeadIndent = firstLineIndent
        style.headIndent = headIndent
        return style
    }
}

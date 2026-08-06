import AppKit
import BeckitKit
import Foundation

/// Turns a section's markdown into styled text with book typography.
///
/// Block structure (headings, paragraphs, quotes, rules) is handled here so the
/// paragraph styles can be right for print — first-line indents, no space
/// between paragraphs, widow and orphan control. Inline formatting is handed to
/// Foundation's markdown parser, which already gets emphasis and links right.
struct MarkdownLayout {
    let configuration: BookPDFRenderer.Configuration

    private var bodyFont: NSFont {
        NSFont(name: configuration.bodyFontName, size: configuration.bodyFontSize)
            ?? .systemFont(ofSize: configuration.bodyFontSize)
    }

    private func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let descriptor = bodyFont.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    // MARK: - Named styles

    var titlePageTitle: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return [.font: font(size: 30, weight: .medium), .paragraphStyle: paragraph]
    }

    var titlePageAuthor: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return [.font: font(size: 14), .paragraphStyle: paragraph]
    }

    var contentsHeading: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = configuration.bodyFontSize
        return [.font: font(size: 20, weight: .medium), .paragraphStyle: paragraph]
    }

    var contentsEntry: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        // A right-aligned tab stop at the text edge produces the page-number
        // column without hand-measuring anything.
        paragraph.tabStops = [
            NSTextTab(textAlignment: .right, location: configuration.textWidth)
        ]
        return [.font: bodyFont, .paragraphStyle: paragraph]
    }

    var pageNumber: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return [
            .font: font(size: configuration.bodyFontSize - 2),
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.black.withAlphaComponent(0.65),
        ]
    }

    func displayTitle(for document: BookPDFRenderer.Document) -> String {
        guard let number = document.number else { return document.title }
        return document.title.isEmpty
            ? "Chapter \(number)"
            : "Chapter \(number): \(document.title)"
    }

    // MARK: - Section rendering

    func attributedString(for document: BookPDFRenderer.Document) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let centered = centeredMatterSections.contains(document.title)

        let heading = displayTitle(for: document)
        if !heading.isEmpty {
            result.append(NSAttributedString(
                string: heading + "\n", attributes: chapterOpener))
        }

        var isFirstParagraph = true
        for block in MarkdownBlock.parse(document.markdown) {
            switch block {
            case .heading(let level, let text):
                result.append(inline(text, attributes: headingStyle(level: level)))
                result.append(NSAttributedString(string: "\n"))
                isFirstParagraph = true

            case .paragraph(let text):
                // The opening paragraph of a section is set flush left; every
                // one after it is indented. This is standard book setting and
                // the single clearest signal that the PDF was typeset rather
                // than printed from a word processor.
                let style = centered
                    ? centeredBody
                    : bodyStyle(indented: !isFirstParagraph)
                result.append(inline(text, attributes: style))
                result.append(NSAttributedString(string: "\n"))
                isFirstParagraph = false

            case .quote(let text):
                result.append(inline(text, attributes: quoteStyle))
                result.append(NSAttributedString(string: "\n"))
                isFirstParagraph = true

            case .listItem(let text, let ordinal):
                let marker = ordinal.map { "\($0). " } ?? "•\t"
                result.append(inline(marker + text, attributes: listStyle))
                result.append(NSAttributedString(string: "\n"))
                isFirstParagraph = true

            case .rule:
                let separator = NSMutableParagraphStyle()
                separator.alignment = .center
                separator.paragraphSpacingBefore = configuration.bodyFontSize
                separator.paragraphSpacing = configuration.bodyFontSize
                result.append(NSAttributedString(
                    string: "\u{2042}\n",
                    attributes: [.font: bodyFont, .paragraphStyle: separator]))
                isFirstParagraph = true

            case .codeBlock(let text):
                result.append(NSAttributedString(string: text + "\n", attributes: codeStyle))
                isFirstParagraph = true
            }
        }
        return result
    }

    /// Parses inline markdown (emphasis, links) and applies the block's style
    /// underneath, so bold inside a heading stays bold *and* stays heading-sized.
    private func inline(
        _ markdown: String, attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)

        let result = NSMutableAttributedString(parsed)
        let whole = NSRange(location: 0, length: result.length)

        // Apply block attributes first, then re-apply the traits the inline
        // parser found, so neither one erases the other.
        result.enumerateAttribute(.font, in: whole) { value, range, _ in
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var attributes = attributes
            if let base = attributes[.font] as? NSFont, !traits.isEmpty {
                let merged = base.fontDescriptor.withSymbolicTraits(
                    base.fontDescriptor.symbolicTraits.union(traits))
                attributes[.font] = NSFont(descriptor: merged, size: base.pointSize) ?? base
            }
            result.addAttributes(attributes, range: range)
        }
        return result
    }

    // MARK: - Block styles

    private var chapterOpener: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = configuration.bodyFontSize * 2
        paragraph.paragraphSpacingBefore = configuration.bodyFontSize * 2
        return [.font: font(size: configuration.bodyFontSize + 8, weight: .medium),
                .paragraphStyle: paragraph]
    }

    private func headingStyle(level: Int) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = configuration.bodyFontSize * 1.2
        paragraph.paragraphSpacing = configuration.bodyFontSize * 0.4
        let bump: CGFloat = switch level {
        case 1: 6
        case 2: 4
        case 3: 2
        default: 0
        }
        return [.font: font(size: configuration.bodyFontSize + bump, weight: .semibold),
                .paragraphStyle: paragraph]
    }

    private func bodyStyle(indented: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.28
        paragraph.alignment = .justified
        paragraph.hyphenationFactor = 0.9
        paragraph.firstLineHeadIndent = indented ? configuration.bodyFontSize * 1.5 : 0
        return [.font: bodyFont, .paragraphStyle: paragraph]
    }

    private var centeredBody: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.28
        paragraph.alignment = .center
        return [.font: bodyFont, .paragraphStyle: paragraph]
    }

    private var quoteStyle: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        paragraph.headIndent = configuration.bodyFontSize * 2
        paragraph.firstLineHeadIndent = configuration.bodyFontSize * 2
        paragraph.tailIndent = -configuration.bodyFontSize * 2
        paragraph.paragraphSpacingBefore = configuration.bodyFontSize * 0.6
        paragraph.paragraphSpacing = configuration.bodyFontSize * 0.6
        let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
        return [.font: italic, .paragraphStyle: paragraph]
    }

    private var listStyle: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        paragraph.headIndent = configuration.bodyFontSize * 2
        paragraph.firstLineHeadIndent = configuration.bodyFontSize
        paragraph.tabStops = [
            NSTextTab(textAlignment: .left, location: configuration.bodyFontSize * 2)
        ]
        return [.font: bodyFont, .paragraphStyle: paragraph]
    }

    private var codeStyle: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = configuration.bodyFontSize
        paragraph.firstLineHeadIndent = configuration.bodyFontSize
        paragraph.paragraphSpacingBefore = configuration.bodyFontSize * 0.5
        paragraph.paragraphSpacing = configuration.bodyFontSize * 0.5
        return [
            .font: NSFont.monospacedSystemFont(
                ofSize: configuration.bodyFontSize - 1, weight: .regular),
            .paragraphStyle: paragraph,
        ]
    }
}

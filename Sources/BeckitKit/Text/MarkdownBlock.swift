import Foundation

/// Block-level structure of a markdown document.
///
/// Deliberately small: Beckit is a prose editor, so this understands the
/// constructs a novelist actually types and treats everything else as a
/// paragraph. Inline formatting is left alone here — consumers hand the text to
/// Foundation's markdown parser, which already handles emphasis and links.
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case quote(String)
    /// `ordinal` is nil for a bulleted item.
    case listItem(text: String, ordinal: Int?)
    case rule
    case codeBlock(String)

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        var quote: [Substring] = []
        var code: [Substring] = []
        var inCodeFence = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(joined(paragraph)))
            paragraph.removeAll(keepingCapacity: true)
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(joined(quote)))
            quote.removeAll(keepingCapacity: true)
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
        }

        for line in markdown.lines {
            let trimmed = line.trimmingPrefix(while: { $0 == " " })

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCodeFence {
                    blocks.append(.codeBlock(code.joined(separator: "\n")))
                    code.removeAll(keepingCapacity: true)
                } else {
                    flushAll()
                }
                inCodeFence.toggle()
                continue
            }
            if inCodeFence {
                code.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }

            if isThematicBreak(trimmed) {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if trimmed.first == "#" {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let rest = trimmed.dropFirst(level)
                if level <= 6, rest.first == " " || rest.isEmpty {
                    flushAll()
                    blocks.append(.heading(
                        level: level,
                        text: String(rest.trimmingCharacters(in: .whitespaces))))
                    continue
                }
            }

            if trimmed.first == ">" {
                flushParagraph()
                quote.append(trimmed.dropFirst().trimmingPrefix(while: { $0 == " " }))
                continue
            }

            if let item = listItem(in: trimmed) {
                flushAll()
                blocks.append(item)
                continue
            }

            flushQuote()
            paragraph.append(trimmed)
        }

        if inCodeFence, !code.isEmpty {
            blocks.append(.codeBlock(code.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    // MARK: - Line classification

    /// Three or more `-`, `*` or `_` with nothing else on the line.
    private static func isThematicBreak(_ line: some StringProtocol) -> Bool {
        guard let marker = line.first, "-*_".contains(marker) else { return false }
        let significant = line.filter { !$0.isWhitespace }
        return significant.count >= 3 && significant.allSatisfy { $0 == marker }
    }

    private static func listItem(in line: some StringProtocol) -> MarkdownBlock? {
        if let marker = line.first, "-*+".contains(marker),
           line.dropFirst().first == " " {
            return .listItem(
                text: String(line.dropFirst().trimmingCharacters(in: .whitespaces)),
                ordinal: nil)
        }

        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, let ordinal = Int(digits) {
            let after = line.dropFirst(digits.count)
            if after.first == "." || after.first == ")", after.dropFirst().first == " " {
                return .listItem(
                    text: String(after.dropFirst().trimmingCharacters(in: .whitespaces)),
                    ordinal: ordinal)
            }
        }
        return nil
    }

    /// Soft-wrapped lines within one paragraph rejoin with spaces, which is how
    /// markdown treats them and how the PDF should set them.
    private static func joined(_ lines: [Substring]) -> String {
        lines.joined(separator: " ")
    }
}

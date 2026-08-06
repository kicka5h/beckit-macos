import AppKit
import Foundation

/// Applies markdown styling directly to the text storage as the writer types.
///
/// The performance rule here is that a keystroke must never restyle the whole
/// document. `restyle(in:)` is given the *paragraph range* around an edit and
/// touches nothing else, so cost is proportional to the paragraph being typed
/// in rather than to the length of the chapter. A 120,000-word manuscript costs
/// the same per keystroke as an empty one.
struct MarkdownStyler {
    var theme: EditorTheme

    /// Restyles the paragraphs covering `range`. Pass nil for the whole thing,
    /// which should only happen on load.
    func restyle(_ storage: NSTextStorage, in range: NSRange? = nil) {
        let target = storage.mutableString.paragraphRange(
            for: range ?? NSRange(location: 0, length: storage.length))

        storage.beginEditing()
        defer { storage.endEditing() }

        // Reset to body style, then let the block and inline passes layer on
        // top. Cheaper and far less error-prone than trying to undo whatever
        // the previous content was.
        storage.setAttributes([
            .font: theme.bodyFont,
            .foregroundColor: theme.textColor,
            .paragraphStyle: theme.paragraphStyle(),
        ], range: target)

        storage.mutableString.enumerateSubstrings(
            in: target, options: [.byParagraphs]
        ) { substring, paragraphRange, _, _ in
            guard let substring else { return }
            styleBlock(substring, at: paragraphRange, in: storage)
            styleInline(substring, at: paragraphRange, in: storage)
        }
    }

    /// The paragraph range containing an edit, widened to cover the edit's full
    /// extent. Used by the text view to scope `restyle` after a change.
    func affectedRange(for edited: NSRange, in storage: NSTextStorage) -> NSRange {
        storage.mutableString.paragraphRange(for: edited)
    }

    // MARK: - Block level

    private func styleBlock(_ line: String, at range: NSRange, in storage: NSTextStorage) {
        let trimmed = line.drop(while: { $0 == " " })
        let leading = line.count - trimmed.count

        if trimmed.first == "#" {
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            guard hashes <= 6, trimmed.dropFirst(hashes).first == " " else { return }

            storage.addAttribute(
                .font, value: theme.heading(level: hashes), range: range)
            // Dim the `##` itself so the heading reads as a heading, but stays
            // editable in place.
            storage.addAttribute(
                .foregroundColor, value: theme.syntaxColor,
                range: NSRange(location: range.location + leading, length: hashes))
            return
        }

        if trimmed.first == ">" {
            storage.addAttributes([
                .font: theme.emphasised(theme.bodyFont, italic: true, bold: false),
                .foregroundColor: theme.quoteColor,
                .paragraphStyle: theme.paragraphStyle(
                    firstLineIndent: theme.bodySize, headIndent: theme.bodySize),
            ], range: range)
            return
        }

        if isListMarker(trimmed) {
            storage.addAttribute(
                .paragraphStyle,
                value: theme.paragraphStyle(headIndent: theme.bodySize * 1.4),
                range: range)
            storage.addAttribute(
                .foregroundColor, value: theme.syntaxColor,
                range: NSRange(location: range.location + leading, length: 1))
            return
        }

        if isThematicBreak(trimmed) {
            storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: range)
        }
    }

    private func isListMarker(_ line: some StringProtocol) -> Bool {
        guard let first = line.first else { return false }
        return "-*+".contains(first) && line.dropFirst().first == " "
    }

    private func isThematicBreak(_ line: some StringProtocol) -> Bool {
        guard let marker = line.first, "-*_".contains(marker) else { return false }
        let significant = line.filter { !$0.isWhitespace }
        return significant.count >= 3 && significant.allSatisfy { $0 == marker }
    }

    // MARK: - Inline level

    /// `**bold**`, `*italic*`, `` `code` ``. Hand-scanned rather than parsed:
    /// this runs on every keystroke, and the text is frequently mid-edit and
    /// therefore not valid markdown at all.
    private func styleInline(_ line: String, at range: NSRange, in storage: NSTextStorage) {
        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            guard character == "*" || character == "_" || character == "`" else {
                index += 1
                continue
            }

            let runLength = min(
                2, countRun(of: character, in: characters, from: index))
            guard let closing = findClosing(
                character, runLength: runLength, in: characters,
                after: index + runLength)
            else {
                index += 1
                continue
            }

            let contentStart = index + runLength
            let contentRange = NSRange(
                location: range.location + contentStart,
                length: closing - contentStart)

            if character == "`" {
                storage.addAttribute(.font, value: theme.monospaceFont, range: contentRange)
            } else {
                let existing = storage.attribute(
                    .font, at: contentRange.location, effectiveRange: nil) as? NSFont
                    ?? theme.bodyFont
                storage.addAttribute(
                    .font,
                    value: theme.emphasised(
                        existing, italic: runLength == 1, bold: runLength == 2),
                    range: contentRange)
            }

            // Recede the delimiters on both sides.
            for markerStart in [index, closing] {
                storage.addAttribute(
                    .foregroundColor, value: theme.syntaxColor,
                    range: NSRange(
                        location: range.location + markerStart, length: runLength))
            }

            index = closing + runLength
        }
    }

    private func countRun(
        of character: Character, in characters: [Character], from index: Int
    ) -> Int {
        var count = 0
        var cursor = index
        while cursor < characters.count, characters[cursor] == character {
            count += 1
            cursor += 1
        }
        return count
    }

    /// Index of the matching closing delimiter, or nil when the run is unclosed
    /// — which is the normal state of a line someone is still typing.
    private func findClosing(
        _ character: Character, runLength: Int, in characters: [Character], after start: Int
    ) -> Int? {
        var index = start
        while index < characters.count {
            guard characters[index] == character else {
                index += 1
                continue
            }
            let run = countRun(of: character, in: characters, from: index)
            if run >= runLength, index > start { return index }
            index += max(run, 1)
        }
        return nil
    }
}

import Foundation

/// Decides how much a save changed a chapter, so the version bump can happen
/// without the writer having to think about it.
///
/// The thresholds come from the Python app (`services/auto_version.py`) and are
/// kept so that a book carried over from Beckit 3.x keeps versioning the way its
/// author expects. They are deliberately prose-shaped rather than code-shaped: a
/// new recurring proper noun usually means a character arrived, and a changed
/// heading set usually means the chapter was restructured.
///
/// One rule is deliberately *not* a faithful port — see
/// `recurringProperNouns(_:)`, which no longer treats sentence-initial "The" as
/// a character name.
public enum ChangeClassifier {

    /// Returns the significance of the edit, or `nil` when the change is too
    /// small to deserve a version of its own (a typo fix, a comma).
    ///
    /// Rules, first match wins:
    /// - none: fewer than 5 words changed *and* under 5% of lines touched
    /// - major: the H1/H2 heading set changed
    /// - major: word count moved by more than 20%
    /// - major: a proper noun used 3+ times appeared or disappeared
    /// - minor: more than 30 words changed, or over 15% of lines touched
    /// - patch: anything else that got this far
    public static func classify(from old: String, to new: String) -> ChangeSignificance? {
        let oldWords = words(in: old)
        let newWords = words(in: new)
        let wordDelta = abs(newWords.count - oldWords.count)

        let oldLines = old.lines
        let newLines = new.lines

        let difference = newLines.difference(from: oldLines)
        let changedLines = difference.insertions.count + difference.removals.count
        let totalLines = max(oldLines.count, newLines.count, 1)
        let changedLineRatio = Double(changedLines) / Double(totalLines)

        if wordDelta < 5 && changedLineRatio < 0.05 { return nil }

        if headings(of: oldLines) != headings(of: newLines) { return .major }

        if !oldWords.isEmpty, Double(wordDelta) > Double(oldWords.count) * 0.20 {
            return .major
        }

        if recurringProperNouns(oldWords) != recurringProperNouns(newWords) {
            return .major
        }

        if wordDelta > 30 || changedLineRatio > 0.15 { return .minor }

        return .patch
    }

    // MARK: - Signals

    private static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    /// The set of level-1 and level-2 headings. Compared as a set, so moving a
    /// scene around does not read as a restructure but renaming one does.
    private static func headings(of lines: [Substring]) -> Set<Substring> {
        Set(lines.filter { line in
            guard line.first == "#" else { return false }
            let hashes = line.prefix(while: { $0 == "#" }).count
            return (1...2).contains(hashes) && line.dropFirst(hashes).first == " "
        })
    }

    /// Capitalised, purely alphabetic words used at least three times, where at
    /// least one use is mid-sentence — a cheap stand-in for "named entity",
    /// which in a novel is usually a character or a place.
    ///
    /// The mid-sentence requirement is a deliberate departure from the Python
    /// original, which counted any capitalised word. That version treated
    /// "The", "He" and "She" as characters, so almost any edit that added a few
    /// sentences introduced a "new character" and forced a major bump — the
    /// signal fired so often it carried no information. Requiring one
    /// non-sentence-initial use costs nothing and a real name clears it easily,
    /// because names do not only ever appear as the first word of a sentence.
    private static func recurringProperNouns(_ words: [Substring]) -> Set<Substring> {
        var counts: [Substring: Int] = [:]
        var seenMidSentence: Set<Substring> = []
        var atSentenceStart = true

        for word in words {
            defer { atSentenceStart = word.endsSentence }

            guard word.first?.isUppercase == true, word.allSatisfy(\.isLetter) else { continue }
            counts[word, default: 0] += 1
            if !atSentenceStart { seenMidSentence.insert(word) }
        }

        return Set(counts.lazy.filter { $0.value >= 3 && seenMidSentence.contains($0.key) }
            .map(\.key))
    }
}

private extension Substring {
    /// True when this whitespace-delimited token closes a sentence, so the next
    /// one starts a new one. Quotes and brackets are stepped over, which is what
    /// dialogue needs: `said."` ends a sentence just as `said.` does.
    var endsSentence: Bool {
        let trailing = reversed().drop { "\"'”’)]»".contains($0) }
        return trailing.first.map { ".!?…".contains($0) } ?? false
    }
}

extension String {
    /// Line-split that matches how a diff sees the text: no trailing empty
    /// element for a final newline, and `\r\n` treated as one break.
    var lines: [Substring] {
        var parts = split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // A trailing newline terminates the last line rather than starting an
        // empty one. Swift treats "\r\n" as a single Character, so CRLF text
        // needs no special handling here.
        if last?.isNewline == true, parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }
}

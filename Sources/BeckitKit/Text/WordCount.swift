import Foundation

public enum WordCount {

    /// Counts prose words in markdown.
    ///
    /// A word is a run of letters or digits, optionally stitched together by an
    /// internal apostrophe or hyphen, so `don't` and `half-empty` each count
    /// once. Markdown punctuation (`#`, `---`, `*`) contributes nothing, which
    /// is the number a writer expects to see — the Python app counted
    /// whitespace-separated tokens, so a horizontal rule counted as a word.
    ///
    /// Single pass, no allocation, so it is cheap enough to run on every
    /// keystroke for a chapter and off the main actor for a whole book.
    public static func count(in text: String) -> Int {
        var words = 0
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index].isWordCharacter else {
                index = text.index(after: index)
                continue
            }

            words += 1

            // Consume the rest of this word, stepping over an apostrophe or
            // hyphen only when a word character follows it.
            while index < text.endIndex {
                if text[index].isWordCharacter {
                    index = text.index(after: index)
                } else if text[index].isWordJoiner {
                    let next = text.index(after: index)
                    guard next < text.endIndex, text[next].isWordCharacter else { break }
                    index = next
                } else {
                    break
                }
            }
        }
        return words
    }

    /// Total across many documents. Callers hand this whole chapters, so it is
    /// kept `nonisolated` and pure for use from a background task.
    public static func total(in texts: some Sequence<String>) -> Int {
        texts.reduce(0) { $0 + count(in: $1) }
    }
}

private extension Character {
    var isWordCharacter: Bool { isLetter || isNumber }
    var isWordJoiner: Bool { self == "'" || self == "\u{2019}" || self == "-" }
}

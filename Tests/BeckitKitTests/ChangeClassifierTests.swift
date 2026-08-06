import Testing
@testable import BeckitKit

/// The classifier decides every version bump in the app without asking the
/// writer, so its thresholds are pinned here. These cases mirror the Python
/// implementation's rules to keep books carried over from Beckit 3.x versioning
/// the way their authors are used to.
@Suite("Change classification")
struct ChangeClassifierTests {

    /// A chapter's worth of paragraphs. The line-ratio rules only mean anything
    /// against a document with real structure — one changed line out of one is
    /// a total rewrite by that measure — so every threshold case here is set
    /// against prose of a believable length.
    private func chapter(paragraphs: Int) -> String {
        String(repeating: "The tide came in slowly and left again.\n\n", count: paragraphs)
    }

    @Test("A typo fix in a full chapter is not worth a version")
    func trivialEditIsIgnored() {
        let body = chapter(paragraphs: 20)
        let before = body + "He said nothing at all about the crossing that night."
        let after = body + "He said nothing at all about the crossing that night!"
        #expect(ChangeClassifier.classify(from: before, to: after) == nil)
    }

    @Test("Identical text is not a change")
    func noChange() {
        let text = "Nothing happened.\n\nThen nothing happened again."
        #expect(ChangeClassifier.classify(from: text, to: text) == nil)
    }

    @Test("Restructuring the headings is major")
    func headingChangeIsMajor() {
        let before = "# The Crossing\n\n" + String(repeating: "word ", count: 200)
        let after = "# The Return\n\n" + String(repeating: "word ", count: 200)
        #expect(ChangeClassifier.classify(from: before, to: after) == .major)
    }

    @Test("Growing the chapter by more than a fifth is major")
    func largeGrowthIsMajor() {
        let before = String(repeating: "word ", count: 100)
        let after = String(repeating: "word ", count: 130)
        #expect(ChangeClassifier.classify(from: before, to: after) == .major)
    }

    @Test("Introducing a recurring character is major")
    func newProperNounIsMajor() {
        // One word swapped, so the word count is identical and neither the
        // growth nor the line-ratio rule can fire ahead of the proper-noun one.
        // The name lands mid-sentence, as a real name does.
        let before = String(repeating: "She waited for her by the door.\n\n", count: 20)
        let after = String(repeating: "She waited for Marlow by the door.\n\n", count: 20)
        #expect(ChangeClassifier.classify(from: before, to: after) == .major)
    }

    /// The one place this classifier departs from the Python original.
    /// Capitalised sentence openers are not characters; treating them as such
    /// made almost every prose edit a major version.
    ///
    /// Swapping every "She" for "He" is exactly the shape that used to trip it:
    /// two recurring capitalised words, one appearing and one disappearing, and
    /// neither of them a name.
    @Test("A capitalised word only ever seen opening a sentence is not a character")
    func sentenceOpenersAreNotCharacters() {
        let before = String(repeating: "She waited by the door and said nothing.\n\n", count: 12)
        let after = String(repeating: "He waited by the door and said nothing.\n\n", count: 12)
        #expect(ChangeClassifier.classify(from: before, to: after) != .major)
    }

    @Test("A proper noun used once or twice is not a character")
    func rareProperNounIsNotMajor() {
        let filler = String(repeating: "the door stayed shut. ", count: 60)
        let before = filler
        let after = filler + "Marlow knocked twice and waited for an answer there."
        #expect(ChangeClassifier.classify(from: before, to: after) != .major)
    }

    @Test("A solid paragraph of new prose is minor")
    func moderateAdditionIsMinor() {
        let before = String(repeating: "word ", count: 400)
        let after = before + String(repeating: "sentence ", count: 40)
        #expect(ChangeClassifier.classify(from: before, to: after) == .minor)
    }

    @Test("A reworded line in a short scene is a patch")
    func smallRewriteIsPatch() {
        let body = chapter(paragraphs: 10)
        let before = body + "He said nothing at all about the crossing that night, not once."
        let after = body + "He said little enough about the crossing that night, not a word."
        #expect(ChangeClassifier.classify(from: before, to: after) == .patch)
    }

    /// Filling an empty chapter reads as minor, not major: the >20% growth rule
    /// needs a previous word count to be 20% of, and there isn't one. A brand
    /// new chapter therefore goes v1.0.0 → v1.1.0, which is the right shape —
    /// a first draft is the start of the work, not a second edition of it.
    @Test("Writing the first draft into an empty chapter is minor")
    func firstDraftIsMinor() {
        #expect(ChangeClassifier.classify(from: "", to: chapter(paragraphs: 8)) == .minor)
    }
}

@Suite("Semantic versions")
struct SemanticVersionTests {

    @Test("Parses the forms Beckit writes", arguments: [
        ("v1.2.3", SemanticVersion(1, 2, 3)),
        ("1.0.0", SemanticVersion(1, 0, 0)),
        ("v0.0.0", SemanticVersion(0, 0, 0)),
        ("v12.30.400", SemanticVersion(12, 30, 400)),
    ])
    func parsing(input: String, expected: SemanticVersion) {
        #expect(SemanticVersion(input) == expected)
    }

    @Test("Rejects anything that is not a plain three-part version", arguments: [
        "v1.2", "1.2.3.4", "v1.2.x", "", "v", "v01.2.3", "v1.2.3-beta", " 1.2.3",
    ])
    func rejectsMalformed(input: String) {
        #expect(SemanticVersion(input) == nil)
    }

    @Test("Bumping resets the components below it")
    func bumping() {
        let version = SemanticVersion(1, 4, 7)
        #expect(version.bumped(.patch) == SemanticVersion(1, 4, 8))
        #expect(version.bumped(.minor) == SemanticVersion(1, 5, 0))
        #expect(version.bumped(.major) == SemanticVersion(2, 0, 0))
    }

    @Test("Orders numerically, not lexically")
    func ordering() {
        #expect(SemanticVersion(1, 9, 0) < SemanticVersion(1, 10, 0))
        #expect(SemanticVersion(2, 0, 0) > SemanticVersion(1, 99, 99))
    }

    @Test("Round-trips through its own description")
    func roundTrip() {
        let version = SemanticVersion(3, 12, 5)
        #expect(SemanticVersion(version.description) == version)
    }
}

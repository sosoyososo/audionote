import XCTest
@testable import AudioNote

/// The vocabulary the model sees is chosen by relevance first and frequency
/// second. The one failure mode that matters: a tag the note actually talks
/// about is left out because the library barely uses it.
final class TagVocabularySelectorTests: XCTestCase {

    // MARK: - The core behaviour

    func testRelevantRareTagComesBeforeIrrelevantFrequentOne() {
        let counts = ["常用": 100, "会议纪要": 1]
        let text = "今天的会议纪要讨论了下周的预算"

        let selected = TagVocabularySelector.select(counts: counts, text: text, limit: 30)

        XCTAssertEqual(selected.first, "会议纪要")
        // The frequent tag still comes along — relevance reorders, it does
        // not shrink the vocabulary.
        XCTAssertTrue(selected.contains("常用"))
    }

    func testWithoutRelevanceTheOrderIsFrequencyThenName() {
        let counts = ["b": 2, "a": 2, "c": 5]

        let selected = TagVocabularySelector.select(counts: counts, text: "毫无关系的一段话", limit: 30)

        XCTAssertEqual(selected, ["c", "a", "b"])
    }

    func testLimitIsRespected() {
        let counts = ["常用": 100, "会议纪要": 1]

        let selected = TagVocabularySelector.select(counts: counts, text: "会议纪要", limit: 1)

        XCTAssertEqual(selected, ["会议纪要"])
    }

    // MARK: - What counts as relevant

    func testChineseTwoCharacterOverlapCountsAsRelevant() {
        // The full tag is not in the note; the shared 会议 is.
        let counts = ["会议纪要": 1]
        let text = "今天的会议安排了一下"

        let selected = TagVocabularySelector.select(counts: counts, text: text, limit: 30)

        XCTAssertEqual(selected, ["会议纪要"])
    }

    func testChineseWithoutAnySharedSubstringIsNotRelevant() {
        let counts = ["运动": 1]
        let text = "今天开会讨论预算"

        let selected = TagVocabularySelector.select(counts: counts, text: text, limit: 30)

        // Not relevant — but it is still the only tag, so it is still offered.
        // Relevance decides the order, never the membership.
        XCTAssertEqual(selected, ["运动"])
    }

    func testEnglishWordOfThreeLettersCountsAsRelevant() {
        let counts = ["work": 1]
        let text = "team meeting about the WORK backlog"

        let selected = TagVocabularySelector.select(counts: counts, text: text, limit: 30)

        XCTAssertEqual(selected, ["work"])
    }

    func testEnglishTagInsideALongerWordIsNotRelevant() {
        let counts = ["ai": 1, "budget": 9]
        // "ai" occurs inside "daily", but not as a word of its own.
        let text = "daily notes"

        let selected = TagVocabularySelector.select(counts: counts, text: text, limit: 1)

        // The frequent unrelated tag takes the only slot.
        XCTAssertEqual(selected, ["budget"])
    }

    func testShortEnglishTagAsAWholeWordIsRelevant() {
        let counts = ["ai": 1, "budget": 9]
        let text = "an ai discussion"

        let selected = TagVocabularySelector.select(counts: counts, text: text, limit: 1)

        XCTAssertEqual(selected, ["ai"])
    }

    func testComparisonIsCaseInsensitive() {
        let counts = ["Work": 1]
        let text = "notes about work"

        let selected = TagVocabularySelector.select(counts: counts, text: text, limit: 30)

        XCTAssertEqual(selected, ["Work"])
    }

    func testTheSpellingIsPreserved() {
        let counts = ["Work": 1]

        let selected = TagVocabularySelector.select(counts: counts, text: "work", limit: 30)

        // Folded case here would hide from the model the very spelling drift
        // it is being asked to fix.
        XCTAssertEqual(selected, ["Work"])
    }

    // MARK: - Degenerate inputs

    func testEmptyInputsAreSafe() {
        XCTAssertEqual(TagVocabularySelector.select(counts: [:], text: "text", limit: 10), [])
        XCTAssertEqual(TagVocabularySelector.select(counts: ["a": 1], text: "text", limit: 0), [])
        XCTAssertEqual(TagVocabularySelector.select(counts: ["a": 1], text: "", limit: 10), ["a"])
        XCTAssertEqual(TagVocabularySelector.select(counts: ["a": 1], text: "   ", limit: 10), ["a"])
    }
}

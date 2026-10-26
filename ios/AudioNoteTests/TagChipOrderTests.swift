import XCTest
@testable import AudioNote

/// The chip row's order, and what the row shows when a search is running.
///
/// The row is a filter control, so the order has to answer "which tag do
/// I want?" — and the badge on each chip answers it with a count. An
/// order that disagrees with the badge is worse than no order at all.
@MainActor
final class TagChipOrderTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        _ title: String,
        id: UUID = UUID(),
        tags: [TaggedItem] = [],
        archived: Bool = false,
        minutesAgo: Int = 0
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            id: id,
            content: "\(title)的正文",
            createdAt: base.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            title: title,
            tags: tags.isEmpty ? nil : tags,
            llmProcessingStatus: .completed,
            archived: archived
        )
    }

    private func makeViewModel(_ records: [TranscriptionRecord]) -> TranscriptionViewModel {
        let vm = TranscriptionViewModel()
        vm.historyRecords = records
        return vm
    }

    // MARK: - Order

    /// The bug in one assertion: a tag on one record with score 0.95 used
    /// to outrank a tag on three records with score 0.2, because the order
    /// was the maximum score rather than the number of records.
    func testTheMostUsedTagComesFirst() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "少用", score: 0.95)]),
            record("乙", tags: [TaggedItem(name: "常用", score: 0.2)]),
            record("丙", tags: [TaggedItem(name: "常用", score: 0.3)]),
            record("丁", tags: [TaggedItem(name: "常用", score: 0.1)])
        ])

        XCTAssertEqual(vm.availableTags.first, "常用")
    }

    /// Legacy string tags carry *pseudo* scores whose first tag is always
    /// 1.0. Ordered by score, one legacy record's first tag sat above
    /// every tag the user actually uses often.
    func testALegacyFirstTagDoesNotOutrankAFrequentTag() {
        // What a legacy record decodes to: string tags mapped onto
        // descending pseudo-scores, so its first tag is always 1.0.
        let legacy = TranscriptionRecord(
            id: UUID(),
            content: "老记录的正文",
            createdAt: base,
            title: "老记录",
            tags: [
                TaggedItem(name: "旧标签", score: 1.0),
                TaggedItem(name: "第二个", score: 0.75)
            ],
            llmProcessingStatus: .completed,
            archived: false
        )
        let vm = makeViewModel([
            legacy,
            record("乙", tags: [TaggedItem(name: "常用", score: 0.4)]),
            record("丙", tags: [TaggedItem(name: "常用", score: 0.4)])
        ])

        XCTAssertEqual(vm.availableTags.first, "常用")
    }

    /// Same count → the higher score wins; same score → alphabetical, so
    /// the row never reshuffles between two runs.
    func testTiesBreakByScoreThenAlphabetically() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "乙标签", score: 0.5)]),
            record("乙", tags: [TaggedItem(name: "甲标签", score: 0.5)]),
            record("丙", tags: [TaggedItem(name: "丙标签", score: 0.9)])
        ])

        // 丙标签 has the highest score but the same count as the others, so
        // it leads on the tiebreak.
        XCTAssertEqual(vm.availableTags, ["丙标签", "甲标签", "乙标签"])
    }

    // MARK: - The search narrows the row

    /// The badges already narrowed with the search query. The chips did
    /// not, so the row showed a chip at count 12 next to a chip at count 0
    /// and ordered them by something else entirely.
    func testTheChipsNarrowWithTheSearchQuery() {
        let vm = makeViewModel([
            record("会议记录", tags: [TaggedItem(name: "会议", score: 0.9)]),
            record("购物清单", tags: [TaggedItem(name: "购物", score: 0.9)])
        ])

        vm.searchQuery = "会议"

        XCTAssertEqual(vm.availableTags, ["会议"])
        XCTAssertEqual(vm.tagCount(for: "会议"), 1)
        XCTAssertEqual(vm.tagCount(for: "购物"), 0)
    }

    /// The order and the badge are the same number now, so they cannot
    /// disagree: the first chip is the one with the highest count.
    func testTheOrderAgreesWithTheBadge() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "少用", score: 0.99)]),
            record("乙", tags: [TaggedItem(name: "常用", score: 0.2)]),
            record("丙", tags: [TaggedItem(name: "常用", score: 0.2)])
        ])

        let chips = vm.availableTags
        XCTAssertEqual(chips.first, "常用")
        // The first chip is the one with the highest count — the badge and
        // the order are the same number, so a chip can never sit ahead of
        // a chip that carries more records.
        XCTAssertGreaterThan(vm.tagCount(for: chips[0]), vm.tagCount(for: chips[1]))
    }

    // MARK: - Searching a tag

    func testTheTagSearchIsCaseInsensitiveAndMatchesASubstring() {
        XCTAssertTrue(TagIdentity.contains("Work", query: "work"))
        XCTAssertTrue(TagIdentity.contains("会议记录", query: "议"))
        XCTAssertTrue(TagIdentity.contains("会议记录", query: "  会议 "))
        XCTAssertFalse(TagIdentity.contains("会议记录", query: "工作"))
    }

    /// An empty query matches everything, so the caller needs no special
    /// case for "the user cleared the search box".
    func testAnEmptyQueryMatchesEveryTag() {
        XCTAssertTrue(TagIdentity.contains("任何标签", query: ""))
        XCTAssertTrue(TagIdentity.contains("任何标签", query: "   "))
    }
}

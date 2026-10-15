import XCTest
@testable import AudioNote

/// Tag identity is case-insensitive: one chip per tag however the LLM spelled
/// it that day, and every comparison — filter, sort, count, highlight, related
/// notes — agreeing on that one definition.
///
/// `@MainActor` because `TranscriptionViewModel` is main-actor isolated and
/// these drive it directly rather than through the view.
@MainActor
final class TagCaseInsensitivityTests: XCTestCase {

    // MARK: - Fixtures

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// `llmProcessingStatus` defaults to `.completed` because
    /// `RelatedNotesService.prescreen` skips anything that hasn't finished
    /// LLM processing — a record without it is invisible to the prescreen, not
    /// unranked.
    private func record(
        _ title: String,
        id: UUID = UUID(),
        tags: [TaggedItem] = [],
        archived: Bool = false,
        minutesAgo: Int = 0,
        status: LLMStatus? = .completed
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            id: id,
            content: "\(title)的正文",
            createdAt: base.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            title: title,
            tags: tags.isEmpty ? nil : tags,
            llmProcessingStatus: status,
            archived: archived
        )
    }

    private func makeViewModel(_ records: [TranscriptionRecord]) -> TranscriptionViewModel {
        let vm = TranscriptionViewModel()
        vm.historyRecords = records
        return vm
    }

    // MARK: - The helper itself

    func testIdentityFoldsLatinCaseOnly() {
        XCTAssertEqual(TagIdentity.key("Work"), TagIdentity.key("WORK"))
        // CJK has no case — this is the whole reason the change is low-risk for
        // a Chinese-content library: nothing about those tags moves.
        XCTAssertEqual(TagIdentity.key("工作"), "工作")
        XCTAssertEqual(TagIdentity.key("会议记录"), "会议记录")
    }

    // MARK: - Chips

    /// The bug in one assertion: two spellings used to be two chips, and each
    /// chip found only the records spelled its own way.
    func testTwoSpellingsCollapseIntoOneChip() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "Work", score: 1.0)]),
            record("乙", tags: [TaggedItem(name: "work", score: 1.0)])
        ])

        XCTAssertEqual(vm.availableTags, ["Work"])
    }

    func testChipShowsTheMoreFrequentSpelling() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "Work", score: 1.0)]),
            record("乙", tags: [TaggedItem(name: "Work", score: 1.0)]),
            record("丙", tags: [TaggedItem(name: "work", score: 1.0)])
        ])

        XCTAssertEqual(vm.availableTags, ["Work"], "2 records say Work, 1 says work")
    }

    func testEqualCountsFallBackToTheHigherScore() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "Work", score: 0.2)]),
            record("乙", tags: [TaggedItem(name: "work", score: 0.9)])
        ])

        XCTAssertEqual(vm.availableTags, ["work"])
    }

    /// Without a deterministic last resort `Work` vs `work` compares as "same"
    /// under a case-insensitive compare and the winner depends on dictionary
    /// iteration order — the same library showing a different chip label on a
    /// different run.
    func testEqualCountsAndScoresFallBackDeterministically() {
        let records = [
            record("甲", tags: [TaggedItem(name: "Work", score: 0.5)]),
            record("乙", tags: [TaggedItem(name: "work", score: 0.5)])
        ]

        let first = makeViewModel(records).availableTags
        for _ in 0..<20 {
            XCTAssertEqual(makeViewModel(records).availableTags, first)
        }
        XCTAssertEqual(first, ["Work"], "raw < puts the capitalised spelling first")
    }

    func testMergedChipCountsEverySpelling() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "Work", score: 1.0)]),
            record("乙", tags: [TaggedItem(name: "work", score: 1.0)]),
            record("丙", tags: [TaggedItem(name: "WORK", score: 1.0)])
        ])

        XCTAssertEqual(vm.availableTags.count, 1)
        XCTAssertEqual(vm.tagCount(for: vm.availableTags[0]), 3)
    }

    func testDistinctTagsAreStillDistinctChips() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "Work", score: 1.0)]),
            record("乙", tags: [TaggedItem(name: "Meetings", score: 0.5)])
        ])

        XCTAssertEqual(vm.availableTags, ["Work", "Meetings"])
    }

    // MARK: - Chinese tags are untouched

    func testChineseTagsBehaveExactlyAsBefore() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "工作", score: 1.0)]),
            record("乙", tags: [TaggedItem(name: "旧项目", score: 0.4)])
        ])

        XCTAssertEqual(vm.availableTags, ["工作", "旧项目"])

        vm.selectedTags = ["工作"]
        XCTAssertEqual(vm.displayedRecords.map(\.title), ["甲"])
        XCTAssertEqual(vm.tagCount(for: "工作"), 1)
    }

    // MARK: - Filtering

    func testSelectingTheChipFindsBothSpellings() {
        let vm = makeViewModel([
            record("大写", tags: [TaggedItem(name: "Work", score: 0.9)]),
            record("小写", tags: [TaggedItem(name: "work", score: 0.9)]),
            record("无关", tags: [TaggedItem(name: "Meetings", score: 0.3)])
        ])

        // Tapping the chip gives back its display form; the filter must not
        // then only find records that happen to spell it that way.
        XCTAssertEqual(vm.availableTags, ["Work", "Meetings"])
        vm.toggleTag(vm.availableTags[0])

        XCTAssertEqual(vm.displayedRecords.map { $0.title ?? "" }.sorted(), ["大写", "小写"])
    }

    func testToggleReplacesAnExistingEntrySpelledDifferently() {
        let vm = makeViewModel([record("甲", tags: [TaggedItem(name: "Work", score: 1.0)])])

        vm.selectedTags = ["work"]
        vm.toggleTag("Work")

        XCTAssertTrue(vm.selectedTags.isEmpty,
                      "re-tapping the same tag must remove it, not stack a second entry")
    }

    func testChipShowsAsSelectedWhicheverFormIsSelected() {
        let vm = makeViewModel([record("甲", tags: [TaggedItem(name: "Work", score: 1.0)])])
        let chip = vm.availableTags[0]

        vm.selectedTags = ["work"]   // e.g. restored from an earlier session

        XCTAssertTrue(TagIdentity.matches(chip, anyOf: vm.selectedTags))
    }

    // MARK: - Sorting

    /// A record carrying both spellings matches the merged chip *once*. If the
    /// rank counted them twice it would outrank a record that genuinely hits
    /// two different filters, and the list order would lie about relevance.
    func testRankCountsAnIdentityOnceNotItsSpellings() {
        let vm = makeViewModel([
            record("只算一个", tags: [
                TaggedItem(name: "Work", score: 1.0),
                TaggedItem(name: "work", score: 1.0)
            ]),
            record("真的两个", tags: [
                TaggedItem(name: "Work", score: 1.0),
                TaggedItem(name: "Meetings", score: 1.0)
            ])
        ])
        vm.selectedTags = ["Work", "Meetings"]

        XCTAssertEqual(vm.displayedRecords.map(\.title), ["真的两个", "只算一个"])
    }

    func testRankRecognisesADifferentlySpelledSecondTag() {
        let vm = makeViewModel([
            record("双标签", tags: [
                TaggedItem(name: "Work", score: 1.0),
                TaggedItem(name: "meetings", score: 1.0)
            ]),
            record("单标签", tags: [TaggedItem(name: "Work", score: 1.0)])
        ])
        vm.selectedTags = ["Work", "Meetings"]

        XCTAssertEqual(vm.displayedRecords.map(\.title), ["双标签", "单标签"])
    }

    // MARK: - Archive mode interaction

    /// Entering the archive with `Work` selected must not re-add a second chip
    /// for it alongside the one the archived records themselves contributed.
    func testArchiveModeDoesNotDuplicateTheOrphanChipAcrossSpellings() {
        let vm = makeViewModel([
            record("活着的", tags: [TaggedItem(name: "Work", score: 1.0)]),
            record("收起来的", tags: [TaggedItem(name: "work", score: 1.0)], archived: true)
        ])
        vm.selectedTags = ["WORK"]

        vm.isArchiveMode = true

        XCTAssertEqual(vm.availableTags, ["work"], "the archive's own spelling, once")
        XCTAssertEqual(vm.displayedRecords.map(\.title), ["收起来的"])
    }

    func testArchiveModeStillShowsAnOrphanChipWhenNothingMatches() {
        let vm = makeViewModel([
            record("活着的", tags: [TaggedItem(name: "Work", score: 1.0)]),
            record("收起来的", tags: [TaggedItem(name: "旧项目", score: 1.0)], archived: true)
        ])
        vm.selectedTags = ["Work"]

        vm.isArchiveMode = true

        XCTAssertEqual(vm.availableTags, ["旧项目", "Work"], "orphan still sorts last")
        XCTAssertEqual(vm.tagCount(for: "Work"), 0)
        XCTAssertTrue(vm.displayedRecords.isEmpty)
    }

    // MARK: - Related notes

    /// The prescreen used to intersect exact spellings, so a note tagged `work`
    /// shared nothing with one tagged `Work` and scored on recency alone.
    func testPrescreenCountsCrossSpellingTagsAsShared() {
        let currentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let current = record("甲", id: currentID, tags: [TaggedItem(name: "Work", score: 1.0)])

        let related = record("共享", tags: [TaggedItem(name: "work", score: 1.0)])
        let unrelated = record("无关", tags: [TaggedItem(name: "Meetings", score: 1.0)])

        let ranked = RelatedNotesService.prescreen(current: current, among: [unrelated, related])

        XCTAssertEqual(ranked.first?.id, related.id,
                       "a cross-spelling share outranks a recency-only score")
    }

    /// And the row's shared-tag chips must show the same overlap the prescreen
    /// acted on — one computing shared tags the other way would render chips
    /// for a link that had been earned on different grounds.
    func testRelatedRowSharedTagsSurviveCaseDifference() {
        let current = record("甲", tags: [TaggedItem(name: "Work", score: 1.0)])
        let other = record("乙", tags: [
            TaggedItem(name: "work", score: 1.0),
            TaggedItem(name: "Meetings", score: 0.5)
        ])

        let rows = RelatedNotesSectionBuilder.rows(
            for: current,
            candidates: [other],
            related: [RelatedNote(id: other.id, score: 2.0)]
        )

        XCTAssertEqual(rows.first?.sharedTags, ["work"], "the other record's own spelling")
    }
}

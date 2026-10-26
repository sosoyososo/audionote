import XCTest
@testable import AudioNote

/// The three counts the library shows, and why they are three.
///
/// "How many notes do I have" has three answers in this app, and they are
/// not the same number:
///
/// - the size of the side you are looking at (live or archived) — the
///   navigation title
/// - how many of those survive your filters — the filter bar
/// - every record in the library — settings
///
/// Each is placed where it cannot be misread for one of the others. The
/// title's number must not change when a filter is applied: it says how big
/// this side is, not how many rows happen to be on screen.
@MainActor
final class LibraryCountTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        _ title: String,
        tags: [TaggedItem] = [],
        archived: Bool = false
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            id: UUID(),
            content: "\(title)的正文",
            createdAt: base,
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

    // MARK: - The scope count (the title)

    func testTheScopeCountIsTheCurrentSideOfTheArchiveSplitOnly() {
        let vm = makeViewModel([
            record("甲"),
            record("乙"),
            record("丙"),
            record("归档一", archived: true),
            record("归档二", archived: true)
        ])

        XCTAssertEqual(vm.recordCountInScope, 3)

        vm.isArchiveMode = true
        XCTAssertEqual(vm.recordCountInScope, 2)
    }

    /// The title's number is the library's size, so a filter must not move
    /// it. If it did, the title would be describing the filter instead of
    /// the library, and the same title would mean two different things.
    func testTheScopeCountDoesNotChangeWithFilters() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "常用", score: 0.5)]),
            record("乙", tags: [TaggedItem(name: "常用", score: 0.5)]),
            record("丙", tags: [TaggedItem(name: "少用", score: 0.5)])
        ])

        let before = vm.recordCountInScope

        vm.searchQuery = "甲"
        vm.selectedTags = ["常用"]

        XCTAssertEqual(vm.recordCountInScope, before)
    }

    // MARK: - The total (settings)

    func testTheTotalCountIsBothSides() {
        let vm = makeViewModel([
            record("甲"),
            record("乙"),
            record("归档一", archived: true)
        ])

        XCTAssertEqual(vm.totalRecordCount, 3)
        XCTAssertEqual(vm.recordCountInScope, 2)
    }

    // MARK: - The filtered count (the filter bar)

    /// The denominator of "5 of 8" is the population the *tag* filter
    /// narrows — the records the search already matched. If the denominator
    /// were the whole library, the number would blame the tags for hiding
    /// records the search box hid.
    func testTheSearchScopeIgnoresTheTagFilter() {
        let vm = makeViewModel([
            record("甲·会议", tags: [TaggedItem(name: "常用", score: 0.5)]),
            record("乙·会议", tags: [TaggedItem(name: "少用", score: 0.5)]),
            record("丙·私人")
        ])

        // The search matches two of the three records.
        vm.searchQuery = "会议"
        XCTAssertEqual(vm.searchMatchedCountInScope, 2)

        vm.selectedTags = ["常用"]
        // The search still matched two records; the tag filter is what
        // narrows them, and it is not the denominator's business.
        XCTAssertEqual(vm.searchMatchedCountInScope, 2)
        XCTAssertEqual(vm.filteredRecordCount, 1)
    }

    func testTheFilteredCountMatchesTheDisplayedRecords() {
        let vm = makeViewModel([
            record("甲", tags: [TaggedItem(name: "常用", score: 0.5)]),
            record("乙", tags: [TaggedItem(name: "常用", score: 0.5)]),
            record("丙")
        ])

        vm.selectedTags = ["常用"]

        XCTAssertEqual(vm.filteredRecordCount, 2)
        XCTAssertEqual(vm.filteredRecordCount, vm.displayedRecords.count)
    }

    /// With no filters the three numbers agree — and that is the only case
    /// where they are supposed to. A filter splits them apart on purpose.
    func testTheCountsAgreeWhenNothingIsFiltered() {
        let vm = makeViewModel([
            record("甲"),
            record("乙"),
            record("归档一", archived: true)
        ])

        XCTAssertEqual(vm.recordCountInScope, 2)
        XCTAssertEqual(vm.searchMatchedCountInScope, 2)
        XCTAssertEqual(vm.filteredRecordCount, 2)
    }
}

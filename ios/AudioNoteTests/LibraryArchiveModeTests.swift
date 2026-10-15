import XCTest
@testable import AudioNote

/// Tests for the archive split in the library list — `isArchiveMode` making
/// `displayedRecords` / `availableTags` / `tagCounts` read the other half of
/// the library, and the two things that split introduced which did not exist
/// when archive was a banner.
///
/// `@MainActor` because `TranscriptionViewModel` is main-actor isolated and
/// these drive it directly rather than through the view.
@MainActor
final class LibraryArchiveModeTests: XCTestCase {

    // MARK: - Fixtures

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        _ title: String,
        tags: [String] = [],
        archived: Bool = false,
        minutesAgo: Int = 0,
        tagScores: [Double]? = nil
    ) -> TranscriptionRecord {
        let scored = tags.enumerated().map { idx, name in
            TaggedItem(name: name, score: tagScores?[safe: idx] ?? 1.0)
        }
        return TranscriptionRecord(
            content: "\(title)的正文",
            createdAt: base.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            title: title,
            tags: scored.isEmpty ? nil : scored,
            archived: archived
        )
    }

    private func makeViewModel(_ records: [TranscriptionRecord]) -> TranscriptionViewModel {
        let vm = TranscriptionViewModel()
        vm.historyRecords = records
        return vm
    }

    // MARK: - The split itself

    func testLiveListExcludesArchivedRecords() {
        let live = record("活着的", archived: false)
        let vm = makeViewModel([live, record("收起来的", archived: true)])

        XCTAssertEqual(vm.displayedRecords.map(\.title), ["活着的"])
    }

    func testArchiveModeShowsOnlyArchivedRecords() {
        let vm = makeViewModel([
            record("活着的", archived: false),
            record("收起来的", archived: true)
        ])

        vm.isArchiveMode = true

        XCTAssertEqual(vm.displayedRecords.map(\.title), ["收起来的"])
    }

    func testTogglingArchiveModeDoesNotTouchFilters() {
        let vm = makeViewModel([record("活着的", tags: ["工作"])])
        vm.selectedTags = ["工作"]
        vm.searchQuery = "活"

        vm.isArchiveMode = true

        // "空就空着" is the agreed rule — the filters survive the toggle and
        // the archive list is allowed to come up empty because of them.
        XCTAssertEqual(vm.selectedTags, ["工作"])
        XCTAssertEqual(vm.searchQuery, "活")
        XCTAssertTrue(vm.displayedRecords.isEmpty)
    }

    // MARK: - Filters stay symmetric across the split

    func testSearchFiltersBothSides() {
        let vm = makeViewModel([
            record("季度总结", archived: false),
            record("季度总结", archived: true)
        ])
        vm.searchQuery = "季度"

        XCTAssertEqual(vm.displayedRecords.count, 1)

        vm.isArchiveMode = true
        XCTAssertEqual(vm.displayedRecords.count, 1)
        XCTAssertEqual(vm.displayedRecords.first?.archived, true)
    }

    func testTagChipsAreBuiltPerSideNotShared() {
        let vm = makeViewModel([
            record("活着的", tags: ["工作"], archived: false),
            record("收起来的", tags: ["旧项目"], archived: true)
        ])

        // A tag carried only by archived records must not appear on the live
        // list — this is what used to make the archived banner the only place
        // such a tag was ever visible.
        XCTAssertEqual(vm.availableTags, ["工作"])

        vm.isArchiveMode = true
        XCTAssertEqual(vm.availableTags, ["旧项目"])
    }

    /// The regression this whole change was about: entering archive mode with a
    /// tag selected that no archived record carries used to leave a filter
    /// silently applied with nothing on screen to switch off.
    func testSelectedTagWithNoArchivedMatchStillRenders() {
        let vm = makeViewModel([
            record("活着的", tags: ["工作"], archived: false),
            record("收起来的", tags: ["旧项目"], archived: true)
        ])
        vm.selectedTags = ["工作"]

        vm.isArchiveMode = true

        // Rendered, but last: the synthesized tag scores -infinity while the
        // real archived tag scores 1.0, so the orphaned filter sits at the end
        // of the row instead of competing with tags that actually matched.
        XCTAssertEqual(vm.availableTags, ["旧项目", "工作"])
        XCTAssertNil(vm.tagCounts["工作"])          // falls back to 0 in the view
        XCTAssertEqual(vm.tagCounts["旧项目"], 1)
        XCTAssertTrue(vm.displayedRecords.isEmpty)  // empty, but explicable
    }

    func testTagCountsReflectOnlyTheSideInScope() {
        let vm = makeViewModel([
            record("甲", tags: ["工作"], archived: false),
            record("乙", tags: ["工作"], archived: false),
            record("丙", tags: ["工作"], archived: true)
        ])

        XCTAssertEqual(vm.tagCounts["工作"], 2)

        vm.isArchiveMode = true
        XCTAssertEqual(vm.tagCounts["工作"], 1)
    }

    func testTagSortOrderSurvivesTheSplit() {
        let vm = makeViewModel([
            record("收起来的", tags: ["旧项目", "低分"], archived: true, tagScores: [1.0, 0.1])
        ])

        vm.isArchiveMode = true

        XCTAssertEqual(vm.availableTags, ["旧项目", "低分"])
    }

    func testArchiveModeSortsByTagMatchCountThenDate() {
        let vm = makeViewModel([
            record("单标签", tags: ["工作", "旧项目"], archived: true, minutesAgo: 60),
            record("双标签", tags: ["工作", "旧项目"], archived: true, minutesAgo: 10)
        ])
        vm.selectedTags = ["工作", "旧项目"]

        vm.isArchiveMode = true

        XCTAssertEqual(vm.displayedRecords.map(\.title), ["双标签", "单标签"])
    }

    // MARK: - Counters

    func testArchivedRecordCountIgnoresFilters() {
        let vm = makeViewModel([
            record("活着的", archived: false),
            record("收起来的甲", archived: true),
            record("收起来的乙", archived: true)
        ])

        XCTAssertEqual(vm.archivedRecordCount, 2)

        vm.searchQuery = "绝不可能匹配的关键词"
        XCTAssertEqual(vm.archivedRecordCount, 2)
    }

    func testHasRecordsInScopeDistinguishesEmptyFromFiltered() {
        let vm = makeViewModel([record("收起来的", archived: true)])

        // Live list is genuinely empty — not "empty because your filters
        // matched nothing".
        XCTAssertFalse(vm.hasRecordsInScope)

        vm.isArchiveMode = true
        XCTAssertTrue(vm.hasRecordsInScope)

        // …and once there is something in scope, filtering down to zero is a
        // no-results state rather than an empty list.
        vm.searchQuery = "绝不可能匹配的关键词"
        XCTAssertTrue(vm.hasRecordsInScope)
        XCTAssertTrue(vm.displayedRecords.isEmpty)
    }

    func testArchivingTheLastLiveRecordEmptiesTheLiveListNotTheArchive() {
        let vm = makeViewModel([record("最后一条", archived: false)])
        XCTAssertTrue(vm.hasRecordsInScope)

        vm.historyRecords[0].archived = true

        XCTAssertFalse(vm.hasRecordsInScope)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
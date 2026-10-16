import XCTest
@testable import AudioNote

/// The library-wide rewrite that folds near-synonym tags into one.
///
/// Everything here exercises `TagMerger` as a pure function — the storage
/// write it feeds is a single atomic `saveAll` with no branches of its own,
/// and `TranscriptionViewModel` cannot be tested at all (its `storage` is a
/// `private let` singleton), which is why the selection remap was extracted
/// into a pure static too.
@MainActor
final class TagMergerTests: XCTestCase {

    // MARK: - Fixtures

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        _ title: String,
        tags: [TaggedItem]?,
        archived: Bool = false
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            content: "\(title)的正文",
            createdAt: base,
            title: title,
            tags: tags,
            archived: archived
        )
    }

    // MARK: - Collapsing

    func testASingleHitBecomesTheTarget() {
        let input = [record("甲", tags: [TaggedItem(name: "工作项", score: 0.9)])]

        let merged = TagMerger.merge(records: input, into: "工作", from: ["工作项"])

        XCTAssertEqual(merged.first?.tagNames, ["工作"])
    }

    /// The record-level collapse. Two source tags on one record must leave
    /// **one** entry behind, not two same-named ones.
    func testManyHitsCollapseToASingleEntry() {
        let input = [record("甲", tags: [
            TaggedItem(name: "工作项", score: 0.9),
            TaggedItem(name: "工作进展", score: 0.6),
            TaggedItem(name: "会议", score: 0.2)
        ])]

        let merged = TagMerger.merge(records: input, into: "工作", from: ["工作项", "工作进展"])

        XCTAssertEqual(merged.first?.tagNames, ["工作", "会议"])
        XCTAssertEqual(merged.first?.tags?.count, 2)
    }

    /// The case that catches the union bug: the record already carries the
    /// target. Without the target's identity in the hit set, the existing
    /// `工作` is left untouched and a second one is inserted beside it.
    func testARecordAlreadyCarryingTheTargetTakesTheMax() {
        let input = [record("甲", tags: [
            TaggedItem(name: "会议", score: 0.5),
            TaggedItem(name: "工作", score: 0.4),
            TaggedItem(name: "工作项", score: 0.9)
        ])]

        let merged = TagMerger.merge(records: input, into: "工作", from: ["工作项"])

        XCTAssertEqual(merged.first?.tagNames, ["会议", "工作"])
        XCTAssertEqual(
            merged.first?.tags?.filter { $0.name == "工作" }.count, 1,
            "the target must not appear twice"
        )
        XCTAssertEqual(merged.first?.score(forTagName: "工作"), 0.9, "max, not first or average")
    }

    /// One record carrying two sources is rewritten once. This is why the
    /// confirmation page's headline count is not the sum of per-source counts
    /// (spec §4).
    func testARecordWithTwoSourcesIsRewrittenOnce() {
        let input = [
            record("甲", tags: [TaggedItem(name: "工作项", score: 0.9), TaggedItem(name: "工作进展", score: 0.5)]),
            record("乙", tags: [TaggedItem(name: "工作项", score: 0.8)])
        ]

        let merged = TagMerger.merge(
            records: input, into: "工作", from: ["工作项", "工作进展"]
        )

        let affected = merged.filter { $0.tagNames == ["工作"] }
        XCTAssertEqual(affected.count, 2, "distinct records, not 31 + 16")
    }

    // MARK: - What must not change

    func testANonMatchingRecordIsReturnedUnchanged() {
        let input = [record("甲", tags: [TaggedItem(name: "会议", score: 0.7)])]

        let merged = TagMerger.merge(records: input, into: "工作", from: ["工作项"])

        XCTAssertEqual(merged, input)
    }

    func testARecordWithoutTagsKeepsThemAbsent() {
        let input = [record("甲", tags: nil)]

        let merged = TagMerger.merge(records: input, into: "工作", from: ["工作项"])

        XCTAssertNil(merged.first?.tags, "a rewrite must not introduce empty tag arrays")
    }

    /// Only `tags` may change. Losing `archived` or `audioFileName` here would
    /// silently un-archive records or orphan their .m4a.
    func testOnlyTagsAreRewritten() {
        let input = [TranscriptionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            content: "正文",
            createdAt: base,
            audioFileName: "abc.m4a",
            title: "标题",
            summary: "摘要",
            tags: [TaggedItem(name: "工作项", score: 0.9)],
            llmProcessingStatus: .completed,
            optimizedContent: "原始",
            recognitionMode: .online,
            archived: true,
            archivedAt: base
        )]

        let merged = TagMerger.merge(records: input, into: "工作", from: ["工作项"])

        let after = merged[0]
        XCTAssertEqual(after.id, input[0].id)
        XCTAssertEqual(after.content, "正文")
        XCTAssertEqual(after.audioFileName, "abc.m4a")
        XCTAssertEqual(after.title, "标题")
        XCTAssertEqual(after.summary, "摘要")
        XCTAssertEqual(after.llmProcessingStatus, .completed)
        XCTAssertEqual(after.optimizedContent, "原始")
        XCTAssertEqual(after.recognitionMode, .online)
        XCTAssertEqual(after.archivedAt, base)
    }

    // MARK: - Identity, not spelling

    func testSourcesDifferingOnlyInCaseAreOneMerge() {
        let input = [record("甲", tags: [TaggedItem(name: "work", score: 0.9)])]

        let merged = TagMerger.merge(records: input, into: "Work", from: ["work", "WORK"])

        XCTAssertEqual(merged.first?.tagNames, ["Work"])
    }

    /// The spec's closing guarantee, stated as a test: after a merge, nothing
    /// anywhere still reports the old spelling. If this fails, the library
    /// has reached a state the UI cannot explain — a chip for a tag nothing
    /// carries.
    func testNoRecordStillReportsTheMergedAwaySpelling() {
        let vm = TranscriptionViewModel()
        vm.historyRecords = [
            record("甲", tags: [TaggedItem(name: "工作项", score: 0.9), TaggedItem(name: "会议", score: 0.3)]),
            record("乙", tags: [TaggedItem(name: "工作", score: 0.8)]),
            record("丙", tags: [TaggedItem(name: "工作项", score: 0.7)])
        ]

        vm.historyRecords = TagMerger.merge(
            records: vm.historyRecords, into: "工作", from: ["工作项"]
        )

        XCTAssertFalse(vm.availableTags.contains("工作项"))
        XCTAssertEqual(vm.availableTags, ["工作", "会议"])
        for r in vm.historyRecords {
            XCTAssertFalse(
                r.tagNames.contains { TagIdentity.key($0) == TagIdentity.key("工作项") },
                "\(r.title ?? "?") still carries the merged-away tag"
            )
        }
    }

    // MARK: - No-ops

    func testTargetAmongSourcesIsAByteIdenticalNoOp() {
        let input = [record("甲", tags: [TaggedItem(name: "工作", score: 0.9)])]

        let merged = TagMerger.merge(records: input, into: "工作", from: ["工作", "工作项"])

        XCTAssertEqual(merged, input)
    }

    func testEmptySourcesChangeNothing() {
        let input = [record("甲", tags: [TaggedItem(name: "工作项", score: 0.9)])]

        XCTAssertEqual(TagMerger.merge(records: input, into: "工作", from: []), input)
    }

    func testSourcesMatchingNothingChangeNothing() {
        let input = [record("甲", tags: [TaggedItem(name: "会议", score: 0.9)])]

        XCTAssertEqual(TagMerger.merge(records: input, into: "工作", from: ["不存在的标签"]), input)
    }

    // MARK: - Archived

    /// "These are the same thing" is a fact, not a view. If archived records
    /// kept the old spelling, the chip would reappear the moment the user
    /// switched to archive mode.
    func testArchivedRecordsAreMergedToo() {
        let input = [
            record("活的", tags: [TaggedItem(name: "工作项", score: 0.9)]),
            record("收起的", tags: [TaggedItem(name: "工作项", score: 0.6)], archived: true)
        ]

        let merged = TagMerger.merge(records: input, into: "工作", from: ["工作项"])

        XCTAssertEqual(merged.map(\.tagNames), [["工作"], ["工作"]])
    }

    // MARK: - Selection remap (spec §3)

    /// The trap this exists for: filtering by a tag you then merge away leaves
    /// `selectedTags` pointing at a name no record carries, and the library
    /// renders **empty** with no error to show.
    ///
    /// The invariant is a *superset*, not an equal count. Filtering `工作项`
    /// shows only the records spelled that way; filtering `工作` afterwards
    /// legitimately shows those plus the records already spelled `工作`,
    /// because after the merge they are the same tag. Hiding those instead
    /// would be the bug. What must never happen is the previously-visible
    /// records disappearing, or the list going empty.
    func testSelectingASourceThenMergingItKeepsThoseRecordsVisible() {
        let vm = TranscriptionViewModel()
        vm.historyRecords = [
            record("甲", tags: [TaggedItem(name: "工作项", score: 0.9)]),
            record("乙", tags: [TaggedItem(name: "工作", score: 0.8)]),
            record("丙", tags: [TaggedItem(name: "会议", score: 0.3)])
        ]

        vm.selectedTags = ["工作项"]
        let visibleBefore = Set(vm.displayedRecords.map(\.id))
        XCTAssertEqual(visibleBefore.count, 1, "only the 工作项 record matches yet")

        vm.historyRecords = TagMerger.merge(
            records: vm.historyRecords, into: "工作", from: ["工作项"]
        )
        vm.selectedTags = TagMerger.remappedSelection(
            vm.selectedTags, into: "工作", from: ["工作项"]
        )

        let visibleAfter = Set(vm.displayedRecords.map(\.id))
        XCTAssertEqual(vm.selectedTags, ["工作"])
        XCTAssertTrue(
            visibleAfter.isSuperset(of: visibleBefore),
            "a merge must never hide a record that was on screen"
        )
        XCTAssertFalse(visibleAfter.isEmpty, "the library must not render empty")
        XCTAssertEqual(visibleAfter.count, 2, "…and now 工作's own records belong here too")
    }

    func testRemapLeavesUnrelatedSelectionsAlone() {
        let selected: Set<String> = ["会议", "工作项"]

        let remapped = TagMerger.remappedSelection(selected, into: "工作", from: ["工作项"])

        XCTAssertEqual(remapped, ["会议", "工作"])
    }

    func testRemappingToAnAlreadySelectedTargetCollapsesThem() {
        let selected: Set<String> = ["工作", "工作项"]

        let remapped = TagMerger.remappedSelection(selected, into: "工作", from: ["工作项"])

        XCTAssertEqual(remapped, ["工作"], "two entries that filtered identically become one")
    }

    func testRemapIsANoOpWithNoSources() {
        let selected: Set<String> = ["工作项"]

        XCTAssertEqual(TagMerger.remappedSelection(selected, into: "工作", from: []), selected)
    }
}

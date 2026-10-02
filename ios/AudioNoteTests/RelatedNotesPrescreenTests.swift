import XCTest
@testable import AudioNote

final class RelatedNotesPrescreenTests: XCTestCase {

    private let currentID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private func record(
        id: UUID,
        tags: [TaggedItem]? = [],
        archived: Bool = false,
        status: LLMStatus? = .completed,
        createdAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> TranscriptionRecord {
        var r = TranscriptionRecord(id: id, content: "x", createdAt: createdAt)
        r.tags = tags
        r.archived = archived
        r.llmProcessingStatus = status
        return r
    }

    private let tA = TaggedItem(name: "状态管理", score: 0.9)
    private let tB = TaggedItem(name: "单例", score: 0.7)
    private let tC = TaggedItem(name: "架构", score: 0.5)

    func testSharesMoreTagsRanksHigher() {
        let current = record(id: currentID, tags: [tA, tB, tC])
        let two = record(id: UUID(), tags: [tA, tB])
        let one = record(id: UUID(), tags: [tA])
        let none = record(id: UUID(), tags: [TaggedItem(name: "别的", score: 0.9)])

        let ranked = RelatedNotesService.prescreen(current: current, among: [none, one, two])
        XCTAssertEqual(ranked.map(\.id), [two.id, one.id, none.id])
    }

    /// Zero-overlap candidates survive ranking — the feature's serendipity case
    /// ("I already said something adjacent three months ago") depends on it.
    /// They score on the recency term alone.
    func testKeepsZeroOverlapCandidatesRankedByRecency() {
        let current = record(id: currentID, tags: [tA])
        let newer = record(id: UUID(), tags: [TaggedItem(name: "别的", score: 0.9)],
                           createdAt: Date(timeIntervalSince1970: 900))
        let older = record(id: UUID(), tags: nil,
                           createdAt: Date(timeIntervalSince1970: 100))

        let ranked = RelatedNotesService.prescreen(current: current, among: [older, newer])
        XCTAssertEqual(ranked.map(\.id), [newer.id, older.id],
                       "zero-overlap candidates are kept, newer first")
    }

    func testEmptyWhenCurrentHasNoTags() {
        let current = record(id: currentID, tags: [])
        let other = record(id: UUID(), tags: [tA])
        let ranked = RelatedNotesService.prescreen(current: current, among: [other])
        XCTAssertTrue(ranked.isEmpty)
    }

    func testExcludesSelf() {
        let current = record(id: currentID, tags: [tA])
        let other = record(id: UUID(), tags: [tA])
        let ranked = RelatedNotesService.prescreen(current: current, among: [current, other])
        XCTAssertEqual(ranked.map(\.id), [other.id])
    }

    func testExcludesArchivedAndUnprocessed() {
        let current = record(id: currentID, tags: [tA])
        let archived = record(id: UUID(), tags: [tA], archived: true)
        let pending = record(id: UUID(), tags: [tA], status: .pending)
        let failed = record(id: UUID(), tags: [tA], status: .failed)
        // A record that has never been through the LLM has no status at all —
        // `Optional<LLMStatus> == LLMStatus.completed` must reject it, not trap.
        let nilStatus = record(id: UUID(), tags: [tA], status: nil)
        let ok = record(id: UUID(), tags: [tA])

        let ranked = RelatedNotesService.prescreen(current: current, among: [archived, pending, failed, nilStatus, ok])
        XCTAssertEqual(ranked.map(\.id), [ok.id], "only the completed record survives")
    }

    /// One case per comparator tier, each fed to `prescreen` in the order the
    /// *tie-break itself* has to reverse. Deleting any one tier therefore leaves
    /// the input order untouched and flips the expectation.
    func testEachComparatorTierDecidesInTurn() {
        let current = record(id: currentID, tags: [tA, tB])
        let date = Date(timeIntervalSince1970: 1_000_000)

        // Tier 1 — score. Identical `createdAt` keeps the recency term equal, so
        // the shared-tag count is the only thing that can separate these.
        let oneTag = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                            tags: [tA], createdAt: date)
        let twoTags = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                             tags: [tA, tB], createdAt: date)
        XCTAssertEqual(
            RelatedNotesService.prescreen(current: current, among: [oneTag, twoTags]).map(\.id),
            [twoTags.id, oneTag.id], "tier 1: higher score first"
        )

        // Tier 2 — `createdAt` descending. `ageDays` is clamped at 0, so future
        // dates all get recency 1.0: the score ties exactly even though the dates
        // differ, and only `createdAt` can order them.
        let futureOlder = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                                 tags: [tA], createdAt: Date(timeIntervalSince1970: 2_000_000_000))
        let futureNewer = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
                                 tags: [tA], createdAt: Date(timeIntervalSince1970: 3_000_000_000))
        XCTAssertEqual(
            RelatedNotesService.prescreen(current: current, among: [futureOlder, futureNewer]).map(\.id),
            [futureNewer.id, futureOlder.id], "tier 2: newer `createdAt` first on a genuine score tie"
        )

        // Tier 3 — `id` ascending. Same score and same `createdAt`; only the id is
        // left, and it is the same in every run, so the result is reproducible.
        let idLow = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
                           tags: [tA], createdAt: date)
        let idHigh = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!,
                            tags: [tA], createdAt: date)
        XCTAssertEqual(
            RelatedNotesService.prescreen(current: current, among: [idHigh, idLow]).map(\.id),
            [idLow.id, idHigh.id], "tier 3: id ascending on a full tie"
        )
    }

    func testCapKeepsTheHighestScoringCandidates() {
        let shared = (1...50).map { TaggedItem(name: "标签\($0)", score: 0.9) }
        let current = record(id: currentID, tags: shared)
        // Candidate i shares exactly i tags, so the score rises strictly with i.
        // "Some 20" and "the top 20" coincide only for the latter.
        let candidates = (1...50).map { i in
            record(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!,
                   tags: Array(shared.prefix(i)))
        }

        let ranked = RelatedNotesService.prescreen(current: current, among: candidates)
        XCTAssertEqual(ranked.count, RelatedNotesService.maxCandidates)
        XCTAssertEqual(ranked.map(\.id), (31...50).reversed().map { candidates[$0 - 1].id },
                       "the cap must keep the highest-scoring candidates, best rank first")
    }
}

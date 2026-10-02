import XCTest
@testable import AudioNote

final class RelatedNotesPrescreenTests: XCTestCase {

    private let currentID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private func record(
        id: UUID,
        tags: [TaggedItem]? = [],
        archived: Bool = false,
        status: LLMStatus = .completed,
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
        let noStatus = record(id: UUID(), tags: [tA], status: .failed)
        let ok = record(id: UUID(), tags: [tA])

        let ranked = RelatedNotesService.prescreen(current: current, among: [archived, pending, noStatus, ok])
        XCTAssertEqual(ranked.map(\.id), [ok.id])
    }

    func testTiesBreakOnCreatedAtDescendingAndAreDeterministic() {
        let current = record(id: currentID, tags: [tA])
        let older = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                           tags: [tA], createdAt: Date(timeIntervalSince1970: 100))
        let newer = record(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                           tags: [tA], createdAt: Date(timeIntervalSince1970: 900))

        let first = RelatedNotesService.prescreen(current: current, among: [older, newer])
        let second = RelatedNotesService.prescreen(current: current, among: [newer, older])
        XCTAssertEqual(first.map(\.id), [newer.id, older.id])
        XCTAssertEqual(first.map(\.id), second.map(\.id), "input order must not change the result")
    }

    func testCapsAtMaxCandidates() {
        let current = record(id: currentID, tags: [tA])
        let many = (0..<50).map { _ in record(id: UUID(), tags: [tA]) }
        let ranked = RelatedNotesService.prescreen(current: current, among: many)
        XCTAssertEqual(ranked.count, RelatedNotesService.maxCandidates)
    }
}

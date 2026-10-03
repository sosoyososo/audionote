import XCTest
@testable import AudioNote

final class RelatedNotesRowModelTests: XCTestCase {

    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let missing = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

    // MARK: - Builder

    private func record(
        _ id: UUID,
        title: String = "标题",
        tags: [TaggedItem] = [],
        archived: Bool = false,
        content: String = "一段足够长的预览文本用来验证 preview 的截断行为是否正确"
    ) -> TranscriptionRecord {
        var r = TranscriptionRecord(id: id, content: content, createdAt: Date(timeIntervalSince1970: 1_000_000))
        r.title = title
        r.summary = "摘要"
        r.tags = tags
        r.llmProcessingStatus = .completed
        r.archived = archived
        return r
    }

    func testSkipsEdgesPointingAtMissingRecords() {
        let rows = RelatedNotesSectionBuilder.rows(
            for: record(a),
            candidates: [record(b)],
            related: [RelatedNote(id: b, score: 0.9), RelatedNote(id: missing, score: 0.8)]
        )
        XCTAssertEqual(rows.map(\.id), [b])
    }

    func testSkipsArchivedRecords() {
        let rows = RelatedNotesSectionBuilder.rows(
            for: record(a),
            candidates: [record(b, archived: true)],
            related: [RelatedNote(id: b, score: 0.9)]
        )
        XCTAssertTrue(rows.isEmpty, "an archived note must not appear as related")
    }

    func testKeepsOnlySharedTags() {
        let current = record(a, tags: [TaggedItem(name: "状态管理", score: 0.9), TaggedItem(name: "SwiftUI", score: 0.7)])
        let other = record(b, tags: [TaggedItem(name: "状态管理", score: 0.8), TaggedItem(name: "别的", score: 0.6)])
        let rows = RelatedNotesSectionBuilder.rows(for: current, candidates: [other], related: [RelatedNote(id: b, score: 0.9)])
        // Would fail with `other.tagNames` in place of the intersection: ["状态管理", "别的"].
        XCTAssertEqual(rows.first?.sharedTags, ["状态管理"])
    }

    func testEmptySharedTagsYieldsNoTagRow() {
        let current = record(a, tags: [TaggedItem(name: "甲", score: 0.9)])
        let other = record(b, tags: [TaggedItem(name: "乙", score: 0.9)])
        let rows = RelatedNotesSectionBuilder.rows(for: current, candidates: [other], related: [RelatedNote(id: b, score: 0.9)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].sharedTags.isEmpty)
    }

    func testSurvivesNoteWithNoTitleOrSummary() {
        var bare = TranscriptionRecord(id: b, content: "只有原始内容", createdAt: Date())
        bare.llmProcessingStatus = .completed
        let rows = RelatedNotesSectionBuilder.rows(
            for: record(a),
            candidates: [bare],
            related: [RelatedNote(id: b, score: 0.9)]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].title.isEmpty, "falls back rather than rendering an empty title")
    }

    func testPreservesScoreOrdering() {
        let rows = RelatedNotesSectionBuilder.rows(
            for: record(a),
            candidates: [record(b), record(c)],
            related: [RelatedNote(id: b, score: 0.4), RelatedNote(id: c, score: 0.9)]
        )
        XCTAssertEqual(rows.map(\.id), [c, b])
    }

    // MARK: - Tie-break (Ruling W)
    //
    // `related(to:)` used to sort on score alone while `upsert` wrote
    // `Array(merged.values)` in Dictionary hash order, and Swift's hash seed is
    // per-process. Two edges tied on score could therefore swap places between
    // app launches, reshuffling the list under the user (spec §4.3/§4.4).
    //
    // The teeth of this test: it never calls `upsert` to produce the input. It
    // writes `relatedNotes.json` by hand in every one of the 4! orderings of
    // the same four tied edges. Without a tie-break, `related(to:)` returns
    // file order, so 23 of the 24 orderings come back wrong and the test fails
    // hard rather than occasionally. Two calls inside one process would have
    // false-passed: the hash seed does not change mid-process, so a
    // fresh-instance-only variant would prove nothing.

    /// Deliberately not in ascending order, so even the first permutation
    /// differs from the expected result.
    private let tied = [
        UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
        UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
        UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
        UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
    ]

    /// Ascending `uuidString`, i.e. the only order the tie-break can justify.
    private var tiedAscending: [UUID] { tied.sorted { $0.uuidString < $1.uuidString } }

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rrow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Raw JSON, so the on-disk order is exactly `order` — `upsert` would
    /// rewrite it in Dictionary order and destroy the variable under test.
    private func writeTiedEdges(in order: [UUID], at url: URL) throws {
        let rows = order
            .map { "{\"a\": \"\(a.uuidString)\", \"b\": \"\($0.uuidString)\", \"score\": 0.5}" }
            .joined(separator: ", ")
        try Data("[\(rows)]".utf8).write(to: url)
    }

    private func permutations(_ items: [UUID]) -> [[UUID]] {
        if items.count <= 1 { return [items] }
        return items.indices.flatMap { i -> [[UUID]] in
            let head = items[i]
            let rest = items.indices.filter { $0 != i }.map { items[$0] }
            return permutations(rest).map { [head] + $0 }
        }
    }

    func testRelatedBreaksScoreTiesByUUIDInEveryStoredOrdering() async throws {
        let url = tmpDir.appendingPathComponent("relatedNotes.json")
        var checked = 0
        for order in permutations(tied) {
            try writeTiedEdges(in: order, at: url)
            let store = RelatedNotesStorage(fileURL: url)
            let related = await store.related(to: a)
            let storedOrder = order.map { String($0.uuidString.prefix(4)) }.joined(separator: ",")
            XCTAssertEqual(
                related.map(\.id),
                tiedAscending,
                "tied-score order must not depend on the stored order [\(storedOrder)]"
            )
            checked += 1
        }
        XCTAssertEqual(checked, 24, "every permutation must be exercised")

        // Same assertion after a real `upsert`, whose `Array(merged.values)`
        // write order is Dictionary hash order — the other half of the leak.
        let store = RelatedNotesStorage(fileURL: tmpDir.appendingPathComponent("upserted.json"))
        try await store.upsert(tied.map { NoteRelation(a: a, b: $0, score: 0.5) })
        let afterUpsert = await store.related(to: a)
        XCTAssertEqual(afterUpsert.map(\.id), tiedAscending, "hash-order write must not leak either")
    }
}

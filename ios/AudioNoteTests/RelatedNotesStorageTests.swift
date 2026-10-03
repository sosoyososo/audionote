import XCTest
@testable import AudioNote

final class RelatedNotesStorageTests: XCTestCase {

    private var tmpDir: URL!
    private var store: RelatedNotesStorage!
    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = RelatedNotesStorage(fileURL: tmpDir.appendingPathComponent("relatedNotes.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testLoadAllReturnsEmptyWhenFileMissing() async throws {
        let all = try await store.loadAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testUpsertThenLoadRoundTrips() async throws {
        try await store.upsert([NoteRelation(a: a, b: b, score: 0.9)])
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.score ?? 0, 0.9, accuracy: 0.0001)
    }

    func testUpsertReversedOrderDoesNotDuplicate() async throws {
        try await store.upsert([NoteRelation(a: a, b: b, score: 0.9)])
        try await store.upsert([NoteRelation(a: b, b: a, score: 0.4)])
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1, "same undirected pair must not duplicate")
        XCTAssertEqual(all.first?.score ?? 0, 0.4, accuracy: 0.0001, "later write replaces the score")
    }

    func testRelatedReturnsBothSidesSortedDescending() async throws {
        try await store.upsert([
            NoteRelation(a: a, b: b, score: 0.3),
            NoteRelation(a: a, b: c, score: 0.8),
        ])
        let related = await store.related(to: a)
        XCTAssertEqual(related.map(\.id), [c, b], "descending by score")

        let fromB = await store.related(to: b)
        XCTAssertEqual(fromB.map(\.id), [a], "counterpart, not the queried id")
    }

    func testRelatedOmitsEdgesBelowMinimumScore() async throws {
        try await store.upsert([
            NoteRelation(a: a, b: b, score: 0.29),
            NoteRelation(a: a, b: c, score: RelatedNotesStorage.minimumScore),
        ])
        let related = await store.related(to: a)
        XCTAssertEqual(related.map(\.id), [c], "threshold is inclusive; 0.29 is hidden")
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 2, "hidden edges are still stored")
    }

    /// `related(to:)` carries the last `try?` in the store (Ruling M), serving
    /// spec §6's "corrupt file → treated as no relations, section hidden" — a
    /// **read/render** policy that must never block the user. This is the only
    /// test that reads through that path: flip the `try?` back to a `try` and
    /// every other test in the suite still passes, because nothing else
    /// exercises it.
    func testRelatedReturnsEmptyOnCorruptFileInsteadOfThrowing() async throws {
        let url = tmpDir.appendingPathComponent("relatedNotes.json")
        try Data("{ this is not json".utf8).write(to: url)
        let related = await store.related(to: a) // non-throwing by contract
        XCTAssertTrue(related.isEmpty, "a corrupt file renders as no relations, never as an error")
        // The read must not have repaired or truncated the file either.
        let after = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: after, as: UTF8.self), "{ this is not json")
    }

    func testRemoveAllInvolvingDropsOnlyMatchingEdges() async throws {
        try await store.upsert([
            NoteRelation(a: a, b: b, score: 0.9),
            NoteRelation(a: b, b: c, score: 0.5),
        ])
        try await store.removeAll(involving: a)
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.key, NoteRelation(a: b, b: c, score: 0).key)
    }

    func testLoadAllOnCorruptFileThrowsAndLeavesFileIntact() async throws {
        let url = tmpDir.appendingPathComponent("relatedNotes.json")
        try Data("{ this is not json".utf8).write(to: url)
        do {
            _ = try await store.loadAll()
            XCTFail("expected a decode failure")
        } catch {
            // Expected. The caller (RelatedNotesService / detail view) swallows
            // this; the point is that it throws rather than crashing.
        }
        // The malformed file must survive the failed read, not be truncated.
        let after = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: after, as: UTF8.self), "{ this is not json")
    }

    func testUpsertOnCorruptFileThrowsAndLeavesFileIntact() async throws {
        let url = tmpDir.appendingPathComponent("relatedNotes.json")
        try Data("{ this is not json".utf8).write(to: url)
        do {
            try await store.upsert([NoteRelation(a: a, b: b, score: 0.9)])
            XCTFail("expected upsert to propagate the decode failure")
        } catch {
            // Expected. The swallow belongs in the caller (`link(for:)`), not
            // here — a store that merged into an empty set would silently
            // overwrite relations that are never recomputed.
        }
        // No write may have happened: the file is still byte-for-byte intact.
        let after = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: after, as: UTF8.self), "{ this is not json")
    }

    func testUpsertWithDuplicatePairsInExistingFileDoesNotTrap() async throws {
        let url = tmpDir.appendingPathComponent("relatedNotes.json")
        // Raw JSON, not encoded NoteRelations: the normalizing `init` would
        // order both rows identically, so encoding could never produce the
        // duplicate key. §4.3 makes {a,b} and {b,a} one edge, so a hand-edited
        // file can legitimately hold both spellings.
        let aString = a.uuidString
        let bString = b.uuidString
        let json = """
        [
          {"a": "\(aString)", "b": "\(bString)", "score": 0.2},
          {"a": "\(bString)", "b": "\(aString)", "score": 0.5}
        ]
        """
        try Data(json.utf8).write(to: url)

        // Must not trap on the duplicate key.
        try await store.upsert([NoteRelation(a: a, b: c, score: 0.7)])

        // The duplicate pair collapses to one edge; the new pair is added.
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 2, "duplicate pair must collapse, new pair added")
        XCTAssertTrue(all.contains { $0.key == NoteRelation(a: a, b: c, score: 0).key })
        XCTAssertTrue(all.contains { $0.key == NoteRelation(a: a, b: b, score: 0).key })
    }
}

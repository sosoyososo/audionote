import XCTest
@testable import AudioNote

/// The batch merge: several groups, one write.
///
/// Two properties matter. The records end up right, and a group that
/// disagrees with an earlier one is skipped rather than applied on top of
/// it — two proposals that both want the same tag would otherwise produce
/// a chain of merges the user never agreed to.
final class TagMergeBatchTests: XCTestCase {

    private var tmpDir: URL!
    private var fileURL: URL!
    private var recordingsDir: URL!
    private var store: TranscriptionStorage!

    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        fileURL = tmpDir.appendingPathComponent("transcriptions.json")
        recordingsDir = tmpDir.appendingPathComponent("Recordings", isDirectory: true)
        store = TranscriptionStorage(fileURL: fileURL, recordingsDirectory: recordingsDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func makeRecord(id: UUID, tags: [String]) -> TranscriptionRecord {
        TranscriptionRecord(
            id: id,
            content: "文本",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 12,
            title: "标题",
            summary: "摘要",
            tags: tags.map { TaggedItem(name: $0, score: 1.0) }
        )
    }

    private func loadRecords() async throws -> [TranscriptionRecord] {
        try await store.loadAll()
    }

    /// The fixture writer. `saveAll` is private — the public write is one
    /// record at a time, which is what the app does too.
    private func saveRecords(_ records: [TranscriptionRecord]) async throws {
        for record in records {
            try await store.save(record)
        }
    }

    // MARK: - Tests

    func testSeveralGroupsAreAppliedAndTheRecordsAreRewritten() async throws {
        try await saveRecords([
            makeRecord(id: a, tags: ["工作项", "工作会议"]),
            makeRecord(id: b, tags: ["会议记录"]),
            makeRecord(id: c, tags: ["别的标签"])
        ])

        let outcome = try await store.mergeTags([
            TagMergeGroup(target: "工作", sources: ["工作项", "工作会议"]),
            TagMergeGroup(target: "会议", sources: ["会议记录"])
        ])

        XCTAssertEqual(outcome.applied.count, 2)
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(outcome.affectedNotes, 2)

        let records = try await loadRecords()
        let first = records.first { $0.id == a }
        XCTAssertEqual(first?.tagNames, ["工作"])
        let second = records.first { $0.id == b }
        XCTAssertEqual(second?.tagNames, ["会议"])
        let third = records.first { $0.id == c }
        XCTAssertEqual(third?.tagNames, ["别的标签"])
    }

    func testAGroupThatOverlapsAnEarlierOneIsSkipped() async throws {
        try await saveRecords([
            makeRecord(id: a, tags: ["A", "B"]),
            makeRecord(id: b, tags: ["D"])
        ])

        // The second group wants a tag the first one already consumed — but
        // it carries a source of its own, so without the overlap check it
        // would still be applied and would rewrite the second record. That
        // is what makes this case worth having: the second group is not
        // pointless, it is *disagreeing*.
        let outcome = try await store.mergeTags([
            TagMergeGroup(target: "A", sources: ["B"]),
            TagMergeGroup(target: "C", sources: ["B", "D"])
        ])

        XCTAssertEqual(outcome.applied.count, 1)
        XCTAssertEqual(outcome.skipped, 1)

        let records = try await loadRecords()
        XCTAssertEqual(records.first { $0.id == a }?.tagNames, ["A"])
        // The skipped group did not run, so D was not swallowed by C.
        XCTAssertEqual(records.first { $0.id == b }?.tagNames, ["D"])
    }

    func testAGroupThatWouldChangeNothingIsSkipped() async throws {
        try await saveRecords([makeRecord(id: a, tags: ["已有标签"])])

        let outcome = try await store.mergeTags([
            TagMergeGroup(target: "工作", sources: ["库里没有的标签"])
        ])

        XCTAssertTrue(outcome.applied.isEmpty)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.affectedNotes, 0)
    }

    func testAnEmptyRequestChangesNothing() async throws {
        try await saveRecords([makeRecord(id: a, tags: ["工作项"])])

        let outcome = try await store.mergeTags([])

        XCTAssertTrue(outcome.applied.isEmpty)
        XCTAssertEqual(outcome.skipped, 0)
        let records = try await loadRecords()
        XCTAssertEqual(records.first?.tagNames, ["工作项"])
    }

    func testASourceThatIsTheTargetItselfIsSkipped() async throws {
        try await saveRecords([makeRecord(id: a, tags: ["工作"])])

        let outcome = try await store.mergeTags([
            TagMergeGroup(target: "工作", sources: ["工作"])
        ])

        XCTAssertTrue(outcome.applied.isEmpty)
        XCTAssertEqual(outcome.skipped, 1)
    }
}

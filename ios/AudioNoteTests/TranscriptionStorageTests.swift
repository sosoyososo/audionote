import XCTest
@testable import AudioNote

/// Tests for the records-file layer: what it reports, and — more
/// importantly — what it does when the file is broken.
///
/// The corruption case is the one that matters. A file that exists but
/// cannot be parsed is not an empty library, and the difference has to
/// survive all the way to the screen, or the user concludes their data
/// is gone.
final class TranscriptionStorageTests: XCTestCase {

    private var tmpDir: URL!
    private var fileURL: URL!
    private var store: TranscriptionStorage!

    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        fileURL = tmpDir.appendingPathComponent("transcriptions.json")
        store = TranscriptionStorage(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func makeRecord(id: UUID, content: String = "文本") -> TranscriptionRecord {
        TranscriptionRecord(
            id: id,
            content: content,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 12,
            title: "标题",
            summary: "摘要",
            tags: [TaggedItem(name: "标签", score: 1.0)]
        )
    }

    private func writeRaw(_ text: String) throws {
        try Data(text.utf8).write(to: fileURL)
    }

    private func readRaw() throws -> String {
        try String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - loadOutcome

    func testLoadOutcomeReportsNoFileWhenNothingHasBeenWritten() async {
        switch await store.loadOutcome() {
        case .noFile:
            break
        case .records(let records):
            XCTFail("expected .noFile, got \(records.count) records")
        case .corrupted:
            XCTFail("expected .noFile, got .corrupted")
        }
    }

    func testLoadOutcomeReportsRecordsWhenTheFileParses() async throws {
        try await store.save(makeRecord(id: a))
        try await store.save(makeRecord(id: b))

        switch await store.loadOutcome() {
        case .records(let records):
            XCTAssertEqual(records.count, 2)
        case .noFile:
            XCTFail("expected .records, got .noFile")
        case .corrupted:
            XCTFail("expected .records, got .corrupted")
        }
    }

    func testLoadOutcomeReportsCorruptedForAnUnparseableFile() async throws {
        try writeRaw("{ this is not json")

        switch await store.loadOutcome() {
        case .corrupted:
            break
        case .noFile:
            XCTFail("expected .corrupted, got .noFile")
        case .records(let records):
            XCTFail("expected .corrupted, got \(records.count) records")
        }
    }

    func testLoadOutcomeDistinguishesAnEmptyFileFromAMissingOne() async throws {
        // A file that exists and holds an empty array is a library the user
        // emptied; a missing file is a library that was never written.
        // Both are "no records" to the user, but only one of them means
        // "your records were removed from outside the app".
        try writeRaw("[]")

        switch await store.loadOutcome() {
        case .records(let records):
            XCTAssertTrue(records.isEmpty)
        case .noFile:
            XCTFail("expected .records (empty), got .noFile")
        case .corrupted:
            XCTFail("expected .records (empty), got .corrupted")
        }
    }

    // MARK: - The data-loss regression

    /// The bug this pins: `save()` used to read the library with
    /// `(try? await loadAll()) ?? []`. A read failure became an *empty
    /// library*, and the next write replaced the whole file with the one
    /// record being saved. One corrupt file, one save, and every record
    /// the user had was gone — with a symptom indistinguishable from the
    /// user having deleted them by hand.
    func testSaveThrowsInsteadOfWipingTheLibraryWhenTheFileIsCorrupted() async throws {
        try writeRaw("{ not json at all")

        do {
            try await store.save(makeRecord(id: a))
            XCTFail("save must fail loudly rather than overwrite a library it could not read")
        } catch {
            // Expected. The important part is what follows.
        }

        let after = try readRaw()
        XCTAssertEqual(after, "{ not json at all",
                       "the unreadable file must be left exactly as it was — not replaced")
    }

    func testSaveStillWorksAfterACorruptedFileIsRepaired() async throws {
        try writeRaw("{ not json at all")
        _ = try? await store.save(makeRecord(id: a))

        // The user repairs the file by hand (or the provider hands us a
        // good copy) and we try again.
        try writeRaw("[]")
        try await store.save(makeRecord(id: b))

        switch await store.loadOutcome() {
        case .records(let records):
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.id, b)
        case .noFile, .corrupted:
            XCTFail("expected the repaired library to load")
        }
    }

    func testSaveOnAMissingFileCreatesTheLibrary() async throws {
        try await store.save(makeRecord(id: a))

        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, a)
    }

    func testSaveKeepsExistingRecords() async throws {
        try await store.save(makeRecord(id: a))
        try await store.save(makeRecord(id: b))

        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map(\.id)), Set([a, b]))
    }

    func testLoadAllThrowsOnACorruptedFile() async throws {
        try writeRaw("{ not json at all")

        do {
            _ = try await store.loadAll()
            XCTFail("loadAll must throw so callers can tell 'unreadable' from 'empty'")
        } catch {
            // Expected.
        }
    }
}

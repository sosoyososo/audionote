import XCTest
@testable import AudioNote

/// Tests for the `RecognitionMode.pending` state — "audio exists, no
/// transcript, waiting for the network". Spec §4.3.
///
/// The state itself is covered here; the *decisions* about it live in
/// `PendingRecognitionPolicy` and are covered in Tasks 2 and 3.
final class PendingRecognitionTests: XCTestCase {

    // MARK: - Enum + Codable

    func testPendingRawValueRoundTrips() throws {
        // The raw value is what lands in the user's JSON. If it ever
        // changes, every pending record already on disk fails to decode
        // and is silently dropped — exactly the bug this feature fixes.
        XCTAssertEqual(RecognitionMode.pending.rawValue, "pending")

        let encoded = try JSONEncoder().encode(RecognitionMode.pending)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"pending\"")

        let decoded = try JSONDecoder().decode(RecognitionMode.self, from: encoded)
        XCTAssertEqual(decoded, .pending)
    }

    func testLegacyRecordWithoutRecognitionModeStillDecodes() throws {
        // Review focus #3: a record written by a pre-upgrade build has no
        // `recognitionMode` key. It must decode to nil rather than throwing,
        // or every pre-existing record becomes unreadable on upgrade.
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "content": "旧版本的记录",
          "createdAt": 1700000000
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TranscriptionRecord.self, from: legacyJSON)
        XCTAssertNil(record.recognitionMode)
        XCTAssertEqual(record.content, "旧版本的记录")
    }

    func testPendingRecordRoundTripsThroughFullRecordJSON() throws {
        // The enum case surviving is not enough — the whole record must
        // round-trip, since that is the shape `TranscriptionStorage` writes.
        let record = TranscriptionRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            content: "",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            duration: 42,
            audioFileName: "22222222-2222-2222-2222-222222222222.m4a",
            recognitionMode: .pending
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TranscriptionRecord.self, from: data)

        XCTAssertEqual(decoded.recognitionMode, .pending)
        XCTAssertEqual(decoded.content, "")
        XCTAssertEqual(decoded.duration, 42)
    }
}

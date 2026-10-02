import XCTest
@testable import AudioNote

final class RelatedNotesSanitizeTests: XCTestCase {

    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let hallucinated = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

    func testDropsIdsOutsideTheCandidateSet() {
        let input = [
            RelatedNoteMatch(id: a, score: 0.9),
            RelatedNoteMatch(id: hallucinated, score: 0.95),
        ]
        let out = RelatedNotesService.sanitize(input, candidateIDs: [a, b], currentID: UUID())
        XCTAssertEqual(out.map(\.id), [a])
    }

    func testDropsTheCurrentNote() {
        // Ruling O: the storage layer does not guard self-edges, so a
        // hallucinated self-match would persist and eat a display slot.
        let input = [RelatedNoteMatch(id: a, score: 0.9), RelatedNoteMatch(id: b, score: 0.4)]
        let out = RelatedNotesService.sanitize(input, candidateIDs: [a, b], currentID: a)
        XCTAssertEqual(out.map(\.id), [b])
    }

    func testDeduplicatesKeepingHighestScore() {
        let input = [
            RelatedNoteMatch(id: a, score: 0.3),
            RelatedNoteMatch(id: a, score: 0.9),
        ]
        let out = RelatedNotesService.sanitize(input, candidateIDs: [a], currentID: UUID())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.score ?? 0, 0.9, accuracy: 0.0001)
    }

    func testCapsAtFiveStrongest() {
        let ids = (0..<9).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        let input = ids.enumerated().map { RelatedNoteMatch(id: $0.element, score: Double($0.offset) / 10) }
        let out = RelatedNotesService.sanitize(input, candidateIDs: Set(ids), currentID: UUID())
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out.map(\.score), [0.8, 0.7, 0.6, 0.5, 0.4])
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertTrue(RelatedNotesService.sanitize([], candidateIDs: [a], currentID: UUID()).isEmpty)
    }
}

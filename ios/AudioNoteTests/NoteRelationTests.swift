import XCTest
@testable import AudioNote

final class NoteRelationTests: XCTestCase {

    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testKeyIsIdenticalRegardlessOfArgumentOrder() {
        XCTAssertEqual(NoteRelation(a: a, b: b, score: 0.9).key,
                       NoteRelation(a: b, b: a, score: 0.4).key)
    }

    func testInvolvesMatchesEitherEndpoint() {
        let edge = NoteRelation(a: a, b: b, score: 0.9)
        XCTAssertTrue(edge.involves(a))
        XCTAssertTrue(edge.involves(b))
        XCTAssertFalse(edge.involves(c))
    }

    func testOtherIDReturnsTheCounterpart() {
        let edge = NoteRelation(a: a, b: b, score: 0.9)
        XCTAssertEqual(edge.otherID(from: a), b)
        XCTAssertEqual(edge.otherID(from: b), a)
        XCTAssertNil(edge.otherID(from: c))
    }

    func testRoundTripsThroughCodable() throws {
        let edge = NoteRelation(a: a, b: b, score: 0.73)
        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(NoteRelation.self, from: data)
        XCTAssertEqual(decoded.a, edge.a)
        XCTAssertEqual(decoded.b, edge.b)
        XCTAssertEqual(decoded.score, edge.score, accuracy: 0.0001)
    }
}

import XCTest
@testable import AudioNote

final class SmokeTests: XCTestCase {
    func testTaggedItemRoundTripsThroughCodable() throws {
        let item = TaggedItem(name: "状态管理", score: 0.8)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(TaggedItem.self, from: data)
        XCTAssertEqual(decoded, item)
    }
}

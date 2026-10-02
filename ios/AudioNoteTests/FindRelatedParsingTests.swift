import XCTest
@testable import AudioNote

final class FindRelatedParsingTests: XCTestCase {

    func testParsesDirectJSON() throws {
        let json = #"{"related":[{"id":"11111111-1111-1111-1111-111111111111","score":0.9}]}"#
        let out = try LLMService.parseRelated(content: json)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.score ?? 0, 0.9, accuracy: 0.0001)
    }

    func testParsesProseWrappedJSON() throws {
        let prose = """
        好的，我分析了这些候选笔记。结果如下：
        {"related":[{"id":"11111111-1111-1111-1111-111111111111","score":0.75}]}
        希望对你有帮助。
        """
        let out = try LLMService.parseRelated(content: prose)
        XCTAssertEqual(out.count, 1)
    }

    func testParsesEmptyRelatedArray() throws {
        let out = try LLMService.parseRelated(content: #"{"related":[]}"#)
        XCTAssertTrue(out.isEmpty, "no relation is a valid answer, not an error")
    }

    func testThrowsOnUnparseableContent() {
        XCTAssertThrowsError(try LLMService.parseRelated(content: "I cannot help with that."))
    }
}

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

    // MARK: - Hostile reply shapes

    func testParsesMarkdownFencedJSON() throws {
        // The prompt says 严格返回 JSON，不要任何解释或 markdown 标记 — and
        // models emit ` ```json … ``` ` anyway, often as the *only* wrapping.
        // There is no prose brace ahead of the payload here, so the balanced
        // brace scan starts at the JSON's own opening brace.
        let fenced = """
        ```json
        {"related":[{"id":"11111111-1111-1111-1111-111111111111","score":0.88}]}
        ```
        """
        let out = try LLMService.parseRelated(content: fenced)
        XCTAssertEqual(out.map(\.id.uuidString), ["11111111-1111-1111-1111-111111111111"])
        XCTAssertEqual(out.first?.score ?? 0, 0.88, accuracy: 0.0001)
    }

    func testProseBraceBeforeTheJSONLosesTheWholeReply() {
        // DOCUMENTED LIMITATION — this test pins existing behaviour, it does
        // not assert that the behaviour is desirable.
        //
        // `extractFirstJSONObject` scans from the FIRST `{` in the string, so
        // prose containing a brace before the payload makes it extract the
        // prose's braces, fail to decode, and throw. The valid JSON further
        // down is never considered. Shared with `parseOptimizeAndProcess`
        // and left alone on purpose (the extractor is pre-existing and used
        // by both); recorded here so it is a known shape rather than a
        // production surprise.
        let reply = """
        我比较了集合 {甲, 乙}，结果：
        {"related":[{"id":"11111111-1111-1111-1111-111111111111","score":0.9}]}
        """
        XCTAssertThrowsError(try LLMService.parseRelated(content: reply)) { error in
            guard case LLMError.decodingError = error else {
                return XCTFail("expected decodingError, got \(error)")
            }
        }
    }

    // MARK: - Element-wise decoding (a malformed element must not void the array)

    func testDropsMalformedElementsAndKeepsTheValidOnes() throws {
        // The whole point: three good pairs must not be cancelled by the one
        // truncated uuid sitting next to them.
        let good = "11111111-1111-1111-1111-111111111111"
        let alsoGood = "55555555-5555-5555-5555-555555555555"
        let json = """
        {"related":[
          {"id":"\(good)","score":0.91},
          {"id":"1111-11","score":0.6},
          {"id":"22222222-2222-2222-2222-222222222222","score":"0.7"},
          {"score":0.8},
          {"id":"44444444-4444-4444-4444-444444444444"},
          "garbage",
          {"id":"\(alsoGood)","score":0.42}
        ]}
        """
        let out = try LLMService.parseRelated(content: json)
        XCTAssertEqual(
            out.map(\.id.uuidString), [good, alsoGood],
            "only the truncated uuid, the string-valued score, the missing id, the missing score and the non-object should have been dropped — in that order, the valid pairs survive"
        )
        XCTAssertEqual(out.map(\.score), [0.91, 0.42])
    }

    func testEveryElementMalformedYieldsEmptyRatherThanThrowing() throws {
        let json = #"{"related":[{"id":"1111-11","score":0.9},{"id":"nope","score":0.4}]}"#
        let out = try LLMService.parseRelated(content: json)
        XCTAssertTrue(out.isEmpty, "a reply with nothing usable is 'no relation', not a decode failure")
    }

    func testMalformedElementsAreAlsoDroppedThroughTheExtractionPath() throws {
        let prose = """
        结果如下：
        {"related":[{"id":"1111-11","score":0.6},{"id":"11111111-1111-1111-1111-111111111111","score":0.77}]}
        """
        let out = try LLMService.parseRelated(content: prose)
        XCTAssertEqual(out.map(\.id.uuidString), ["11111111-1111-1111-1111-111111111111"])
    }
}

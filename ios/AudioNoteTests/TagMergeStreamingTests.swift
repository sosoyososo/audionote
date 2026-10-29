import XCTest
@testable import AudioNote

/// The server-sent-event reader and the reasoning display.
///
/// The reader is the part that has to be exactly right: a provider that
/// sends an event shape this code does not recognise must not lose the
/// answer. So every shape is either read or ignored deliberately, and
/// nothing throws.
final class TagMergeStreamingTests: XCTestCase {

    func testTheContentOfAnEventIsExtracted() {
        let line = #"data: {"choices":[{"delta":{"content":"工作"}}]}"#

        XCTAssertEqual(LLMService.sseContent(in: line), "工作")
    }

    func testALineThatIsNotDataIsIgnored() {
        XCTAssertNil(LLMService.sseContent(in: "event: message"))
        XCTAssertNil(LLMService.sseContent(in: ""))
        XCTAssertNil(LLMService.sseContent(in: ": keep-alive"))
    }

    func testTheDoneMarkerCarriesNothing() {
        XCTAssertNil(LLMService.sseContent(in: "data: [DONE]"))
    }

    func testAMalformedEventIsIgnoredRatherThanFatal() {
        XCTAssertNil(LLMService.sseContent(in: "data: {not json"))
        XCTAssertNil(LLMService.sseContent(in: "data: {\"choices\":[]}"))
        XCTAssertNil(LLMService.sseContent(in: "data: {\"choices\":[{\"delta\":{}}]}"))
    }

    func testAnEventWithoutContentCarriesNothing() {
        // The final chunk of some providers has no delta at all.
        XCTAssertNil(LLMService.sseContent(in: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#))
    }

    // MARK: - The reasoning on screen

    func testTheThinkingIsTheTextBetweenTheThinkMarkers() {
        let text = "<think>先排除录音问题\n那么候选是 工作项</think>{\"merges\":[]}"

        let thinking = TagMergeProposalSheet.thinking(from: text)

        XCTAssertTrue(thinking.contains("先排除录音问题"))
        XCTAssertFalse(thinking.contains("merges"))
    }

    func testTextWithoutThinkMarkersFallsBackToTheTail() {
        let thinking = TagMergeProposalSheet.thinking(from: "{\"merges\":[1,2,3]}")

        XCTAssertTrue(thinking.contains("merges"))
    }
}

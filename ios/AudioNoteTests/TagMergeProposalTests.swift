import XCTest
@testable import AudioNote

/// The merge proposal path: what the model is allowed to say, and what
/// happens when the user agrees to some of it.
///
/// The rule that matters throughout: **the model proposes, the user
/// disposes.** Nothing here merges without the user saying so, and the
/// parsing drops anything the library does not actually have.
final class TagMergeProposalTests: XCTestCase {

    // MARK: - Parsing the model's reply

    func testAWellFormedReplyBecomesProposals() throws {
        let content = """
        {"merges": [
          {"target": "工作", "sources": ["工作项", "工作会议"]},
          {"target": "会议纪要", "sources": ["会议记录"]}
        ]}
        """

        let proposals = try LLMService.parseTagMerges(
            content: content,
            knownCounts: ["工作": 12, "工作项": 3, "工作会议": 2, "会议纪要": 4, "会议记录": 1]
        )

        XCTAssertEqual(proposals.count, 2)
        guard proposals.count == 2 else { return }
        XCTAssertEqual(proposals[0].target, "工作")
        XCTAssertEqual(proposals[0].sources, ["工作项", "工作会议"])
        XCTAssertEqual(proposals[0].counts["工作项"], 3)
    }

    func testAMalformedEntryIsDroppedAndTheRestSurvive() throws {
        let content = """
        {"merges": [
          {"target": "工作", "sources": ["工作项"]},
          {"sources": ["缺了目标"]},
          {"target": "会议", "sources": "不是数组"},
          {"target": "会议", "sources": ["会议记录"]}
        ]}
        """

        let proposals = try LLMService.parseTagMerges(
            content: content,
            knownCounts: ["工作": 12, "工作项": 3, "会议": 5, "会议记录": 1]
        )

        XCTAssertEqual(proposals.count, 2)
        XCTAssertEqual(proposals.map(\.target), ["工作", "会议"])
    }

    func testTagsTheLibraryDoesNotHaveAreDropped() throws {
        // The model invents a tag that does not exist.
        let content = #"{"merges": [{"target": "工作", "sources": ["工作项", "编出来的标签"]}]}"#

        let proposals = try LLMService.parseTagMerges(
            content: content,
            knownCounts: ["工作": 12, "工作项": 3]
        )

        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].sources, ["工作项"])
    }

    func testATargetTheLibraryDoesNotHaveIsDropped() throws {
        // Merging into a tag that does not exist would create vocabulary,
        // and a merge does not create vocabulary.
        let content = #"{"merges": [{"target": "编出来的目标", "sources": ["工作项"]}]}"#

        let proposals = try LLMService.parseTagMerges(
            content: content,
            knownCounts: ["工作": 12, "工作项": 3]
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testASourceThatIsTheTargetItselfIsDropped() throws {
        // `Work` and the target `work` are one identity, so there is nothing
        // to merge there — only `job` is a real source.
        let content = #"{"merges": [{"target": "work", "sources": ["Work", "job"]}]}"#

        let proposals = try LLMService.parseTagMerges(
            content: content,
            knownCounts: ["work": 5, "Work": 2, "WORK": 1, "job": 3]
        )

        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.sources, ["job"])
        XCTAssertEqual(proposals.first?.counts["job"], 3)
    }

    func testAProposalThatWouldMergeATagWithItselfIsDropped() throws {
        // Every name here is the same identity, so there is no merge to do.
        let content = #"{"merges": [{"target": "work", "sources": ["Work", "WORK"]}]}"#

        let proposals = try LLMService.parseTagMerges(
            content: content,
            knownCounts: ["work": 5, "Work": 2, "WORK": 1]
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testCountsAreCountedPerIdentity() throws {
        // Two spellings of one identity: the count is the sum. (Chinese
        // traditional and simplified are *not* one identity — `TagIdentity`
        // folds case and whitespace, not scripts.)
        let content = #"{"merges": [{"target": "work", "sources": ["Job"]}]}"#

        let proposals = try LLMService.parseTagMerges(
            content: content,
            knownCounts: ["work": 5, "Work": 2, "WORK": 1, "job": 3, "Job": 1]
        )

        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.counts["Job"], 4)
    }

    func testATargetTheLibraryOnlyHasInAnotherScriptIsDropped() throws {
        // `工作項` is a different string from `工作项` — a different tag as
        // far as identity goes, so it cannot be the target of a merge.
        let content = #"{"merges": [{"target": "工作項", "sources": ["工作项"]}]}"#

        let proposals = try LLMService.parseTagMerges(
            content: content,
            knownCounts: ["工作项": 2]
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testAnEmptyReplyMeansNothingToMerge() throws {
        let proposals = try LLMService.parseTagMerges(
            content: #"{"merges": []}"#,
            knownCounts: ["工作": 1]
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testAMissingMergesKeyAlsoMeansNothingToMerge() throws {
        let proposals = try LLMService.parseTagMerges(
            content: #"{ }"#,
            knownCounts: ["工作": 1]
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    // MARK: - What a merge would cost

    func testANoteCarryingTwoOfTheTagsCountsOnce() {
        let record = TranscriptionRecord(
            id: UUID(),
            content: "文本",
            createdAt: Date(),
            duration: 1,
            title: "标题",
            summary: "摘要",
            tags: [TaggedItem(name: "工作项", score: 1.0), TaggedItem(name: "工作会议", score: 0.8)]
        )

        let proposal = TagMergeProposal(target: "工作", sources: ["工作项", "工作会议"])

        XCTAssertEqual(proposal.affectedNoteCount(in: [record]), 1)
    }
}

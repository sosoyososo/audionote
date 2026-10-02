import XCTest
@testable import AudioNote

/// Covers `LLMService.makeSystemPrompt` — the network-free half of
/// `findRelated`, extracted so it can be tested without a stub server.
final class FindRelatedPromptTests: XCTestCase {

    private func candidate(_ index: Int) -> RelatedNoteCandidate {
        RelatedNoteCandidate(
            id: UUID(uuidString: String(format: "AAAAAAAA-0000-4000-8000-%012d", index))!,
            title: "候选标题\(index)",
            summary: "候选摘要\(index)"
        )
    }

    private func candidateLines(in prompt: String) -> [String] {
        // Candidate lines are the only ones of the form `<uuid>. 标题：…`;
        // the template's own `标题：` line has no `. ` prefix.
        prompt.components(separatedBy: "\n").filter { $0.contains(". 标题：") }
    }

    func testCandidateBlockHasOneLinePerCandidateAtTheCap() {
        let candidates = (0..<RelatedNotesService.maxCandidates).map(candidate)
        let prompt = LLMService.makeSystemPrompt(
            currentTitle: "当前标题",
            currentSummary: "当前摘要",
            candidates: candidates
        )
        let lines = candidateLines(in: prompt)
        XCTAssertEqual(lines.count, RelatedNotesService.maxCandidates)
        for (index, candidate) in candidates.enumerated() {
            XCTAssertEqual(
                lines[index],
                "\(candidate.id.uuidString). 标题：\(candidate.title) 摘要：\(candidate.summary)"
            )
        }
    }

    func testTitleAndSummaryLandInTheirOwnSlots() {
        let prompt = LLMService.makeSystemPrompt(
            currentTitle: "关于向量数据库",
            currentSummary: "讨论了索引与召回",
            candidates: [candidate(0), candidate(1)]
        )
        XCTAssertTrue(prompt.contains("标题：关于向量数据库\n"), "title must land in the 标题 slot")
        XCTAssertTrue(prompt.contains("摘要：讨论了索引与召回\n"), "summary must land in the 摘要 slot")
        XCTAssertEqual(candidateLines(in: prompt).count, 2)
        for line in candidateLines(in: prompt) {
            XCTAssertFalse(line.contains("关于向量数据库"))
            XCTAssertFalse(line.contains("讨论了索引与召回"))
        }
    }

    func testPlaceholderShapedTitleDoesNotDisplaceTheCandidateBlock() {
        // A note title is model-generated text, so it can contain anything —
        // including a literal `{candidates}`. Chained whole-document
        // `replacingOccurrences` passes would re-scan it on a later pass and
        // the title would overwrite the candidate slot.
        let hostileTitle = "{candidates} ← 标题里带占位符"
        let prompt = LLMService.makeSystemPrompt(
            currentTitle: hostileTitle,
            currentSummary: "普通摘要",
            candidates: [candidate(0), candidate(1)]
        )

        XCTAssertTrue(prompt.contains("标题：\(hostileTitle)\n"), "the literal placeholder text belongs in the title slot, untouched")
        XCTAssertEqual(candidateLines(in: prompt).count, 2, "the real candidate block must not be displaced or duplicated")
        for index in 0..<2 {
            let candidate = candidate(index)
            XCTAssertTrue(
                prompt.contains("\(candidate.id.uuidString). 标题：\(candidate.title) 摘要：\(candidate.summary)"),
                "candidate \(index) must still be in the block"
            )
        }
        // The hostile token is inert: it appears once, in the title, and is
        // not expanded into the candidate list a second time.
        XCTAssertEqual(
            prompt.components(separatedBy: "\n").filter { $0.contains("{candidates}") }.count, 1
        )
    }

    func testOrdinaryFieldsProduceTheLockedPromptByteForByte() {
        // Guards the refactor: for inputs that contain no placeholder text,
        // the split-and-join must be byte-identical to the straightforward
        // replacement of the ADR-0003 prompt.
        let candidates = [candidate(0), candidate(1)]
        let block = candidates
            .map { "\($0.id.uuidString). 标题：\($0.title) 摘要：\($0.summary)" }
            .joined(separator: "\n")
        let expected = LLMService.findRelatedPrompt
            .replacingOccurrences(of: "{title}", with: "标题甲")
            .replacingOccurrences(of: "{summary}", with: "摘要乙")
            .replacingOccurrences(of: "{candidates}", with: block)

        let actual = LLMService.makeSystemPrompt(
            currentTitle: "标题甲",
            currentSummary: "摘要乙",
            candidates: candidates
        )
        XCTAssertEqual(actual, expected)
        XCTAssertFalse(actual.contains("{title}"))
        XCTAssertFalse(actual.contains("{summary}"))
        XCTAssertFalse(actual.contains("{candidates}"))
    }

    func testEmptyCandidateListLeavesAnEmptyBlock() {
        let prompt = LLMService.makeSystemPrompt(
            currentTitle: "T",
            currentSummary: "S",
            candidates: []
        )
        XCTAssertTrue(candidateLines(in: prompt).isEmpty)
        XCTAssertFalse(prompt.contains("{candidates}"))
    }
}

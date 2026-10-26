import XCTest
@testable import AudioNote

/// Tests for the record derivation behind `TranscriptionViewModel.updateRecord`.
///
/// The decision lives in `PendingRecognitionPolicy.mergedRecord`; this file
/// pins it. The bug these tests were written for: `RecordingView.saveEditedText`
/// builds a fresh `TranscriptionRecord` carrying only the text fields, and
/// `updateRecord` believed it — so editing a transcript on the recording
/// screen deleted the note's title, summary, tags and LLM status. Because
/// `handEditMarker` then marks the record hand-edited, `llmQueue` excludes
/// it forever, so nothing would put the metadata back.
final class UpdateRecordMergeTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRecord(
        content: String = "转写文本",
        title: String? = nil,
        summary: String? = nil,
        tags: [TaggedItem]? = nil,
        llmStatus: LLMStatus? = nil,
        optimizedContent: String? = nil,
        mode: RecognitionMode? = .online,
        audioFileName: String? = "uuid.m4a",
        archived: Bool = false,
        archivedAt: Date? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1700000000)
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            content: content,
            createdAt: createdAt,
            duration: 30,
            language: "zh-CN",
            audioFileName: audioFileName,
            title: title,
            summary: summary,
            tags: tags,
            llmProcessingStatus: llmStatus,
            optimizedContent: optimizedContent,
            recognitionMode: mode,
            archived: archived,
            archivedAt: archivedAt
        )
    }

    /// The shape `RecordingView.saveEditedText` builds: a record carrying
    /// only the text fields, with no knowledge of the LLM metadata that
    /// `processWithLLM` wrote earlier.
    private func makeTextOnlyRecord(content: String) -> TranscriptionRecord {
        TranscriptionRecord(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            content: content,
            createdAt: Date(),
            duration: 30,
            language: "zh-CN",
            recognitionMode: .online
        )
    }

    // MARK: - The LLM fields — the bug

    func testEditingTheTextDoesNotWipeTheStoredLLMMetadata() {
        // The regression this file exists for. The stored record carries the
        // LLM's title, summary, tags and `.completed` status; the incoming
        // record knows nothing about them. Merging must not delete them.
        let existing = makeRecord(
            content: "优化后的文本",
            title: "周会纪要",
            summary: "讨论了下周的排期",
            tags: [TaggedItem(name: "会议", score: 0.9)],
            llmStatus: .completed,
            optimizedContent: "优化前的文本"
        )
        let incoming = makeTextOnlyRecord(content: "用户改过的文本")

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertEqual(merged.title, "周会纪要")
        XCTAssertEqual(merged.summary, "讨论了下周的排期")
        XCTAssertEqual(merged.tags?.map(\.name), ["会议"])
        XCTAssertEqual(merged.llmProcessingStatus, .completed)
    }

    func testTheLLMStatusSurvivesSoTheOptimizedBadgeStays() {
        // The 优化后 badge is gated on `llmProcessingStatus == .completed`
        // and never on the hand-edit predicate (see ADR-0005). If the status
        // were dropped on an edit, an LLM-optimized note would stop
        // advertising that it had been optimized.
        let existing = makeRecord(content: "优化后的文本", llmStatus: .completed)
        let incoming = makeTextOnlyRecord(content: "用户改过的文本")

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertEqual(merged.llmProcessingStatus, .completed)
    }

    func testTheCallersOwnLLMFieldsWin() {
        // `reprocessRecord` re-runs the LLM and sends the new title, summary
        // and tags. Those must land — the caller stated them.
        let existing = makeRecord(
            title: "旧标题",
            summary: "旧摘要",
            tags: [TaggedItem(name: "旧标签", score: 0.5)],
            llmStatus: .completed
        )
        let incoming = makeRecord(
            content: "优化后的文本",
            title: "新标题",
            summary: "新摘要",
            tags: [TaggedItem(name: "新标签", score: 0.8)],
            llmStatus: .completed
        )

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertEqual(merged.title, "新标题")
        XCTAssertEqual(merged.summary, "新摘要")
        XCTAssertEqual(merged.tags?.map(\.name), ["新标签"])
        XCTAssertEqual(merged.llmProcessingStatus, .completed)
    }

    func testEachLLMFieldIsCarriedIndependently() {
        // Not all-or-nothing: a caller that states one field and omits the
        // rest must not be read as "clear the rest".
        let existing = makeRecord(
            title: "旧标题",
            summary: "旧摘要",
            tags: [TaggedItem(name: "旧标签", score: 0.5)],
            llmStatus: .completed
        )
        let incoming = makeRecord(content: "文本", title: "新标题")

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertEqual(merged.title, "新标题")
        XCTAssertEqual(merged.summary, "旧摘要")
        XCTAssertEqual(merged.tags?.map(\.name), ["旧标签"])
        XCTAssertEqual(merged.llmProcessingStatus, .completed)
    }

    func testAnEmptyTagListIsAStatedValueAndClearsTheTags() {
        // The other half of "believe the caller": an empty array is a value,
        // not an absence. A reprocess that produced no tags must not leave
        // the old ones behind.
        let existing = makeRecord(tags: [TaggedItem(name: "旧标签", score: 0.5)])
        let incoming = makeRecord(content: "文本", tags: [])

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertEqual(merged.tags, [])
    }

    func testANewRecordKeepsEverythingTheCallerStated() {
        // Nothing stored yet — no crash, and no invention.
        let incoming = makeRecord(
            content: "刚录的",
            title: "标题",
            llmStatus: .completed
        )

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: nil)

        XCTAssertEqual(merged.title, "标题")
        XCTAssertEqual(merged.llmProcessingStatus, .completed)
        XCTAssertEqual(merged.content, "刚录的")
        XCTAssertNil(merged.optimizedContent)
    }

    // MARK: - The record facts — unchanged by the LLM fix

    func testTheCreatedAtAndAudioFileSurviveAnEdit() {
        // Pre-existing behaviour, kept here so the LLM change cannot quietly
        // disturb it: an edit must not reorder the library or break playback.
        let createdAt = Date(timeIntervalSince1970: 1600000000)
        let existing = makeRecord(
            content: "原文",
            audioFileName: "uuid.m4a",
            createdAt: createdAt
        )
        let incoming = makeTextOnlyRecord(content: "用户改过的文本")

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertEqual(merged.createdAt, createdAt)
        XCTAssertEqual(merged.audioFileName, "uuid.m4a")
    }

    func testTheArchiveStateSurvivesAnEdit() {
        let archivedAt = Date(timeIntervalSince1970: 1650000000)
        let existing = makeRecord(archived: true, archivedAt: archivedAt)
        let incoming = makeTextOnlyRecord(content: "用户改过的文本")

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertTrue(merged.archived)
        XCTAssertEqual(merged.archivedAt, archivedAt)
    }

    func testTheRecognitionModeSurvivesAnEdit() {
        // The caller that does not know about the mode must not lose it.
        let existing = makeRecord(mode: .pending)
        let incoming = makeRecord(content: "用户改过的文本", mode: nil)

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertEqual(merged.recognitionMode, .pending)
    }

    func testTheCallersOwnRecognitionModeWins() {
        // The other half: a caller that states the mode is believed, even
        // when the stored record says something else.
        let existing = makeRecord(mode: .pending)
        let incoming = makeRecord(content: "用户改过的文本", mode: .enhanced)

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertEqual(merged.recognitionMode, .enhanced)
    }

    // MARK: - The hand-edit marker — unchanged by the LLM fix

    func testAnEditedTextStampsThePreEditTextAsTheMarker() {
        // The marker is what makes `isHandEdited` true, which is what keeps
        // the automatic sweeps from overwriting the user's text.
        let existing = makeRecord(content: "原始内容")
        let incoming = makeTextOnlyRecord(content: "用户改过的内容")

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertEqual(merged.optimizedContent, "原始内容")
        XCTAssertTrue(PendingRecognitionPolicy.isHandEdited(merged))
    }

    func testAnUnchangedTextCarriesTheExistingMarkerForward() {
        // A re-save that changes nothing must not manufacture a marker —
        // that would freeze the record out of every automatic route.
        let existing = makeRecord(
            content: "内容",
            optimizedContent: "更早的原文本"
        )
        let incoming = makeRecord(content: "内容")

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertEqual(merged.optimizedContent, "更早的原文本")
    }

    func testAnEditedRecordIsStillExcludedFromTheLLMQueue() {
        // The reason the metadata loss is unrecoverable, stated as an
        // assertion so a future change to the queue cannot quietly undo it.
        let existing = makeRecord(
            content: "原始内容",
            title: "周会纪要",
            llmStatus: .completed
        )
        let incoming = makeTextOnlyRecord(content: "用户改过的内容")

        let merged = PendingRecognitionPolicy.mergedRecord(
            incoming: incoming, existing: existing)

        XCTAssertTrue(PendingRecognitionPolicy.isHandEdited(merged))
        XCTAssertTrue(PendingRecognitionPolicy.llmQueue(from: [merged]).isEmpty)
    }
}

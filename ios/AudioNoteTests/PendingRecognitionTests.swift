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
        // `audioFileName` is the field `recognitionRetryQueue` filters on, so
        // losing it through the encode/decode cycle would silently turn a
        // recoverable pending record into one that can never be retried.
        XCTAssertEqual(decoded.audioFileName,
                       "22222222-2222-2222-2222-222222222222.m4a")
    }

    // MARK: - classify()

    func testClassifyDiscardsWhenUserWasActuallySilent() {
        // Review focus #1. No error and no text = the user said nothing.
        // Saving this would put a "待识别" row in their list for a
        // recording with no content, and the 2026-04-09 skip-empty spec
        // exists precisely to avoid feeding meaningless records onward.
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: false, trimmedContent: "",
                recognizerMode: .online),
            .discard
        )
    }

    func testClassifyTreatsWhitespaceOnlyContentAsNoText() {
        // A string of spaces is not a transcript, so it must fall through
        // the "no text" branch exactly like `""` does — which with a
        // recognizer error means `.pending`, not `.discard` (spec §4.2: the
        // predicate is `trimmedContent.isEmpty` *after* trimming, and
        // error + no text is the case worth keeping because the audio is
        // already on disk). The caller always passes a trimmed string, so
        // this is a guard on the invariant rather than a live path.
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: true, trimmedContent: "   \n\t ",
                recognizerMode: .online),
            .save(.pending)
        )
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: false, trimmedContent: "   \n\t ",
                recognizerMode: .online),
            .discard
        )
    }

    func testClassifySavesPendingWhenRecognizerFailedButUserSpoke() {
        // The bug being fixed. `hasRecognitionError == true` with no text
        // means the recognizer died — the user may well have spoken, and
        // the audio is on disk. Discarding it is what stranded the .m4a
        // with no record pointing at it.
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: true, trimmedContent: "",
                recognizerMode: .online),
            .save(.pending)
        )
    }

    func testClassifySavesRecognizerModeWhenThereIsText() {
        // A record with a transcript is a normal record. The error flag must
        // not change that — the framework can fail *after* producing usable
        // text, and the VM already handles that by treating it as on-device.
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: true, trimmedContent: "今天讨论了三个方案",
                recognizerMode: .online),
            .save(.onDevice)
        )

        // The no-error path returns the recognizer's own mode, NOT a hardcoded
        // `.online`. Offline + successful on-device recognition must stay
        // `.onDevice`: that is what keeps the connectivity gate in
        // `assessAndEnhance` and the upgrade filter in `networkDidRecover`
        // matching this record.
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: false, trimmedContent: "hello",
                recognizerMode: .online),
            .save(.online)
        )
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: false, trimmedContent: "今天讨论了三个方案",
                recognizerMode: .onDevice),
            .save(.onDevice)
        )
    }

    // MARK: - llmQueue()

    private func makeRecord(mode: RecognitionMode?,
                            content: String,
                            llmStatus: LLMStatus? = nil,
                            audioFileName: String? = "some-uuid.m4a") -> TranscriptionRecord {
        TranscriptionRecord(
            id: UUID(),
            content: content,
            createdAt: Date(timeIntervalSince1970: 1700000000),
            duration: 30,
            audioFileName: audioFileName,
            llmProcessingStatus: llmStatus,
            recognitionMode: mode
        )
    }

    func testLlmQueueExcludesPendingRecords() {
        // Review focus #4 — the load-bearing exclusion of the whole
        // feature. A pending record has llmProcessingStatus == nil and an
        // empty content, so the pre-existing filter swept it up and fed
        // "" to the LLM, which answers with a confident hallucination.
        let pending = makeRecord(mode: .pending, content: "")
        let normal = makeRecord(mode: .onDevice, content: "真正的转写文本")

        let queue = PendingRecognitionPolicy.llmQueue(from: [pending, normal])

        XCTAssertEqual(queue.map(\.id), [normal.id])
        XCTAssertFalse(queue.contains { $0.recognitionMode == .pending })
    }

    func testLlmQueueStillIncludesFailedStatusRecordsWithText() {
        // The exclusion must be narrow. A record that has real text and an
        // LLM failure still needs retrying — that is step 4's job.
        let failed = makeRecord(mode: .onDevice, content: "有文本", llmStatus: .failed)
        let queue = PendingRecognitionPolicy.llmQueue(from: [failed])
        XCTAssertEqual(queue.map(\.id), [failed.id])
    }

    func testLlmQueueIncludesLegacyRecordWithNilMode() {
        // Review focus #3, second half: a pre-upgrade record has
        // recognitionMode == nil. Excluding only `.pending` (and not
        // "anything not online") keeps it eligible.
        let legacy = makeRecord(mode: nil, content: "旧记录")
        let queue = PendingRecognitionPolicy.llmQueue(from: [legacy])
        XCTAssertEqual(queue.map(\.id), [legacy.id])
    }

    // MARK: - recognitionRetryQueue()

    func testRecognitionRetryQueueIncludesPendingAndFailed() {
        // Both states mean "transcript missing, audio on disk", and both
        // are worth re-running. Unlimited retries by design (spec D4).
        let pending = makeRecord(mode: .pending, content: "")
        let failed = makeRecord(mode: .failed, content: "")
        let healthy = makeRecord(mode: .online, content: "已经好了")

        let queue = PendingRecognitionPolicy.recognitionRetryQueue(
            from: [pending, failed, healthy])

        XCTAssertEqual(Set(queue.map(\.id)), Set([pending.id, failed.id]))
    }

    func testRecognitionRetryQueueRequiresAudioOnDisk() {
        // Without an .m4a there is nothing to re-recognize; retrying would
        // just spin. This guard already exists in the VM and is preserved.
        let noAudio = makeRecord(mode: .pending, content: "", audioFileName: nil)
        let queue = PendingRecognitionPolicy.recognitionRetryQueue(from: [noAudio])
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - isLLMEligible()

    func testLlmEligibilityRejectsEmptyText() {
        // Guard (b). There are two LLM routes and both refuse text that
        // carries no information: `processWithLLM` in the VM, and
        // `TranscriptionDetailView.reprocessRecord`, which calls
        // `optimizeAndProcess` directly and so carries its own copy of
        // the guard. `""` is not a safe no-op input for either one: the
        // model answers it with a confident invented title, summary and
        // tags, which are then written over the record.
        XCTAssertFalse(PendingRecognitionPolicy.isLLMEligible(text: ""))
    }

    func testLlmEligibilityRejectsWhitespaceOnlyText() {
        // Same rule as `classify`: whitespace is not a transcript. A
        // transcript of nothing but spaces would otherwise sail past a bare
        // `isEmpty` check and buy the same hallucination.
        XCTAssertFalse(PendingRecognitionPolicy.isLLMEligible(text: "   "))
        XCTAssertFalse(PendingRecognitionPolicy.isLLMEligible(text: "\n\t \r\n"))
    }

    func testLlmEligibilityAcceptsRealText() {
        // The guard must not be a de-facto offline switch: a real transcript
        // is still eligible, including one that is only *padded* with
        // whitespace.
        XCTAssertTrue(PendingRecognitionPolicy.isLLMEligible(text: "今天讨论了三个方案"))
        XCTAssertTrue(PendingRecognitionPolicy.isLLMEligible(text: "  hello  "))
        XCTAssertTrue(PendingRecognitionPolicy.isLLMEligible(text: "."))
    }

    func testLlmEligibilityRejectsTheEmptyTextAPendingRetryCanProduce() {
        // The exact value the hole would have sent. A retry that came back
        // empty must be rejected here, and — via the same predicate in
        // `retryRecognitionFromFile` — must not advance the record's mode
        // either, so it stays in `recognitionRetryQueue` for a later attempt.
        // Only the decision is asserted here; that wiring is covered by Task
        // 8 device verification.
        XCTAssertFalse(
            PendingRecognitionPolicy.isLLMEligible(
                text: makeRecord(mode: .pending, content: "").content)
        )
    }
}

import XCTest
@testable import AudioNote

/// Tests for the launch recovery sweep's candidate selection.
///
/// The view model wires its collaborators as `private let` singletons, so
/// it cannot be unit-tested. The decisions that matter — which records
/// want an LLM pass, which want a re-recognition, and which of them the
/// launch sweep is allowed to touch — are therefore pure functions on
/// `PendingRecognitionPolicy`, and that is what is tested here.
final class LaunchRecoverySweepTests: XCTestCase {

    // MARK: - Helpers

    private func record(
        id: UUID = UUID(),
        content: String = "一段转写文本",
        createdAt: Date = Date(),
        audioFileName: String? = nil,
        llmProcessingStatus: LLMStatus? = nil,
        optimizedContent: String? = nil,
        recognitionMode: RecognitionMode? = .online
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            id: id,
            content: content,
            createdAt: createdAt,
            audioFileName: audioFileName,
            llmProcessingStatus: llmProcessingStatus,
            optimizedContent: optimizedContent,
            recognitionMode: recognitionMode
        )
    }

    // MARK: - The three-way split

    func testRecoveryCandidatesSplitsTheLibraryThreeWays() {
        let never = record(content: "从未处理")
        let failed = record(content: "LLM 失败", llmProcessingStatus: .failed)
        let stuck = record(content: "调用被杀", llmProcessingStatus: .processing)
        let pending = record(content: "", audioFileName: "a.m4a", recognitionMode: .pending)
        let done = record(content: "已完成", llmProcessingStatus: .completed)

        let candidates = PendingRecognitionPolicy.recoveryCandidates(
            from: [never, failed, stuck, pending, done]
        )

        XCTAssertEqual(candidates.neverProcessed.map(\.id), [never.id])
        XCTAssertEqual(candidates.unfinishedLLM.map(\.id), [failed.id, stuck.id])
        XCTAssertEqual(candidates.recognitionRetry.map(\.id), [pending.id])
    }

    /// A record whose LLM pass finished is not work in progress. It must
    /// not be handed to the model again.
    func testCompletedRecordsAreNotCandidates() {
        let done = record(content: "已完成", llmProcessingStatus: .completed)
        let pool = PendingRecognitionPolicy.llmPool(from: [done], limit: nil)
        XCTAssertTrue(pool.isEmpty)
    }

    /// A record left at `.processing` has nothing in flight to finish it —
    /// the app was killed between writing the status and writing the
    /// outcome. Nothing else in the app would ever move it, so the sweep
    /// has to.
    func testRecordsStuckInProcessingArePickedUp() {
        let stuck = record(content: "调用被杀", llmProcessingStatus: .processing)
        let candidates = PendingRecognitionPolicy.recoveryCandidates(from: [stuck])
        XCTAssertEqual(candidates.unfinishedLLM.map(\.id), [stuck.id])
        XCTAssertTrue(candidates.neverProcessed.isEmpty)
    }

    /// ADR-0005: a `.pending` record has no transcript, and feeding it to
    /// the model produces a hallucinated summary. It must never reach an
    /// LLM path.
    func testPendingRecordsNeverReachTheLLMPool() {
        let pending = record(content: "", audioFileName: "a.m4a", recognitionMode: .pending)
        let candidates = PendingRecognitionPolicy.recoveryCandidates(from: [pending])
        XCTAssertTrue(candidates.neverProcessed.isEmpty)
        XCTAssertTrue(candidates.unfinishedLLM.isEmpty)
        // It does need a re-recognition, though.
        XCTAssertEqual(candidates.recognitionRetry.map(\.id), [pending.id])
    }

    /// The automatic passes write over `content`, so a record whose text
    /// has diverged from its source is a record the sweep would keep
    /// overwriting without ever asking.
    func testHandEditedRecordsAreLeftAlone() {
        let edited = record(content: "用户改过的文本", optimizedContent: "原始文本")
        let candidates = PendingRecognitionPolicy.recoveryCandidates(from: [edited])
        XCTAssertTrue(candidates.neverProcessed.isEmpty)
        XCTAssertTrue(candidates.unfinishedLLM.isEmpty)
        XCTAssertTrue(candidates.recognitionRetry.isEmpty)
    }

    // MARK: - The network-recovery regression guarantee

    /// The uncapped pool is what the network-recovery sweep uses, and it
    /// must select exactly what its two LLM steps selected before the
    /// refactor, in the same order. The order is the input order, which
    /// is `loadAll()`'s order.
    func testTheUncappedPoolKeepsTheNetworkRecoveryBehaviour() {
        let records = [
            record(content: "A", llmProcessingStatus: nil),
            record(content: "B", llmProcessingStatus: .failed),
            record(content: "C", llmProcessingStatus: .completed),
            record(content: "D", llmProcessingStatus: nil)
        ]
        let pool = PendingRecognitionPolicy.llmPool(from: records, limit: nil)
        XCTAssertEqual(pool.map(\.content), ["A", "B", "D"])
    }

    /// The uncapped pool must not re-sort. Re-ordering the network
    /// sweep's queue would change which records get a network connection
    /// first, for no reason.
    func testTheUncappedPoolDoesNotReorder() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = (0..<5).map { i in
            record(
                content: "R\(i)",
                createdAt: base.addingTimeInterval(-Double(i) * 60),
                llmProcessingStatus: nil
            )
        }
        let pool = PendingRecognitionPolicy.llmPool(from: records, limit: nil)
        XCTAssertEqual(pool.map(\.content), ["R0", "R1", "R2", "R3", "R4"])
    }

    // MARK: - The cap

    func testTheCapKeepsTheOldestFirst() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = (0..<15).map { i in
            record(
                content: "R\(i)",
                createdAt: base.addingTimeInterval(Double(i) * 60),
                llmProcessingStatus: nil
            )
        }
        let pool = PendingRecognitionPolicy.llmPool(from: records, limit: 10)
        XCTAssertEqual(pool.count, 10)
        XCTAssertEqual(pool.first?.content, "R0")
        XCTAssertEqual(pool.last?.content, "R9")
    }

    /// The cap is a budget for the whole sweep, not a budget per bucket.
    /// Six never-processed and six failed is twelve records of work, and
    /// the launch sweep only has room for ten.
    func testTheCapCoversBothLLMBucketsTogether() {
        let records = (0..<6).map { record(content: "N\($0)", llmProcessingStatus: nil) }
            + (0..<6).map { record(content: "F\($0)", llmProcessingStatus: .failed) }
        let candidates = PendingRecognitionPolicy.recoveryCandidates(from: records, llmLimit: 10)
        XCTAssertEqual(
            candidates.neverProcessed.count + candidates.unfinishedLLM.count,
            10
        )
    }

    /// Re-recognition is Apple's speech service, not a paid API, and
    /// ADR-0005 §4.6 requires retries to be unlimited. The LLM cap must
    /// not bound them.
    func testTheLLMLimitDoesNotBoundRecognitionRetries() {
        let records = (0..<12).map { i in
            record(
                content: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                audioFileName: "a\(i).m4a",
                recognitionMode: .pending
            )
        }
        let candidates = PendingRecognitionPolicy.recoveryCandidates(
            from: records,
            llmLimit: PendingRecognitionPolicy.launchLLMLimit
        )
        XCTAssertEqual(candidates.recognitionRetry.count, 12)
        XCTAssertTrue(candidates.neverProcessed.isEmpty)
        XCTAssertTrue(candidates.unfinishedLLM.isEmpty)
    }

    /// The launch sweep is unattended, so its cost has to be bounded. The
    /// value is pinned here so that changing it is a deliberate act.
    func testTheLaunchLimitIsTen() {
        XCTAssertEqual(PendingRecognitionPolicy.launchLLMLimit, 10)
    }

    /// A limit larger than the pool is not an error, and a limit of zero
    /// is an empty sweep rather than an unlimited one.
    func testTheCapHandlesOversizedAndEmptyPools() {
        let records = (0..<3).map { record(content: "R\($0)", llmProcessingStatus: nil) }
        XCTAssertEqual(
            PendingRecognitionPolicy.llmPool(from: records, limit: 100).count,
            3
        )
        XCTAssertTrue(
            PendingRecognitionPolicy.llmPool(from: records, limit: 0).isEmpty
        )
    }
}

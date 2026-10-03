import XCTest
@testable import AudioNote

/// Wiring tests for `RelatedNotesService.link(for:)` — the only place that
/// composes prescreen → LLM → sanitize → persist.
///
/// The LLM is stubbed, so nothing here touches the network. The one piece of
/// global state `link(for:)` reads is the active provider profile, so each test
/// installs one and removes it again (see `setUp` / `tearDown`).
final class RelatedNotesLinkTests: XCTestCase {

    private var tmpDir: URL!
    private var relations: RelatedNotesStorage!
    private var testProfileID: UUID!

    override func setUp() async throws {
        try await super.setUp()

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        relations = RelatedNotesStorage(fileURL: tmpDir.appendingPathComponent("relatedNotes.json"))

        // Production `link(for:)` reads the active profile from the store the
        // same way `TranscriptionViewModel.processWithLLM` does, so a test
        // that is meant to reach the LLM has to install one. `requiresAPIKey:
        // false` with a nil key keeps this out of the Keychain entirely.
        let profile = LLMProviderProfile(
            displayName: "link-tests",
            baseURL: URL(string: "http://localhost:11434/v1/chat/completions")!,
            model: "test-model",
            requiresAPIKey: false
        )
        testProfileID = profile.id
        try await MainActor.run {
            try ProviderProfileStore.shared.upsert(profile, apiKey: nil)
        }
    }

    override func tearDown() async throws {
        if let testProfileID {
            await MainActor.run {
                try? ProviderProfileStore.shared.delete(testProfileID)
            }
        }
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func tagged(_ names: [String], archived: Bool = false) -> TranscriptionRecord {
        let id = UUID()
        var r = TranscriptionRecord(id: id, content: "content for \(id)", createdAt: Date())
        r.title = "标题 \(id)"
        r.summary = "摘要 \(id)"
        r.tags = names.enumerated().map { TaggedItem(name: $0.element, score: 0.9 - Double($0.offset) * 0.1) }
        r.llmProcessingStatus = .completed
        r.archived = archived
        return r
    }

    /// Spec §6: "Fewer than 3 candidates → return before calling the LLM."
    /// Two candidates is under the bar, so the call must not be spent at all —
    /// asserted on the stub's `callCount`, not just on the empty edge set.
    func testLinkDoesNothingWhenTooFewCandidates() async throws {
        let current = tagged(["a", "b"])
        let x = tagged(["a", "b"])
        let y = tagged(["a", "c"])

        let llm = StubLLM(returns: [RelatedNoteMatch(id: x.id, score: 0.9)])
        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [current, x, y]),
            llm: llm
        )

        await service.link(for: current.id)

        let edges = try await relations.loadAll()
        XCTAssertTrue(edges.isEmpty, "fewer than minimumCandidates must not write an edge")
        XCTAssertEqual(llm.callCount, 0, "the LLM call is the expensive step and must be skipped")
    }

    /// Exactly at the bar (3 candidates) the call *is* spent, exactly once, and
    /// every match the model returned becomes one edge.
    func testLinkWritesOneEdgePerMatch() async throws {
        let current = tagged(["a", "b", "c"])
        let x = tagged(["a", "b"])
        let y = tagged(["a", "c"])
        let z = tagged(["a", "b"])

        let llm = StubLLM(returns: [
            RelatedNoteMatch(id: x.id, score: 0.9),
            RelatedNoteMatch(id: y.id, score: 0.5),
            RelatedNoteMatch(id: z.id, score: 0.7),
        ])
        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [current, x, y, z]),
            llm: llm
        )

        await service.link(for: current.id)

        let edges = try await relations.loadAll()
        XCTAssertEqual(edges.count, 3)
        XCTAssertEqual(llm.callCount, 1, "one call for the whole batch, never one per candidate")
        XCTAssertTrue(edges.allSatisfy { $0.involves(current.id) })
    }

    /// Re-linking the same note merges rather than appends: `upsert` replaces
    /// the score on an existing undirected pair (§4.3).
    func testLinkIsIdempotent() async throws {
        let current = tagged(["a", "b"])
        let x = tagged(["a", "b"])
        let y = tagged(["a", "b"])
        let z = tagged(["a", "b"])

        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [current, x, y, z]),
            llm: StubLLM(returns: [RelatedNoteMatch(id: x.id, score: 0.8)])
        )

        await service.link(for: current.id)
        await service.link(for: current.id)

        let edges = try await relations.loadAll()
        XCTAssertEqual(edges.count, 1, "re-linking must not duplicate the edge")
    }

    /// Spec §6: "findRelated throws or returns junk → no edge written, no error
    /// surfaced." `link(for:)` is `async` and non-throwing by contract.
    func testLLMFailureLeavesNoEdgesAndDoesNotThrow() async throws {
        let current = tagged(["a", "b", "c"])
        let x = tagged(["a", "b"])
        let y = tagged(["a", "c"])
        let z = tagged(["a", "b"])

        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [current, x, y, z]),
            llm: StubLLM(error: LLMError.decodingError)
        )

        await service.link(for: current.id) // must not throw

        let edges = try await relations.loadAll()
        XCTAssertTrue(edges.isEmpty)
    }

    /// An archived note is filtered out by `prescreen` and therefore never
    /// reaches the model at all — asserted on what the stub was *offered*,
    /// not merely on the absence of an edge.
    func testArchivedCandidateIsNeverSent() async throws {
        let current = tagged(["a", "b", "c"])
        let live = tagged(["a", "b"])
        let alsoLive = tagged(["a", "b"])
        let thirdLive = tagged(["a", "c"])
        let archived = tagged(["a", "c"], archived: true)

        let llm = StubLLM(returns: [RelatedNoteMatch(id: live.id, score: 0.8)])
        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [current, live, alsoLive, thirdLive, archived]),
            llm: llm
        )

        await service.link(for: current.id)

        XCTAssertEqual(llm.callCount, 1)
        XCTAssertEqual(llm.lastCandidateIDs.count, 3,
                       "exactly the three live candidates reach the model")
        XCTAssertFalse(llm.lastCandidateIDs.contains(archived.id),
                       "an archived note must never be sent to the LLM")
        let edges = try await relations.loadAll()
        XCTAssertFalse(edges.contains { $0.involves(archived.id) })
    }

    /// A model reply is adversarial input: ids it invented, its own id, and
    /// duplicates must all be dropped before anything is persisted (§6).
    func testHallucinatedAndDuplicateIdsNeverReachStorage() async throws {
        let current = tagged(["a", "b", "c"])
        let x = tagged(["a", "b"])
        let y = tagged(["a", "c"])
        let z = tagged(["a", "b"])
        let invented = UUID()

        let llm = StubLLM(returns: [
            RelatedNoteMatch(id: x.id, score: 0.4),
            RelatedNoteMatch(id: x.id, score: 0.9),   // duplicate, weaker
            RelatedNoteMatch(id: current.id, score: 0.99), // self
            RelatedNoteMatch(id: invented, score: 0.95),   // never offered
        ])
        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [current, x, y, z]),
            llm: llm
        )

        await service.link(for: current.id)

        let edges = try await relations.loadAll()
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.otherID(from: current.id), x.id)
        XCTAssertEqual(edges.first?.score ?? 0, 0.9, accuracy: 0.0001,
                       "the duplicate's stronger score wins")
    }
}

// MARK: - Test doubles

/// In-memory stand-in for `TranscriptionStorage`'s read path. The real one
/// needs a bootstrapped folder; `link(for:)` only ever calls `loadAll()`.
struct InMemoryRecords: RecordsSource {
    let all: [TranscriptionRecord]
    func loadAll() async throws -> [TranscriptionRecord] { all }
}

/// A class, not a struct: the tests read `callCount` / `lastCandidateIDs`
/// after the call returns, which a non-mutating protocol-satisfying method on
/// a struct could not record.
final class StubLLM: RelatedNotesLLM {
    private(set) var callCount = 0
    private(set) var lastCandidateIDs: [UUID] = []
    private let returns: [RelatedNoteMatch]
    private let error: Error?

    init(returns: [RelatedNoteMatch] = [], error: Error? = nil) {
        self.returns = returns
        self.error = error
    }

    func findRelated(
        currentTitle: String,
        currentSummary: String,
        candidates: [RelatedNoteCandidate],
        profile: LLMProviderProfile,
        apiKey: String?
    ) async throws -> [RelatedNoteMatch] {
        callCount += 1
        lastCandidateIDs = candidates.map(\.id)
        if let error { throw error }
        return returns
    }
}

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

    /// Spec §4.4: "For any pair (A, B) ... the relation is measured **exactly
    /// once** — during B's write, when A is a candidate. The single score from
    /// that measurement is the score both notes show, forever."
    ///
    /// `link(for:)` is reachable more than once for the same note. The
    /// 在线升级识别 button in `TranscriptionDetailView` re-runs
    /// `processWithLLM` on a note that is already `.completed` and already
    /// carries edges — its visibility condition tests `recognitionMode`, never
    /// `llmProcessingStatus`. And `upsert` *replaces* the score on an existing
    /// undirected pair, so without an exclusion a re-analysis silently re-rates
    /// the **other** note's page: down past `minimumScore` that is a row that
    /// disappears forever, and anywhere else a list that reorders behind the
    /// user's back while the note they did not touch is the one that changed.
    ///
    /// The seeded edge is 0.92; the re-analysis is offered the same pair and
    /// rates it 0.24, below the 0.3 threshold. The 0.92 must survive — and the
    /// re-analysis must still be free to create a *new* edge, which is the
    /// whole reason this is an exclusion and not a refusal to re-link.
    func testRelinkNeverReratesAnExistingEdge() async throws {
        let current = tagged(["a", "b", "c"])
        let already = tagged(["a", "b"])
        let fresh = tagged(["a", "c"])
        let third = tagged(["a", "b"])
        let fourth = tagged(["a", "c"])

        try await relations.upsert([NoteRelation(a: current.id, b: already.id, score: 0.92)])

        let llm = StubLLM(returns: [
            RelatedNoteMatch(id: already.id, score: 0.24), // would destroy the seeded edge
            RelatedNoteMatch(id: fresh.id, score: 0.7),
        ])
        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [current, already, fresh, third, fourth]),
            llm: llm
        )

        await service.link(for: current.id)

        let edges = try await relations.loadAll()
        let preserved = edges.first { $0.key == NoteRelation(a: current.id, b: already.id, score: 0).key }
        XCTAssertEqual(preserved?.score ?? 0, 0.92, accuracy: 0.0001,
                       "§4.4: an existing pair is never re-measured, so the seeded score must stand")
        XCTAssertTrue(edges.contains { $0.key == NoteRelation(a: current.id, b: fresh.id, score: 0).key },
                      "a re-analysis must still be able to create a NEW edge")
        XCTAssertEqual(llm.callCount, 1, "the exclusion must not make the pass a no-op")
        XCTAssertFalse(llm.lastCandidateIDs.contains(already.id),
                       "an already-linked note must not be re-offered for judgment")
    }

    /// Ruling AP: `prescreen`'s `guard !currentTags.isEmpty` is a deliberate,
    /// documented deviation from spec §4.1 (now a row in §6's table). A note
    /// with no tags therefore never *initiates* a pass — but it must still be
    /// pickable as a CANDIDATE in someone else's pass. `prescreen` keeps
    /// zero-overlap candidates by design (that is where the serendipity comes
    /// from), and this pins it, because without it the guard would cost a
    /// tagless note every relation in both directions rather than only its own.
    ///
    /// Passes on the current code — it pins existing intended behavior that
    /// nothing else covers, and it is the half of the deviation that makes
    /// keeping the guard cheap.
    func testTaglessNoteStillAppearsAsAnotherNotesCandidate() async throws {
        let current = tagged(["a", "b", "c"])
        let tagless = tagged([]) // zero tag overlap — ranked on recency alone
        let y = tagged(["a", "c"])
        let z = tagged(["a", "b"])

        let llm = StubLLM(returns: [RelatedNoteMatch(id: tagless.id, score: 0.8)])
        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [current, tagless, y, z]),
            llm: llm
        )

        await service.link(for: current.id)

        XCTAssertTrue(llm.lastCandidateIDs.contains(tagless.id),
                      "a zero-overlap candidate must still reach the model — that is the feature")
        let edges = try await relations.loadAll()
        XCTAssertTrue(edges.contains { $0.key == NoteRelation(a: current.id, b: tagless.id, score: 0).key },
                      "a tagless note must accumulate edges normally as a candidate")
    }

    /// The one test that spans the production seam, end to end:
    /// `link(for:)` → `relatedNotesStorage.related(to:)` →
    /// `RelatedNotesSectionBuilder.rows(...)` over a real temp-dir store.
    ///
    /// The other three files each stop short: link tests assert against raw
    /// `loadAll()`, row-model tests hand-build `RelatedNote` values, storage
    /// tests never reach the builder. So a regression where `related(to:)`
    /// returned the **queried** id instead of the counterpart would render a
    /// note listing *itself* — and every other test in the suite would stay
    /// green. This is the highest-value test of the round.
    func testLinkThroughStorageToRenderedRowYieldsTheOtherNote() async throws {
        let current = tagged(["a", "b", "c"])
        let other = tagged(["a", "b"])
        let y = tagged(["a", "c"])
        let z = tagged(["a", "b"])

        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [current, other, y, z]),
            llm: StubLLM(returns: [RelatedNoteMatch(id: other.id, score: 0.9)])
        )

        await service.link(for: current.id)

        let related = await relations.related(to: current.id)
        let rows = RelatedNotesSectionBuilder.rows(
            for: current,
            candidates: [current, other, y, z],
            related: related
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, other.id, "the row is the OTHER note")
        XCTAssertNotEqual(rows.first?.id, current.id, "a note must never list itself as related")
        XCTAssertEqual(rows.first?.record.id, other.id, "the pushed record is the other note too")
    }

    /// Linking the same note twice writes one edge, not two. Note this is now
    /// satisfied by the §4.4 exclusion rather than by `upsert` merging: the
    /// second pass does not re-offer the already-linked candidate, so there is
    /// nothing left for `upsert` to merge.
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
    ///
    /// The `callCount` assertion is what makes this test mean what its name
    /// says. `edges.isEmpty` alone cannot distinguish "the LLM failed and we
    /// swallowed it" from "prescreen found too few candidates and we never
    /// called the LLM" — both leave the edge set empty, so the second case
    /// would false-pass. Pinning the call count proves the failure was actually
    /// reached and that it is the *LLM's* failure that produced the empty set.
    func testLLMFailureLeavesNoEdgesAndDoesNotThrow() async throws {
        let current = tagged(["a", "b", "c"])
        let x = tagged(["a", "b"])
        let y = tagged(["a", "c"])
        let z = tagged(["a", "b"])

        let llm = StubLLM(error: LLMError.decodingError)
        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [current, x, y, z]),
            llm: llm
        )

        await service.link(for: current.id) // must not throw

        XCTAssertEqual(llm.callCount, 1, "the LLM must actually be reached and fail")
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

/// `Gate` is a hand-rolled FIFO mutex built on `withCheckedContinuation`, and
/// that kind of code fails *silently* when wrong — a lock that admits two
/// callers still produces correct-looking edges, it just occasionally loses
/// one, and only on real devices under real timing. So the gate is tested
/// directly rather than inferred through `link(for:)`.
final class RelatedNotesGateTests: XCTestCase {

    func testWithLockAdmitsExactlyOneCallerAtATime() async {
        let gate = Gate()
        let counter = ConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.withLock {
                        await counter.enterAndYield()
                    }
                }
            }
        }

        // Ruling D: read the actor's values into locals first. An
        // `XCTAssertEqual(await counter.maxSeen, 1)` autoclosure does not
        // compile, and hiding the `await` in a closure would take the async
        // work outside the assertion.
        let maxSeen = await counter.maxSeen
        let current = await counter.current

        XCTAssertEqual(maxSeen, 1, "withLock must admit exactly one caller at a time")
        XCTAssertEqual(current, 0, "every acquisition must be released — a leaked lock is a permanently dead gate")
    }

    /// The counter is balanced only if `release()` ran on every exit path of
    /// the critical section, including the ones that return early.
    func testWithLockReleasesWhenTheBodyReturnsEarly() async {
        let gate = Gate()

        await gate.withLock { return }
        await gate.withLock { /* empty body */ }

        // Both critical sections completed, so the gate must be free again.
        // A third acquisition that never returns would hang here instead.
        await gate.withLock { return }
    }
}

// MARK: - Test doubles

/// Records the highest concurrency ever observed inside a `Gate` critical
/// section. The `Task.yield()` is the whole point: it hands the cooperative
/// pool a chance to run a *competing* task while this one is still inside the
/// section, which is the interleaving a correct lock has to prevent.
actor ConcurrencyCounter {
    private(set) var current = 0
    private(set) var maxSeen = 0

    func enterAndYield() async {
        current += 1
        maxSeen = max(maxSeen, current)
        await Task.yield()
        current -= 1
    }
}

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

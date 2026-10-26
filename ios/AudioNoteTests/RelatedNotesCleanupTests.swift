import XCTest
@testable import AudioNote

/// Wiring tests for `RelatedNotesService.unlink(recordId:)` — the cleanup
/// half of the delete path.
///
/// Task 2's `RelatedNotesStorageTests` already cover `removeAll(involving:)`
/// as a storage mechanic. What is untested until now is the thing that can
/// actually be wrong: that the delete path reaches it, and that it contends
/// for the *same* gate as `link(for:)`. Per spec §4.4 relations are never
/// recomputed, so an edge lost to an interleaved read-modify-write is lost
/// permanently — that is the whole reason `unlink` sits on the service
/// instead of being inlined as `try? await RelatedNotesStorage.shared
/// .removeAll(involving:)` in the view model (Ruling Y).
///
/// Archive deliberately has no cleanup and no test here: spec §5.8 keeps an
/// archived note's edges so unarchiving restores them for free.
final class RelatedNotesCleanupTests: XCTestCase {

/// A provider profile handed to the service directly.
///
/// The service takes its profile by injection now, so a test no longer
/// has to mutate the shared store to get one — which also means the
/// tests no longer depend on each other's order, and no longer write
/// into whatever folder the store points at.
private struct StubProfileSource: RelatedNotesProfileSource {
    let profile: LLMProviderProfile

    func prepare() async {}
    @MainActor func activeProfile() -> LLMProviderProfile? { profile }
    @MainActor func apiKey(for id: UUID) -> String? { nil }
}


    private var tmpDir: URL!
    private var relations: RelatedNotesStorage!
    private var profileSource: StubProfileSource!

    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    override func setUp() async throws {
        try await super.setUp()

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        relations = RelatedNotesStorage(fileURL: tmpDir.appendingPathComponent("relatedNotes.json"))

        // Same reason as `RelatedNotesLinkTests`: `link(for:)` reads the
        // active profile off the main actor, so reaching the LLM at all
        // requires one installed.
        let profile = LLMProviderProfile(
            displayName: "cleanup-tests",
            baseURL: URL(string: "http://localhost:11434/v1/chat/completions")!,
            model: "test-model",
            requiresAPIKey: false
        )
        profileSource = StubProfileSource(profile: profile)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func tagged(_ names: [String]) -> TranscriptionRecord {
        let id = UUID()
        var r = TranscriptionRecord(id: id, content: "content for \(id)", createdAt: Date())
        r.title = "标题 \(id)"
        r.summary = "摘要 \(id)"
        r.tags = names.enumerated().map { TaggedItem(name: $0.element, score: 0.9 - Double($0.offset) * 0.1) }
        r.llmProcessingStatus = .completed
        return r
    }

    /// A service over the temp-dir store. `link` is never exercised by the
    /// first three tests, so the doubles are only there to satisfy the init.
    private func makeService(records: [TranscriptionRecord] = [], llm: RelatedNotesLLM = StubLLM()) -> RelatedNotesService {
        RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: records),
            llm: llm,
            profileSource: profileSource
        )
    }

    // MARK: - The delete path

    /// The behavior the whole task exists for: a deleted note leaves no edge
    /// behind, and the edges that had nothing to do with it survive intact.
    func testUnlinkDropsEveryEdgeTouchingTheDeletedNote() async throws {
        try await relations.upsert([
            NoteRelation(a: a, b: b, score: 0.9),
            NoteRelation(a: a, b: c, score: 0.7),
            NoteRelation(a: b, b: c, score: 0.6),
        ])

        await makeService().unlink(recordId: a)

        // Ruling D: hoist the await out of the assertion — an autoclosure
        // cannot be async.
        let remaining = try await relations.loadAll()
        XCTAssertEqual(remaining.count, 1, "only the edge between the two surviving notes is left")
        XCTAssertFalse(remaining.contains { $0.involves(a) })
        XCTAssertTrue(remaining[0].involves(b) && remaining[0].involves(c),
                      "the unrelated edge must survive untouched")
    }

    /// Deleting a note twice — or deleting two notes that were never related —
    /// must not throw and must not damage the store. `unlink` is non-throwing
    /// by contract, so the `try` is only here for `loadAll`.
    func testUnlinkIsIdempotent() async throws {
        try await relations.upsert([
            NoteRelation(a: a, b: b, score: 0.9),
            NoteRelation(a: b, b: c, score: 0.6),
        ])

        let service = makeService()
        await service.unlink(recordId: a)
        await service.unlink(recordId: a)
        await service.unlink(recordId: UUID()) // never had an edge

        let remaining = try await relations.loadAll()
        XCTAssertEqual(remaining.count, 1, "repeated deletes must not duplicate or resurrect anything")
        XCTAssertTrue(remaining[0].involves(b) && remaining[0].involves(c))
    }

    /// Deleting a note on a store that was never written must not throw and
    /// must not create a file. `removeAll` early-returns when nothing matched,
    /// so the absence of the file is the assertion that it took that path.
    func testUnlinkOnMissingStoreWritesNothing() async throws {
        let url = tmpDir.appendingPathComponent("relatedNotes.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        await makeService().unlink(recordId: a)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "an unlink that removes nothing must not write an empty file")
        let remaining = try await relations.loadAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    /// A corrupt file makes `removeAll` throw (Ruling M: the store refuses to
    /// default to an empty merge set, because that would destroy relations
    /// §4.4 never recomputes). `unlink` is the surface that swallows it, and
    /// the file must be left exactly as it was found.
    func testUnlinkSwallowsACorruptStoreAndLeavesItAlone() async throws {
        let url = tmpDir.appendingPathComponent("relatedNotes.json")
        try Data("not json".utf8).write(to: url)

        await makeService().unlink(recordId: a) // must not throw

        let after = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: after, as: UTF8.self), "not json",
                       "a failed cleanup must not overwrite anything")
    }

    // MARK: - Gate

    /// The reason `unlink` is a method on `RelatedNotesService` and not an
    /// inlined storage call.
    ///
    /// `link(for:)` calls the LLM while it holds the gate. The hook below runs
    /// *inside* that critical section and fires a real concurrent `unlink`,
    /// then waits. If `unlink` contends for the same gate, the probe cannot
    /// finish until `link` releases — which it has not yet, because the hook
    /// is still on the stack. If it does not contend, the probe finishes in
    /// microseconds and `probeCompletedWhileLinkHeld` flips to `true`.
    ///
    /// The hook deliberately does **not** await the probe: the gate is a
    /// non-reentrant mutex and `link` still holds it, so awaiting there would
    /// deadlock rather than fail. The task is collected through `holder` and
    /// awaited after `link` returns, when the gate is free again.
    func testUnlinkQueuesBehindLinkOnTheSameGate() async throws {
        let current = tagged(["a", "b", "c"])
        let x = tagged(["a", "b"])
        let y = tagged(["a", "c"])
        let z = tagged(["a", "b"])
        let doomed = UUID()

        let holder = ProbeHolder()
        let probeState = ProbeState()
        let llm = ProbeLLM(returns: [RelatedNoteMatch(id: x.id, score: 0.9)])
        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [current, x, y, z]),
            llm: llm,
            profileSource: profileSource
        )
        llm.setHook { [service] in
            let probe = Task {
                await service.unlink(recordId: doomed)
                await probeState.markFinished()
            }
            await holder.adopt(probe)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await probeState.markChecked()
            let finished = await probeState.isFinished
            await probeState.record(finishedWhileLinkHeld: finished)
        }

        await service.link(for: current.id)

        // The probe cannot have been starved either: the gate is released
        // once `link` returns, so it runs and completes before this.
        if let probe = await holder.task { await probe.value }

        let early = await probeState.finishedWhileLinkHeld
        let checked = await probeState.wasChecked
        XCTAssertNotNil(early, "the probe must actually have been observed")
        XCTAssertFalse(early ?? true, "unlink ran to completion while link held the gate — the two are not serialized")
        XCTAssertTrue(checked)
        XCTAssertEqual(llm.callCount, 1)

        // And the file is in the state serialization guarantees: the link's
        // edge landed, the unlinked id never had one to lose.
        let edges = try await relations.loadAll()
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.otherID(from: current.id), x.id)
    }

    /// Twelve overlapping `link` / `unlink` calls on one service, all racing
    /// the same file. Under the gate they run in some FIFO order, so the
    /// final state is the same regardless of which order that is: every
    /// link's edge is present exactly once, and nothing survives for the
    /// deleted note. Without the gate the two concurrent read-modify-write
    /// cycles can clobber each other and lose one of those edges.
    func testConcurrentLinksAndUnlinksEndInAConsistentState() async throws {
        let one = tagged(["a", "b", "c"])
        let two = tagged(["a", "b", "c"])
        let x = tagged(["a", "b"])
        let y = tagged(["a", "c"])
        let z = tagged(["a", "b"])
        let doomed = UUID()

        // A pre-existing edge for the note that is about to be deleted, so
        // `unlink` has real work to do rather than early-returning.
        try await relations.upsert([NoteRelation(a: doomed, b: x.id, score: 0.8)])

        let service = RelatedNotesService(
            storage: relations,
            records: InMemoryRecords(all: [one, two, x, y, z]),
            llm: StubLLM(returns: [RelatedNoteMatch(id: x.id, score: 0.9)]),
            profileSource: profileSource
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await service.link(for: one.id) }
                group.addTask { await service.link(for: two.id) }
                group.addTask { await service.unlink(recordId: doomed) }
            }
        }

        let edges = try await relations.loadAll()
        XCTAssertFalse(edges.contains { $0.involves(doomed) },
                       "a deleted note must leave no edge behind, whatever the interleaving")
        let keys = Set(edges.map(\.key))
        XCTAssertEqual(keys.count, edges.count, "concurrent writers must not duplicate an undirected pair")
        XCTAssertTrue(keys.contains(NoteRelation(a: one.id, b: x.id, score: 0).key),
                      "link(one) was called four times; its edge must not be lost to a racing writer")
        XCTAssertTrue(keys.contains(NoteRelation(a: two.id, b: x.id, score: 0).key),
                      "link(two)'s edge must not be lost to a racing writer")
    }
}

// MARK: - Test doubles

/// Records what the probe observed, without ever blocking the caller.
actor ProbeState {
    private var finished = false
    private var checked = false

    /// Whether the concurrent `unlink` had completed by the time the hook —
    /// running inside `link`'s critical section — looked.
    private(set) var finishedWhileLinkHeld: Bool?
    var wasChecked: Bool { checked }

    func markFinished() { finished = true }
    func markChecked() { checked = true }
    func record(finishedWhileLinkHeld: Bool) { self.finishedWhileLinkHeld = finishedWhileLinkHeld }
    var isFinished: Bool { finished }
}

/// Hands the probe task back to the test so it can be awaited after `link`
/// releases the gate.
actor ProbeHolder {
    private(set) var task: Task<Void, Never>?
    func adopt(_ task: Task<Void, Never>) { self.task = task }
}

/// `StubLLM` plus a hook that runs while `link(for:)` still holds the gate.
/// The hook is installed after construction, so the closure can capture the
/// service without a retain cycle at init time.
final class ProbeLLM: RelatedNotesLLM {
    private(set) var callCount = 0
    private let returns: [RelatedNoteMatch]
    private var hook: (() async -> Void)?

    init(returns: [RelatedNoteMatch]) {
        self.returns = returns
    }

    func setHook(_ hook: @escaping () async -> Void) {
        self.hook = hook
    }

    func findRelated(
        currentTitle: String,
        currentSummary: String,
        candidates: [RelatedNoteCandidate],
        profile: LLMProviderProfile,
        apiKey: String?
    ) async throws -> [RelatedNoteMatch] {
        callCount += 1
        if let hook {
            await hook()
        }
        return returns
    }
}

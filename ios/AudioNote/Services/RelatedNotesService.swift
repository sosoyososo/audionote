import Foundation

/// Read-only view of the note store. Lets `link(for:)` be tested without a
/// bootstrapped folder; `TranscriptionStorage` satisfies it as-is.
protocol RecordsSource {
    func loadAll() async throws -> [TranscriptionRecord]
}

/// The slice of `LLMService` that `link(for:)` needs — the one method, with
/// the same signature `LLMService.findRelated` already has.
protocol RelatedNotesLLM {
    func findRelated(
        currentTitle: String,
        currentSummary: String,
        candidates: [RelatedNoteCandidate],
        profile: LLMProviderProfile,
        apiKey: String?
    ) async throws -> [RelatedNoteMatch]
}

/// Minimal async mutex guarding the read-modify-write on `relatedNotes.json`.
///
/// `link(for:)` is the only serialized section. A second caller **queues** —
/// it does not skip, coalesce, or bail: a fast second recording must still get
/// its own linking pass, just after the first one has finished writing.
/// The queue is FIFO, so relations land in the order the notes were created.
///
/// Both the acquisition and the release happen inside the actor, which is why
/// `withLock` exists rather than an `acquire()` / `defer { release() }` pair
/// spread across the caller: `await` is illegal inside `defer`, so the release
/// would have to be deferred onto an unscheduled `Task`, and a caller returning
/// from `link(for:)` could then start a second pass while the gate still
/// reported busy.
actor Gate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` with the gate held, releasing it on every exit path.
    func withLock(_ body: () async -> Void) async {
        await acquire()
        defer { release() }
        await body()
    }

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Hands the lock to the next waiter if there is one, otherwise clears it.
    /// Synchronous on purpose: `isBusy` and `waiters` are only ever touched
    /// from inside the actor.
    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Owns prescreen → LLM → sanitize → persist for related notes.
/// Knows nothing about SwiftUI. `link(for:)` never throws.
struct RelatedNotesService {

    /// Upper bound on candidates handed to the LLM.
    static let maxCandidates = 20

    /// Below this candidate count there is nothing worth asking the LLM about
    /// (spec §6): the caller must bail out before spending a call.
    static let minimumCandidates = 3

    /// How many related notes a detail page shows. The `findRelated` prompt
    /// says `最多 5 条` in prose; that literal is a model instruction and
    /// stays a literal, but the two must not drift apart.
    static let maxRelated = 5

    // MARK: - Dependencies

    private let storage: RelatedNotesStorage
    private let records: RecordsSource
    private let llm: RelatedNotesLLM

    /// Serializes the read-modify-write on `relatedNotes.json`.
    private let gate = Gate()

    init(
        storage: RelatedNotesStorage = .shared,
        records: RecordsSource = TranscriptionStorage.shared,
        llm: RelatedNotesLLM = LLMService()
    ) {
        self.storage = storage
        self.records = records
        self.llm = llm
    }

    // MARK: - Prescreen (pure, local, free)

    /// Rank existing notes by how likely they are to be related, locally.
    ///
    /// score = 2.0 × (shared tag count)
    ///       + 0.5 × log2(1 + mean score of the shared tags)
    ///       + 0.3 × recency decay
    ///
    /// Recency decay is `1 / (1 + ageDays / 30)` — a 30-day time constant, so a
    /// note from today scores 1.0 and one from ~30 days ago scores 0.5.
    ///
    /// Candidates are every record that is not `current`, is not archived, and
    /// whose LLM processing has completed. A candidate sharing **no** tag with
    /// the current note is still ranked: its tag terms are 0 and it scores on
    /// recency alone. That is deliberate — the feature's point is serendipity
    /// ("three months ago you already said something adjacent"), and dropping
    /// zero-overlap notes would make exactly that unreachable.
    ///
    /// The tag-count term dominates; the recency term only breaks ties among
    /// equal-overlap notes. Ordering is deterministic for a given `now` (ties
    /// fall back to `createdAt` descending, then `id`), and it is also stable
    /// across calls despite `now` moving: a one-tag difference is worth 2.0,
    /// while the tag-score and recency terms together span at most
    /// 0.5 × log2(2) + 0.3 = 0.8, so a moving `now` can never reorder a pair
    /// the tag count did not already order.
    ///
    /// Does not enforce `minimumCandidates` — the caller must check that before
    /// spending an LLM call.
    static func prescreen(current: TranscriptionRecord, among: [TranscriptionRecord]) -> [TranscriptionRecord] {
        // First tag wins on a duplicated name, matching the LLM's descending-score order.
        var currentTags: [String: Double] = [:]
        for tag in current.tags ?? [] where currentTags[tag.name] == nil {
            currentTags[tag.name] = tag.score
        }
        guard !currentTags.isEmpty else { return [] }

        let currentNames = Set(currentTags.keys)
        let now = Date()

        let scored: [(record: TranscriptionRecord, score: Double)] = among.compactMap { candidate in
            guard candidate.id != current.id,
                  !candidate.archived,
                  candidate.llmProcessingStatus == LLMStatus.completed
            else { return nil }

            var candidateNames: Set<String> = []
            for tag in candidate.tags ?? [] {
                candidateNames.insert(tag.name)
            }
            let sharedNames = candidateNames.intersection(currentNames)

            // "Mean shared-tag score" is the per-shared-tag `min` of the two
            // notes' scores for that tag, averaged. `min` (rather than the mean
            // of the current note's scores, or the max) keeps the pair
            // symmetric — swapping current and candidate gives the same number —
            // and conservative: a tag one side scores poorly cannot pull the
            // pair up.
            let sharedScores = sharedNames.map { name -> Double in
                min(currentTags[name] ?? 0, candidate.score(forTagName: name) ?? 0)
            }
            let tagCount = Double(sharedNames.count)
            let meanTagScore = sharedScores.isEmpty ? 0 : sharedScores.reduce(0, +) / Double(sharedScores.count)
            let ageDays = max(0, now.timeIntervalSince(candidate.createdAt) / 86_400)
            let recency = 1.0 / (1.0 + ageDays / 30.0)

            let score = 2.0 * tagCount + 0.5 * log2(1 + meanTagScore) + 0.3 * recency
            return (candidate, score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.record.createdAt != rhs.record.createdAt { return lhs.record.createdAt > rhs.record.createdAt }
                return lhs.record.id.uuidString < rhs.record.id.uuidString
            }
            .prefix(Self.maxCandidates)
            .map(\.record)
    }

    // MARK: - Sanitize (pure)

    /// Drop anything the model shouldn't have returned: ids that weren't
    /// offered as candidates (hallucinations), the current note itself, and
    /// duplicates. Keeps the strongest score per surviving id and caps the
    /// result at `maxRelated`, ordered strongest first.
    ///
    /// Pure — no network, no storage, no ViewModel. Task 5 owns the wiring;
    /// this is only the filter the LLM's answer must pass through before
    /// anything is persisted.
    ///
    /// Order of operations matters, and it is not the order the spec's data
    /// flow diagram lists them in prose. The candidate-set intersection and
    /// the self-drop happen in the *filter*, so they cost nothing; dedupe
    /// happens next, into a dictionary, because a duplicate must not be able
    /// to consume one of the 5 display slots — capping first would let two
    /// copies of the same note take two slots and leave a genuinely related
    /// note off the list. The cap is therefore last.
    ///
    /// The self-drop is not redundant with the candidate-set intersection:
    /// the model can be handed — or invent — the current note's own id, and
    /// the storage layer does **not** guard self-edges (`NoteRelation.init`
    /// has no `a != b` check, and `otherID(from:)` on `{X, X}` returns `X`),
    /// so an unguarded self-match would persist and render as a note linked
    /// to itself.
    static func sanitize(
        _ matches: [RelatedNoteMatch],
        candidateIDs: Set<UUID>,
        currentID: UUID
    ) -> [RelatedNoteMatch] {
        // Dedupe, keeping the highest score the model gave each id — a model
        // that rates the same note twice is reporting uncertainty about the
        // score, not a second opinion, and the higher rating is the one it
        // stands behind.
        //
        // Non-positive scores are dropped outright rather than clamped. Both
        // 0.0 and a negative are far below `minimumScore`, so neither can
        // reach a display slot, but clamping would persist a number the model
        // never said: `max(nil ?? 0, -0.5)` writes 0.0 and the stored edge
        // then disagrees with the reply it came from. Dropping keeps the
        // persisted value equal to something the model actually wrote.
        var best: [UUID: Double] = [:]
        for match in matches
        where candidateIDs.contains(match.id) && match.id != currentID && match.score > 0 {
            if let existing = best[match.id] {
                best[match.id] = max(existing, match.score)
            } else {
                best[match.id] = match.score
            }
        }

        // Dictionary iteration order is seeded per process, so a tie on score
        // would otherwise make the same input render in a different order
        // on every launch. Break ties on first appearance in the model's own
        // list, which keeps the output deterministic for a given input.
        var firstSeen: [UUID: Int] = [:]
        for (index, match) in matches.enumerated() where firstSeen[match.id] == nil {
            firstSeen[match.id] = index
        }

        return best
            .map { RelatedNoteMatch(id: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return (firstSeen[lhs.id] ?? 0) < (firstSeen[rhs.id] ?? 0)
            }
            .prefix(Self.maxRelated)
            .map { $0 }
    }

    // MARK: - Link (orchestration)

    /// Compute and persist relations for one note. Never throws: a failure
    /// here must not disturb the note's own save or surface to the user
    /// (spec §6 — "relations are best-effort and never block, never error,
    /// never surface").
    ///
    /// **Caller's contract:** the note must already be persisted *and* its
    /// optimized text already on screen before this is awaited. `link` spends
    /// a second LLM round trip, so awaiting it while the caller still shows a
    /// "processing" UI would mask the first call's output for 1–3s. Getting
    /// that wrong costs a briefly-empty 相关思考 section, which self-heals;
    /// linking too early costs a stalled UI.
    ///
    /// Serialized through `gate`, so two overlapping triggers (a fast second
    /// recording, or `networkDidRecover` firing alongside) run one after the
    /// other instead of interleaving a read-modify-write on the same file.
    func link(for recordId: UUID) async {
        await gate.withLock {
            do {
                let all = try await records.loadAll()
                guard let current = all.first(where: { $0.id == recordId }),
                      current.llmProcessingStatus == .completed,
                      let title = current.title, !title.isEmpty,
                      let summary = current.summary, !summary.isEmpty
                else {
                    Logger.info("Related notes skipped for \(recordId): no completed note with title + summary")
                    return
                }

                let candidates = Self.prescreen(current: current, among: all)
                // Spec §6: "Fewer than 3 candidates → return before calling the
                // LLM. No edge written." The LLM call is the expensive step, so
                // this gate is about spend — a small corpus legitimately
                // produces no relations.
                guard candidates.count >= Self.minimumCandidates else {
                    Logger.info("Related notes skipped for \(recordId): only \(candidates.count) candidates")
                    return
                }

                // Connectivity is not re-checked here: `LLMService.findRelated`
                // runs its own gate #2 before every request (spec §6's offline
                // row is satisfied there).
                //
                // `ProviderProfileStore` is main-actor isolated, so hop for the
                // read. No active profile means the LLM path is off entirely —
                // same silent skip `processWithLLM` does.
                guard let profile = await MainActor.run(body: { ProviderProfileStore.shared.active }) else {
                    Logger.info("Related notes skipped for \(recordId): no active provider profile")
                    return
                }
                let apiKey = await MainActor.run(body: { ProviderProfileStore.shared.apiKey(for: profile.id) })

                let payload = candidates.map {
                    RelatedNoteCandidate(id: $0.id, title: $0.title ?? "", summary: $0.summary ?? "")
                }
                let raw = try await llm.findRelated(
                    currentTitle: title,
                    currentSummary: summary,
                    candidates: payload,
                    profile: profile,
                    apiKey: apiKey
                )

                let sanitized = Self.sanitize(
                    raw,
                    candidateIDs: Set(candidates.map(\.id)),
                    currentID: current.id
                )
                guard !sanitized.isEmpty else {
                    Logger.info("Related notes: model returned nothing usable for \(recordId)")
                    return
                }

                // `upsert` throws on a read failure rather than defaulting to
                // an empty merge set — overwriting an undecodable file would
                // destroy relations that, per §4.4, are never recomputed. So
                // the swallow belongs here, at the caller, and only here.
                try await storage.upsert(
                    sanitized.map { NoteRelation(a: current.id, b: $0.id, score: $0.score) }
                )
                Logger.info("Related notes linked for \(recordId): \(sanitized.count) edges")
            } catch {
                Logger.warning("Related notes linking failed for \(recordId): \(error.localizedDescription)")
            }
        }
    }
}

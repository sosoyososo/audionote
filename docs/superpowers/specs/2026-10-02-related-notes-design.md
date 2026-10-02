# 相关思考 (Related Notes) — Design Spec

**Date**: 2026-10-02
**Status**: ACCEPTED
**Supersedes**: `2026-09-24-related-notes-design.md` (backlog stub — that file's §3.1 is resolved by this spec)
**Related**: ADR-0002 (merge LLM calls), ADR-0004 (optimization by default), `2026-09-23-library-search-tag-archive-design.md` (tag system), `2026-09-24-multi-provider-llm-design.md` (Provider profiles)

---

## 1. Problem

A voice note is a dead end. You record an idea, it becomes a row in the list, and it never connects to anything else. The library tab already solves *search* (substring match) and *filtering* (tag chips) — but those are deliberate acts. Related Notes is about **serendipity**: opening a note and discovering that three months ago you already said something adjacent.

The feature: at the bottom of a note's detail page, show the notes most related to it, tappable to jump across.

## 2. Non-goals

Explicitly out of scope:

- Embedding models / BM25 / any local semantic model.
- Background or periodic re-linking of old notes (see §4.4 for why this is a permanent decision, not a deferral).
- Recomputing relations when the user edits a note's text.
- A loading skeleton, a manual "recompute" button, or an offline retry affordance.
- Displaying the numeric score to the user.
- Background audio, playback speed, skip buttons (carried over from the playback stub's §6 — unchanged by this feature).

---

## 3. Two independent scores

The single most important concept in this spec: **there are two different scores, computed by two different parties, for two different purposes. They are never compared to each other.**

| | Prescreen score | Relatedness score |
|---|---|---|
| Computed by | Local code (no network) | The LLM |
| Used for | Picking which ≤20 old notes get sent to the LLM | Answering "how related is this pair" |
| Persisted? | **No** — thrown away after the call | **Yes** — the edge list |
| Comparable across notes? | Irrelevant; it only orders the candidate set | Yes, within the list being displayed |

Conflating these is the mistake to avoid. A note with a high prescreen score that the LLM then rates at 0.2 is a normal outcome, not a bug: tag overlap got it into the candidate pool, and semantic judgement decided it wasn't actually related.

## 4. Architecture

### 4.1 Data flow

```
stopRecording()
  └─ assessAndEnhance(record:originalText:)          ← unchanged (ADR-0001)
       └─ processWithLLM(recordId:originalText:)
            ├─ LLMService.optimizeAndProcess(...)     ← call 1, UNCHANGED
            │     returns { optimizedText, title, summary, tags }
            ├─ save record                            ← existing path
            └─ RelatedNotesService.link(for: recordId)   ← NEW, fire-and-forget
                 ├─ 1. prescreen → ≤20 candidate UUIDs
                 │     candidates = records where
                 │       llmProcessingStatus == .completed && !archived
                 │     ranked by: 2.0×(shared tag count)
                 │                  + 0.5×log2(1 + mean shared-tag score)
                 │                  + 0.3×recency decay
                 │     tie-break: createdAt descending (deterministic)
                 │     self excluded
                 ├─ 2. if candidates.count < 3 → return (no edge written)
                 ├─ 3. LLMService.findRelated(...)     ← call 2, NEW
                 │     input:  this note's title + summary
                 │             each candidate's id + title + summary
                 │     output: [{ id, score }], ≤5 entries, score desc
                 ├─ 4. sanitize: intersect with candidate UUID set
                 │             (drops hallucinated ids), dedupe, drop self,
                 │             cap at 5
                 ├─ 5. RelatedNotesStorage.upsert(edges)  ← one atomic write
                 └─ 6. return — errors are swallowed
```

### 4.2 Why relation-finding is a second LLM call, not a fifth field on the first

The natural instinct is to fold relation-finding into the existing `optimizeAndProcess` call and pay zero extra API cost. This spec deliberately does not, because the two tasks want incompatible inputs.

Call 1's user message is the raw transcript, and the system prompt asks the model to *rewrite* it. Call 2 needs 20 other notes' titles and summaries injected into the same message. A model asked to "optimize this text" while surrounded by 20 unrelated summaries will start importing them — the same failure mode ADR-0004 had to fix when a mis-hearing turned 「语音」 into 「200题」.

Splitting costs one extra round-trip (~1.5–2.5K tokens, because the candidate cap is what makes it small) and buys two independently retryable operations. **If call 2 fails, the note is already saved with its title, summary, and tags intact, and the user sees no error at all.**

### 4.3 Storage: a separate file, undirected edges

Relation data lives in its own file and `TranscriptionRecord` gains **no new fields**.

```json
// AudioNote/relatedNotes.json — sibling of transcriptions.json
[
  { "a": "3F2A…", "b": "9B1C…", "score": 0.92 },
  { "a": "7D40…", "b": "9B1C…", "score": 0.41 }
]
```

`a` and `b` are unordered. The writer normalizes so `a.uuidString < b.uuidString`, which makes `(A,B)` and `(B,A)` the same edge by construction.

Four reasons this beats `relatedIDs: [UUID]?` on the record:

1. **An edge is stored once.** With per-record lists, every relation is written twice (into A and into B) and the two copies can drift. Here, both detail pages read the same row — cross-page score consistency is structural, not something to maintain.
2. **`TranscriptionRecord` is left alone.** That type already carries a legacy-shape migration for `tags` (`[String]` → `[TaggedItem]`) and `decodeIfPresent` fallbacks for `archived`/`archivedAt`. Not touching it means this feature cannot break existing installs.
3. **Cleanup is one place.** Deleting a note removes every edge touching its UUID from a single array, rather than relying on render-time filtering scattered through the view. (Archiving deliberately does *not* clean up — see §5.8.)
4. **Ordering is free.** A set of edges can be re-sorted at read time; an append-only per-record array could not.

Cost: one more file path to manage, one more read per detail view, and a possible dangling edge if a note is deleted out from under its edges. All three are addressed in §6.

### 4.4 Relations are computed once per pair, at write time

Because there is no backfill, an older note can never see a newer one. For any pair (A, B) where A was written first, the relation is measured **exactly once** — during B's write, when A is a candidate. The single score from that measurement is the score both notes show, forever.

This has a known consequence: **two old notes, neither written recently, never link to each other.** A 2024-era note's edge list is frozen at whatever it looked like when each subsequent note happened to be written. This is accepted, not deferred — a backfill pass would re-rank existing rows and reintroduce exactly the ordering churn §4.3 was chosen to avoid.

### 4.5 Editing a note does not recompute

The pencil button in `TranscriptionDetailView` saves text and stops. Edits are frequent and cheap to make, so recomputing on save would mean frequent re-ranking of a stored list for a text change that may not even alter the note's topic. A stale relation is merely imprecise; a re-ranked one is churn.

## 5. Components

### 5.1 `Models/NoteRelation.swift` (new)

```swift
/// One undirected "these two notes are related" edge.
struct NoteRelation: Codable, Hashable {
    let a: UUID
    let b: UUID
    let score: Double

    /// Stable identity for the undirected pair, independent of argument order.
    var key: String {
        min(a.uuidString, b.uuidString) + "|" + max(a.uuidString, b.uuidString)
    }

    func involves(_ id: UUID) -> Bool { a == id || b == id }
    var otherID: (from: UUID) -> UUID? { a == from ? b : (b == from ? a : nil) }
}

/// An edge resolved from one note's point of view: the *other* note's id
/// plus the pair's score. Produced by `RelatedNotesStorage.related(to:)`
/// so callers never have to think about which side of the edge they hold.
struct RelatedNote: Identifiable, Hashable {
    let id: UUID      // the other note
    let score: Double
}
```

### 5.2 `Services/RelatedNotesStorage.swift` (new)

Mirrors `TranscriptionStorage`'s shape exactly: private init singleton, `jsonURLOrNil()` that hops to `MainActor` and returns `nil` when `StorageCoordinator.shared.isReady` is false, `.atomic` writes, `loadAll` returning `[]` when the file is absent (clean first launch).

| Method | Behavior |
|---|---|
| `loadAll() async throws -> [NoteRelation]` | Missing file → `[]` |
| `related(to id: UUID) -> [RelatedNote]` | Filter `involves(id)`, resolve the counterpart id, drop scores below `minimumScore`, sort by score desc |
| `upsert(_ relations: [NoteRelation])` | De-dupe by `key`; an existing edge has its `score` replaced |
| `removeAll(involving id: UUID)` | Drops every edge touching the id, then one atomic write |
| `static let minimumScore = 0.3` | Display threshold — weak edges are stored but not shown |
| `private relatedNotesURL` | Resolved via `StorageCoordinator` |

`minimumScore` sits well inside the LLM's plausible output range rather than on a boundary, so an edge's visibility doesn't flip on a knife-edge. Edges below it are still written — the threshold is a display policy, and loosening it later needs no re-link pass.

The service owns **no** in-memory cache. The file is a few KB; re-reading on each detail view is cheaper than the invalidation logic a cache would require.

### 5.3 `StorageCoordinator` (modified)

One added `nonisolated` computed property, matching the existing `jsonURL` pattern:

```swift
nonisolated var relatedNotesURL: URL {
    rootURL.appendingPathComponent("relatedNotes.json")
}
```

### 5.4 `Services/RelatedNotesService.swift` (new)

Owns prescreen → LLM → sanitize → persist. Knows nothing about SwiftUI. Its entire public surface is:

```swift
func link(for recordId: UUID) async
```

Never throws; every failure path returns silently. The caller in `TranscriptionViewModel.processWithLLM` awaits it after the existing record save, so a slow or failing relation call cannot delay or block the note's own save.

### 5.5 `Services/LLMService.swift` (modified)

New wire type and entry point alongside `optimizeAndProcess`:

```swift
struct RelatedNoteCandidate: Encodable {
    let id: UUID
    let title: String
    let summary: String
}

struct RelatedNoteMatch: Decodable {
    let id: UUID
    let score: Double
}
```

`findRelated(current:title:summary:candidates:profile:apiKey:) async throws -> [RelatedNoteMatch]` — reuses the existing `retryingRequest` machinery and the existing JSON-extract regex (the same defence that handles prose-wrapped JSON from models in the M2.7 lineage). It applies gate #1 (`validateProfile`) and gate #2 (`NetworkMonitor.shared.checkConnectivity()`) exactly as `optimizeAndProcess` does — the ADR-0001 rule that every online call is connectivity-gated has no exceptions.

The system prompt is a `private static let`, matching how `optimizeAndProcessPrompt` is locked:

```
你是一个笔记关联助手。下面是一条笔记，以及候选笔记的列表。

【当前笔记】
标题：{title}
摘要：{summary}

【候选笔记】
{id}. 标题：{title} 摘要：{summary}
…

请选出与【当前笔记】在主题或内容上真正相关的候选，最多 5 条，不足则少给。
只返回你确实认为相关的；如果没有任何一条相关，返回空数组。
不要返回格式错误的 id，不要编造候选列表中不存在的 id。
id 字段必须是给定的完整 uuid 字符串。

严格返回 JSON，不要任何解释或 markdown 标记：
{"related": [{"id": "<uuid>", "score": 0.85}]}
```

The prompt pins the score's meaning to the pair, not to its rank within the candidate pool, so that an 0.85 is comparable across calls made at different times. LLMs are not perfectly consistent about this; the display layer (§6) does not depend on the property holding.

### 5.6 `ViewModels/TranscriptionViewModel.swift` (modified)

In `processWithLLM`, after the existing save succeeds:

```swift
await relatedNotesService.link(for: record.id)
```

`assessAndEnhance`'s three-case switch is untouched.

### 5.7 `Views/TranscriptionDetailView.swift` (modified)

A `RelatedNotesSection` rendered below the original/optimized text comparison. It reads `relatedNotesStorage.related(to: currentRecord.id)` and maps each result to its record via `viewModel.historyRecords`. A result whose record is missing or archived is skipped, producing a shorter list rather than a gap.

Each row: title, created-at, one-line preview, and the tags the two notes **share** — rendered as chips, with non-shared tags omitted entirely (no chip row at all when the intersection is empty). A section with no renderable rows hides itself.

Tapping a row is a `NavigationLink` push. Stacking is allowed, since following a chain of related notes is the point.

### 5.8 Delete-path cleanup

Deleting a note drops every edge touching its UUID via `relatedNotesStorage.removeAll(involving:)`. Failures are swallowed — the note is already gone, and the render-time skip handles a dangling edge.

**Implementation note (settled while planning):** the call lives in `TranscriptionViewModel`'s delete path rather than inside `TranscriptionStorage.delete(id:)`. `TranscriptionStorage` is a pure file service with no handle on the relations file, and testing it requires a bootstrapped folder; calling from the view model gives identical observable behavior with a testable seam. Archive deliberately does **not** clean up — an archived note keeps its edges and is filtered at render time, so unarchiving restores its relations for free.

## 6. Failure and edge-case behavior

| Situation | Behavior |
|---|---|
| No Provider configured | `processWithLLM` doesn't run; no relations written; no section shown |
| Offline at write time | Gate #2 blocks the call; no edge written; no error surfaced |
| Fewer than 3 candidates | Return before calling the LLM. No edge written. |
| `findRelated` throws or returns junk | All of call 1's results are already persisted. No edge written. No error surfaced. |
| LLM hallucinates an id not in the candidate set | Dropped by the whitelist intersection |
| LLM returns its own id (the current note) | Dropped |
| LLM returns duplicates | De-duped |
| LLM returns more than 5 | Capped at 5, order preserved |
| A referenced note was deleted | Row skipped at render; no gap, no error |
| A referenced note was archived | Row skipped at render |
| A note is deleted | `removeAll(involving:)` drops its edges |
| A note is edited | Nothing recomputed (§4.5) |
| `relatedNotes.json` is corrupt | Decode failure → treated as no relations, section hidden. Never blocks the app's other features. |

The uniform principle: **relations are best-effort and never block, never error, never surface.** A note is fully usable whether or not it has related notes.

### On score comparability across time

Because a note's edges are written at different moments, the scores in one list may not share a scale — a 0.9 earned from a pool of 6 notes and a 0.55 earned from a pool of 200 are not the same measurement. This is a property of asking an LLM the same question at different times, not a design defect. The design accommodates it rather than pretending it away: the threshold is a single well-widowed constant rather than a value tuned to a boundary, and the score is never shown as a number, so no user ever sees two numbers and wonders why they disagree.

## 7. Testing

The project currently has no test coverage for `TranscriptionRecord`, `LLMService`, or `TranscriptionDetailView`. The tests below target pure logic only — no network, no SwiftUI.

**`NoteRelation` / `RelatedNotesStorage`** (in-memory fixture, temp directory)

- `key` is identical for `(A,B)` and `(B,A)`
- `related(to:)` returns both the "a-side" and "b-side" edges of an id
- `related(to:)` sorts descending by score
- `related(to:)` omits edges scoring below `minimumScore`, while `loadAll()` still returns them
- `related(to:)` yields the counterpart id, not the queried id
- `upsert` with an existing pair replaces the score instead of appending a duplicate
- `loadAll` on a missing file returns `[]`
- `removeAll(involving:)` drops every edge touching the id and leaves the rest
- round-trip encode/decode preserves all fields

**`RelatedNotesService.prescreen` (pure function)**

- a note sharing more tags outranks one sharing fewer
- ties break on `createdAt` descending — and two runs over the same input produce identical ordering
- the current note is excluded
- archived records are excluded
- records whose `llmProcessingStatus != .completed` are excluded
- fewer than 3 candidates yields nil

**`RelatedNotesService.sanitize` (pure function)**

- an id outside the candidate set is dropped
- the current note's own id is dropped
- duplicates collapse
- input longer than 5 is truncated

**`TranscriptionStorage.delete`** — deleting a note removes its edges.

**Manual verification on device** (iPhone Air, `3C0B7BE4-2AEF-54E4-B937-9A0C96326420`)

1. Record six notes on a shared topic; each detail page shows a "相关思考" section.
2. Open note 1 — notes 2–6 appear. Open note 2 — note 1 and the overlapping notes appear. Both pages read the same score for the same pair.
3. Record a seventh note that relates to note 1. Reopen note 1: the section now has seven entries, ordered by score.
4. Edit note 1's text and save. Its section is unchanged.
5. Record with the device offline. No section appears, and no error is shown.
6. Archive a note. It disappears from other notes' sections.
7. Delete a note. It disappears from other notes' sections, leaving no gap.
8. Open `relatedNotes.json` in the Files app under `AudioNote/` and confirm the shape.

**Build gate**: `xcodebuild` against both `iphonesimulator` and `iphoneos` must succeed.

## 8. What ships

A user who records a note, later opens it, and finds three adjacent notes they would otherwise never have rediscovered — without the app making a second network request visible to them, without the list reshuffling under them, and without a single existing record's schema changing.

# Tag merge — folding duplicate tag spellings into one

| Field | Value |
|---|---|
| **Status** | DRAFT — awaiting user review |
| **Date** | 2026-10-17 |
| **Author** | — |
| **Related** | `docs/decisions/0003-multi-provider-llm.md` (prompt vocabulary), `docs/GLOSSARY.md` (`TagIdentity`) |

## Problem

The library accumulates near-synonym tags. `工作`, `工作项` and `工作会议` are
the same topic to the person who filed them, and they show up as three
separate chips — each filtering only to its own records, so tapping one
silently hides most of what the user meant to see.

Two earlier pieces of work narrowed this but do not close it:

- **Case-insensitive chip merging** (`TagIdentity`, 2026-10-15) collapses
  `Work` / `work`. On a Chinese-only library it is a **no-op**: CJK has no
  case, so `lowercased()` changes nothing. It also cannot touch vocabulary
  drift — `工作项` is a genuinely different string from `工作`, not a second
  spelling of one name.
- **The prompt's vocabulary hint** (2026-10-17) tells the model which tags
  already exist, so it reuses them instead of inventing a near-synonym per
  record. This constrains **future** output only. It does nothing about the
  drift already on disk.

So the existing library keeps its drift, and this spec is the one-time
(occasionally repeatable) manual cure for it.

## Decision

Long-press a tag chip → tick the tags to fold into it → confirm. One
library-wide rewrite.

Four choices were made by the user during design; they are load-bearing and
recorded here so a later reader does not "improve" them away:

| Choice | Answer | Why |
|---|---|---|
| Undo | **No.** A confirmation page instead | A snapshot file and a restore path is a second storage surface to keep correct forever, for an operation the user performs a handful of times. The confirmation page is the only safety net, and it must therefore be informative (§4). |
| Semantics | **N into one existing tag** | Long-press the chip that survives; tick what disappears into it. Chip count strictly decreases. "Merge N tags into a brand-new name" is a different operation and is out of scope. |
| Scope | **Whole library, including archived** | "These two are the same thing" is a fact, not a view. If archived records kept `工作项`, the chip would reappear the next time the user switched to archive mode. |
| Candidates | **Every other tag, count-descending, searchable** | Restricting to substring matches (`工作` → `工作项`) would miss the most common real case: `客户A` into `客户`. |

## §1. `TagMerger` — pure, no I/O

New file `ios/AudioNote/Services/TagMerger.swift`.

```swift
enum TagMerger {
    static func merge(
        records: [TranscriptionRecord],
        into target: String,
        from sources: [String]
    ) -> [TranscriptionRecord]
}
```

Rules for each record:

1. A tag is a **hit** when `TagIdentity.key(tag.name)` is in the source-key
   set, **or** equals `TagIdentity.key(target)`.
2. A record with ≥1 hit keeps **one** `TaggedItem(name: target, score:)` —
   never two entries with the same name.
3. **Score is the max** over all hits. A record holding `工作项` (0.9) and
   `工作` (0.4) becomes `工作` (0.9): the score expresses how relevant the
   topic was to this note, and max is the reading that preserves it. Taking
   the first, or averaging, would both discard information.
4. The merged item sits at the **index of the first hit**, so the existing
   score-descending rendering does not jump around.
5. Non-hits keep their position and score.
6. A record with **no hit** is returned **unchanged** — same `id`, same
   `tags`. Not re-allocated, not re-ordered, not given an empty array.

**Identity is the whole point.** Every comparison routes through
`TagIdentity.key`, the same definition the library filter and chip counts
use. If merge used a different notion of sameness, the failure mode would be
"merged, yet records still carry the old tag" — the operation would report
success while leaving the library in a state the UI cannot explain. Sharing
the definition is what makes the guarantee real rather than intended.

**`sources` is deduplicated by identity before use**, so passing `["工作项",
"工作项"]` is harmless.

**A `sources` containing `target` itself is a no-op**, not a corruption: the
hit set already includes the target, the max is unchanged, and the result is
byte-identical to the input.

## §2. `TranscriptionStorage` — one rewrite, atomically

New method:

```swift
func mergeTags(into target: String, from sources: [String]) async throws
```

`loadAll()` → `TagMerger.merge` → `saveAll()` **once**.

Not a loop over `save(_:)`. `save` re-reads the entire file and re-encodes
all of it on every call, so a merge touching 400 records would be 400 full
read-modify-write cycles — slow, and a failure halfway through leaves a
half-merged library that looks intact. `saveAll` writes `.atomic`, so the
whole rewrite either lands or does not.

If the caller merges with no sources, or with sources that match nothing, the
result is identical to the input; the storage method still writes, which is
harmless but wasteful. The **ViewModel** short-circuits that case before
reaching storage, and a test asserts the pure function's output is
byte-identical for it.

## §3. `TranscriptionViewModel` — and the `selectedTags` trap

```swift
func mergeTag(_ target: String, from sources: [String]) async
```

Storage rewrite, then **`selectedTags` remapping**.

This is the one step that is not about the data. If the user filters by
`工作项`, then merges `工作项` into `工作`, `selectedTags` still holds
`工作项` — a tag that no longer exists on any record. `displayedRecords`
matches nothing, and the library appears **empty**. Nothing crashed; there is
simply no error to show, because the filter is working exactly as written
against a name that is gone.

So after the rewrite, every entry of `selectedTags` whose `TagIdentity.key`
matches a source key is replaced by `target`. Because `selectedTags` is a
`Set<String>`, remapping can collapse two entries into one — which is
correct: those filters were always equivalent.

The remap lives in the ViewModel, not storage. Storage does not know what the
UI has selected, and must not acquire that dependency.

## §4. UI — long-press, select, confirm

`LibraryListView.tagChip` gains a `.contextMenu` with one item, 「合并标签…」,
presenting `MergeTagsView` as a sheet.

```
long-press 「工作」chip
  └─ 「合并标签…」
       └─ sheet: MergeTagsView(target: "工作")
            ├─ search field
            ├─ list: every other tag + count, count-descending, multi-select
            ├─ footer: 「将 N 个标签并入『工作』」
            └─ tap footer → confirmation page
                 「将影响 43 条记录。
                  并入『工作』：
                    工作项 (31)
                    工作进展 (16)
                  记录正文、标题、摘要不受影响。」
                 [取消] [合并]
```

The headline count is the number of **distinct records affected**, not the sum
of the per-source counts. They differ whenever one record carries two of the
selected sources — a record tagged both `工作项` and `工作进展` is rewritten
once, and showing `31 + 16 = 47` would overstate the blast radius. The
per-source numbers keep their own counts because the question the page is
answering is "which tag goes away", not "how many rows change".

Candidate list = `availableTags` minus the target's identity, filtered by the
search string, ordered by `tagCount(for:)` descending. Counts come from the
existing identity-aware `tagCount(for:)` rather than a fresh tally, so the
number in the picker cannot disagree with the number on the chip.

The confirmation page lists **per-source record counts and names**, not just
a total. This is the only safety net (§ Decision table), and a merge is two
taps with a silent, whole-library consequence — the mistake it needs to catch
is pointing the merge the wrong way (`工作` into `工作项` instead of the
reverse), which is only visible if the user is shown which tag is the target
and which are disappearing.

With no source ticked, the merge button is disabled and nothing is written.

## §5. Out of scope

- **`relatedNotes.json` is not touched, and its edges are not recomputed.**
  It stores id pairs and scores, so it is structurally unaffected. But those
  scores were derived from tag overlap, and merging changes the overlap while
  `RelatedNotesService` measures each pair exactly once (§4.4 of
  `2026-10-02-related-notes-design.md`) — so after a merge, some already-listed
  "related notes" will look less related. That is **accepted, not a bug**:
  repairing it would mean re-measuring pairs, which is the decision this app
  deliberately made. Recomputing is left for an explicit reprocess feature.
- No undo, no snapshot file.
- No LLM re-run; `content`, `title`, `summary` and audio are untouched.
- No new ADR. This reuses `TagIdentity` and locks no new decision; the
  "measure each pair once" decision referenced above is unchanged.
- No "merge into a new name". § Decision table.

## Tests

`TagMerger` is pure, so §1 is exhaustively testable; the storage layer is a
single atomic write with no branches of its own.

`TagMergerTests`:

| Case | Assertion |
|---|---|
| one hit | one record rewritten to the target |
| many hits | collapses to **one** entry, not N |
| record already has the target | score is the **max** of all, and exactly one entry survives |
| non-hit records | returned unchanged — same `id`, same `tags` |
| one record carrying two sources | rewritten **once**; affected-record count ≠ sum of per-source counts |
| `tags == nil` | stays `nil`, never becomes `[]` |
| sources differing only by case | deduplicated; merging is not doubled |
| `sources` contains the target | byte-identical no-op |
| archived records | rewritten like any other |
| identity consistency | after merge, `availableTags` has no source spelling left, and no record reports it |

`TranscriptionViewModelTests`:

| Case | Assertion |
|---|---|
| selected source is merged away | `displayedRecords.count` is **unchanged** by the merge — the §3 trap |
| nothing selected | filter state untouched |
| selected target | still selected, filter unchanged |
| no sources / no matches | storage not called |

## Code anchors

| Symbol | Path |
|---|---|
| `TagMerger` (new) | `ios/AudioNote/Services/TagMerger.swift` |
| `TranscriptionStorage.mergeTags` (new) | `ios/AudioNote/Services/TranscriptionStorage.swift` |
| `TranscriptionViewModel.mergeTag` (new) | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` |
| `LibraryListView.tagChip` | `ios/AudioNote/Views/LibraryListView.swift:117` |
| `MergeTagsView` (new) | `ios/AudioNote/Views/MergeTagsView.swift` |
| `TagIdentity` | `ios/AudioNote/Utilities/TagIdentity.swift` |

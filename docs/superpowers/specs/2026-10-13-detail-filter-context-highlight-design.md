# Detail Page — Tag Filter Context Highlight

**Status:** 📋 DESIGNED — not yet implemented
**Created:** 2026-10-13
**Branch at filing:** `main` (`cf37c8b`)
**Related:** `2026-10-13-detail-section-copy-buttons-design.md` (same screen, independent)

---

## 1. Problem

The library's tag filter is **OR**, not AND — `TranscriptionViewModel.swift:727-730`:

```swift
selectedTags.isEmpty
    || record.tagNames.contains(where: selectedTags.contains)
```

Selecting 「工作」+「会议」 returns every record carrying *either*. The list
then sorts by how many of the selected tags a record carries
(`:735-740`), so ordering leaks the hit count — but only in the list, and only
implicitly.

The detail sheet shows none of it. A record carrying 「工作」 but not 「会议」
renders six inert tag chips with nothing marking which of them brought it into
the filtered set. Two questions go unanswered:

- **"Why is this record in my results?"** — the record itself cannot say.
- **"Which of my selected tags did it match?"** — with OR semantics, the
  answer can differ per record and is never stated.

`TagFlowView` (`TranscriptionDetailView.swift:696-727`) is the only tag
renderer in the app and has exactly one call site (`:290`), so there is a
single place to fix.

## 2. Current state (verified 2026-10-13, `main` @ `cf37c8b`)

| Element | Location | Notes |
|---|---|---|
| `selectedTags` | `TranscriptionViewModel.swift:25` | `@Published Set<String>`, lives on the shared VM |
| `searchQuery` | `:24` | `@Published String`, same lifetime |
| OR filter | `:727-730` (displayedRecords), `:787-790` (archivedHitIDs) | **case-sensitive** `Set.contains` on `record.tagNames` |
| Search filter | `matchesSearch` | `localizedCaseInsensitiveContains` over title + summary + tags + content |
| Hit-count sort | `:735-740` | only when `!selectedTags.isEmpty` |
| `TagFlowView` | `TranscriptionDetailView.swift:696-727` | horizontal chips: name (`.caption`) + score (`.caption2`, `.secondary`), `accentColor.opacity(0.1)`, radius 8 |
| Its single call site | `:290` | inside `llmResultsSection`, gated on `!tags.isEmpty` |

### 2.1 Two detail entry points, different context

| Entry | Filter context |
|---|---|
| `LibraryListView.swift:25` — sheet over the filtered list | filter applies |
| `TranscriptionDetailView.swift:646` — push from 相关思考 | filter does **not** apply; the record may not match at all |

A highlight driven by the live `selectedTags` handles both without branching:
via 相关思考, zero chips highlight (nothing matched — correct); via the sheet,
the matching ones light up.

## 3. Options considered

### 3.1 Copy the whole filter bar into the detail sheet

Rejected. The detail is a sheet for reading and editing **one** record; a full
tag-chip row + search field duplicates the list's chrome, and two copies of
filter state in two presentations is a drift bug waiting to happen.

### 3.2 A "came from filter: 工作 + 会议" banner at the top

Rejected. It answers *"what is the filter"* — but the user already knows that;
they just set it. The open question is *"which of these chips is why this
record is here"*, which under OR semantics is per-record and varies row to
row. It also adds a new UI element to a screen whose scroll order is already
long.

### 3.3 Highlight the tags that matched ✅ **CHOSEN**

Light the chips whose names are in the live `selectedTags`; dim the rest.
Answers the actual question, adds no new element, and reuses the chip
component that already exists.

## 4. Decision

**`TagFlowView` takes a `highlighted: Set<String>` and renders matched chips
at full strength, unmatched chips dimmed. `TranscriptionDetailView` passes
`viewModel.selectedTags` directly. No new state, no new gate, no change to
the filter itself.**

### 4.1 The matching predicate must be the filter's own

Highlight uses **exact, case-sensitive** `highlighted.contains(tag.name)`,
matching `displayedRecords:729` exactly.

This matters: `TranscriptionRecord.score(forTagName:)` (`TranscriptionRecord.swift:191-196`)
resolves tag names **case-insensitively**, while the filter does not. A
case-insensitive highlight would light a chip that did *not* actually filter
the record in — reintroducing, on the detail screen, precisely the
misinformation this feature exists to remove. (That
case-sensitivity mismatch between the two functions is itself worth a look;
it is out of scope here and filed as an observation in §8.)

### 4.2 No "is a filter active" gate

`highlighted` is empty whenever nothing is selected, and an empty set renders
every chip identically. The "no filter ⇒ uniform rendering" rule lives in the
component (§5) rather than in the detail view, so `TranscriptionDetailView`
gains no conditional and cannot forget to apply it. There is no state in
which the highlight is wrong — only a state in which it is absent.

### 4.3 `searchQuery` deliberately does not participate

Search matches over a joined haystack (`matchesSearch`), so a record can
satisfy the search through its title or body with no tag involved. Tag chips
therefore highlight from `selectedTags` alone. When only a search is active,
`selectedTags` is empty and the chips render as they do today — which is
correct: no tag was selected.

### 4.4 Accepted consequences

- **Reprocess drops the record out of the result set — left alone, on
  purpose.** Re-running the LLM in the detail view rewrites `tags`. If the
  new tags no longer intersect `selectedTags`, the record leaves
  `displayedRecords` on dismiss. No prompt, no pin, no snapshot. With the
  highlight in place the situation is self-explaining: the chips that were
  lit go dim, and the record's absence from the list is the visible
  consequence of tags that genuinely stopped matching. Extra notification is
  over-engineering for a state the user caused and can see.
- **Extreme case, same handling:** reprocessing the last record carrying a
  given tag can remove that tag from `availableTags` (`:747-768`), so the
  list's filter row loses a chip. Also self-explaining under the highlight.
- **A record reached via 相关思考 may light up coincidentally.** If it shares
  a tag name with the live filter, that chip highlights even though the record
  was not selected by that filter. This is informative rather than wrong —
  it is a true statement about the record's tags — and it is the price of not
  branching on entry point (§2.1).

## 5. Visual specification

Current (every chip identical):

```swift
.background(Color.accentColor.opacity(0.1))
.cornerRadius(8)
```

New:

| Condition | Background | Opacity | Rationale |
|---|---|---|---|
| `highlighted.isEmpty` | unchanged (`accentColor.opacity(0.1)`) | `1` | no filter in play — today's rendering, untouched |
| matched | `accentColor.opacity(0.18)` | `1` | reads as selected; tint is 0.1 → 0.18, not a solid fill, so the `.caption` name and `.caption2` score stay legible and the chip keeps the `radius 8` shape |
| unmatched | unchanged (`accentColor.opacity(0.1)`) | `0.4` | recedes; a filtered-out chip should not compete with a matching one |

Name stays `.caption`; score stays `.caption2` `.secondary` `monospacedDigit`
(`:714-717`) — the score is LLM metadata, not part of the filter signal, so it
is unchanged in all three rows. Chip padding `8 / 4`, spacing `8`, radius `8`
are all untouched (`spacing-and-shape.md §2-3`).

The `.opacity(0.4)` is applied to the chip as a whole rather than re-colouring
its parts — one modifier, and SwiftUI's dimmed-tint rendering keeps the score
readable enough to recognise.

## 6. Files that will change

- `ios/AudioNote/Views/TranscriptionDetailView.swift`
  - `TagFlowView:696-727` — add `let highlighted: Set<String>`, apply the
    three-row table above.
  - `:290` — pass `highlighted: viewModel.selectedTags`.
- `design-system/patterns/detail-sheet.md` — states table gains the
  filter-active row.
- `design-system/tokens/colors.md` — record the 0.1 → 0.18 accent step as the
  chip's "matched" tint.

Not touched: `TranscriptionViewModel` (filter logic unchanged),
`TranscriptionRecord`, `LibraryListView` (its chips already show selection),
storage, any ADR.

## 7. States covered

| State | Rendering |
|---|---|
| No filter active (`selectedTags` empty) | identical to today |
| Filter active, record matches all selected tags | all chips matched |
| Filter active, record matches some | those matched, rest dimmed |
| Filter active, record reached via 相关思考 | whichever chips share a name are matched |
| Search active but no tag selected | identical to today (§4.3) |
| Record has no tags | `TagFlowView` not rendered at all (`:290` gate unchanged) |

## 8. Out of scope

- **Case-sensitivity mismatch** between `displayedRecords:729` (exact) and
  `score(forTagName:)` (`TranscriptionRecord.swift:191-196`, case-insensitive).
  A tag stored as "Work" is invisible to a filter for "work" and vice versa.
  Real, but a separate change with its own blast radius — do not fix it
  inside this one.
- Making the detail chips tappable (navigate back to the library filtered by
  that tag). Discussed and deferred; it needs a VM method and a dismiss, and
  is a genuinely separate feature.
- Any banner / chip-row in the detail.
- **Archived matches list rows are not tappable** — `LibraryArchivedMatchesView:440`
  renders `RecordRowView` with no tap handler, so nothing in the archived
  result list opens a detail. Confirmed as a separate topic; the user deferred
  it. Filed on its own in
  `2026-10-13-archived-matches-rows-not-tappable-design.md`.

## 9. Tests / verification

`codegraph` reports no covering tests for `TranscriptionDetailView` or
`TagFlowView`; both are pure view code. The only logic is a one-line set
membership test. Verification is a device smoke pass — see the plan.

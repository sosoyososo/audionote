# Plan — Detail Page Tag Filter Context Highlight

**Spec:** `docs/superpowers/specs/2026-10-13-detail-filter-context-highlight-design.md`
**Created:** 2026-10-13
**Branch:** `feat/detail-filter-context`
**Status:** not started

## Success criteria

1. With ≥1 tag selected in the library, opening a record's detail lights the
   chips whose names are in `selectedTags` and dims the rest.
2. With no tag selected, the detail renders byte-identically to today.
3. A tag whose casing differs from the record's tag does **not** light up —
   the highlight uses the same exact-match predicate as `displayedRecords:729`.
4. No change to `TranscriptionViewModel` filter/sort logic.
5. `xcodebuild` succeeds; smoke-verified on the iPhone Air.

## Tasks

### Task 1 — `TagFlowView.highlighted`

`ios/AudioNote/Views/TranscriptionDetailView.swift:696-727`.

- Add `let highlighted: Set<String>` (no default — the single call site is
  updated in Task 2, so a missing argument is a compile error, which is the
  right failure mode for a required semantic).
- Inside the existing `ForEach(sortedTags, id: \.name)` chip body, derive
  `let isMatched = highlighted.contains(tag.name)`.
- Apply spec §5's three-row table. Note `highlighted.isEmpty` must be checked
  first so an empty set renders uniformly rather than dimming every chip.

**Verify:** `xcodebuild build` — no test is warranted for a `Set.contains`
and three opacity/background ternaries.

### Task 2 — Pass the filter at the call site

`TranscriptionDetailView.swift:290`.

```swift
TagFlowView(tags: tags, highlighted: viewModel.selectedTags)
```

`selectedTags` is already `@Published` on the VM this view observes
(`:5`), and the chip block already re-renders when `currentRecord` changes,
so no new observation wiring is needed.

**Verify:** build.

### Task 3 — design-system docs

- `design-system/patterns/detail-sheet.md` §4 states table — add
  "filter active" row.
- `design-system/tokens/colors.md` — record `accentColor.opacity(0.1)` as the
  base chip tint and `0.18` as the matched tint, so the next chip does not
  invent a third value.

**Verify:** `grep -rn "accentColor.opacity" design-system/` shows both values
documented.

### Task 4 — Verification pass

1. `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -destination
   'platform=iOS Simulator' build`
2. `xcodebuild … -destination 'generic/platform=iOS' build`
3. Install + launch on the iPhone Air (`memory/ios-device-registry.md`).
4. Smoke:
   - No filter → open a record with tags → all chips identical to before.
   - Select one tag the record carries, and (where possible) two where the
     record carries only one → the carried one is lit, the other dimmed.
   - Open a record via 相关思考 → nothing lit, or only the coincidental ones.
   - Search-only filter → all chips identical to the no-filter case.
5. `superpowers:verification-before-completion` before reporting done.

## Notes / risks

- The dim value (`0.4`) is a judgement call from spec §5, not a measured one.
  Task 4 step 4 is where it gets confirmed; adjust in place if it reads as
  too faint or too strong on the real device.
- Do **not** "tidy" the case-sensitivity mismatch noted in spec §8 while in
  this file. It changes filter behaviour and belongs to its own change.
- Independent of `2026-10-13-detail-section-copy-buttons-plan.md`; both touch
  `TranscriptionDetailView` but not the same lines. If both land, resolve
  conflicts by merging, not by rebasing one over the other.

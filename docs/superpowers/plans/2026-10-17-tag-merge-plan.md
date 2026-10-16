# Plan — Tag Merge

**Spec:** `docs/superpowers/specs/2026-10-17-tag-merge-design.md`
**Created:** 2026-10-17
**Branch:** `feat/tag-merge`
**Status:** not started

## Success criteria

1. Long-pressing a tag chip offers 「合并标签…」; the sheet lists every other
   tag with its count as a multi-select **grid in pinyin order**, searchable.
   (Layout and order were revised after the first device smoke — spec §4.1.)
2. Confirming folds the selected tags into the long-pressed one across the
   **whole library including archived**, in one atomic write.
3. A record carrying two of the merged tags is rewritten **once**, and the
   confirmation headline count is the number of distinct records affected —
   not the sum of per-source counts.
4. Merging while a merged-away tag is selected leaves every previously
   visible record visible — a **superset**, not an unchanged count, since the
   target's own records now legitimately belong to the same filter (spec §3).
5. No tag chip for a merged-away spelling survives anywhere, by `TagIdentity`
   identity — the library has no state that contradicts itself.
6. `xcodebuild` succeeds for iphonesimulator and iphoneos; manual smoke on
   the iPhone Air runs the whole flow; `relatedNotes.json` is untouched.
7. All new tests green, existing suite still green (153 before this change).

## Testing reality — read before writing tests

`TranscriptionViewModel.storage` is `private let storage = TranscriptionStorage.shared`
(`TranscriptionViewModel.swift:35`) with **no injection seam**. So any VM
method that performs I/O cannot be unit-tested, and every existing VM test in
the repo (`TagHygieneTests`, `TagCaseInsensitivityTests`,
`LibraryArchiveModeTests`) tests only pure computed properties after setting
`historyRecords` directly.

`PendingRecognitionPolicy` exists precisely because of this — `docs/GLOSSARY.md`
records it as "extracted as pure statics because `TranscriptionViewModel`'s
collaborators are `private let` singletons and so the VM itself cannot be
unit-tested." This plan follows that precedent.

**Consequence:** the `selectedTags` remap — the one piece of logic in §3 with
real edge cases — is extracted as a **pure static on `TagMerger`** and tested
there. The VM method becomes a three-line orchestration of
`storage.mergeTags` + `TagMerger.remappedSelection` + `loadHistory`, verified
by build and manual smoke only. That is stated here so nobody later mistakes
the absence of a VM test for an oversight.

There is also no ViewInspector or equivalent: **the UI layer has no automated
verification at all.** Tasks 5–7 verify by `xcodebuild` plus the manual smoke
in Task 8.

## Tasks

### Task 1 — `TagMerger`, the pure rewrite

New `ios/AudioNote/Services/TagMerger.swift`.

```swift
enum TagMerger {
    static func merge(
        records: [TranscriptionRecord],
        into target: String,
        from sources: [String]
    ) -> [TranscriptionRecord]
}
```

- Build the hit set as `TagIdentity.matchingKeys(Set(sources))` **unioned**
  with `TagIdentity.key(target)`. The union is what makes a record that
  already carries the target participate in the max — without it, a record
  holding `工作` (0.4) and `工作项` (0.9) would keep `工作` (0.4) untouched
  and gain a second `工作` (0.9) beside it.
- Dedupe `sources` by identity first: `["工作项", "工作项"]` is harmless.
- Per record: walk `tags`; collect `(index, score)` for hits; if none, return
  the record **unchanged** (same instance value, `tags` never nil→[]).
- If hits exist: merged item at the **first** hit index with score
  `hits.map(\.score).max()`; non-hits keep their index and score; rebuild the
  array so the length shrinks by `hits.count - 1`.
- `TranscriptionRecord` is a struct with `var tags` — mutate a local copy.
  Confirm which other fields are non-optional-by-default before writing, so
  the rewrite cannot silently reset `archived`, `audioFileName` or
  `optimizedContent`.

**Verify:** compiles. No test in this task.

### Task 2 — `TagMerger` tests

New `ios/AudioNoteTests/TagMergerTests.swift`, covering the spec's table:

- one hit → rewritten to target
- many hits on one record → **exactly one** entry, not N
- record already carrying the target → score is the max, still exactly one
- no-hit record → `id` and `tags` both unchanged
- `tags == nil` → still `nil`, never `[]`
- two sources on one record → one rewrite; affected count ≠ sum of counts
- sources differing only in case → deduplicated (merge runs once, score is
  not inflated)
- `sources` contains the target → output byte-identical to input
- archived record → rewritten like any other
- **identity consistency:** after merging `工作项` into `工作`, no record's
  `tagNames` reports `工作项` under any spelling, and `TagIdentity.matching`
  finds no leftover
- empty `sources` → identical output

Reuse the fixture shape from `TagHygieneTests` (`record(_:id:tags:archived:status:)`)
rather than inventing a second one.

**Verify:** `xcodebuild test` — new suite green.

### Task 3 — `TagMerger.remappedSelection`

Same file:

```swift
static func remappedSelection(
    _ selected: Set<String>,
    into target: String,
    from sources: [String]
) -> Set<String>
```

Replaces every entry whose `TagIdentity.key` is in the source-key set with
`target`. Because the result is a `Set`, two entries can collapse into one —
correct, since those filters were already equivalent.

Tests: source selected → becomes target; unrelated selection untouched;
target already selected → unchanged; both spellings selected → one entry.

**Verify:** `xcodebuild test`.

### Task 4 — `TranscriptionStorage.mergeTags`

`ios/AudioNote/Services/TranscriptionStorage.swift`, after `delete(id:)`.

```swift
func mergeTags(into target: String, from sources: [String]) async throws
```

`loadAll()` → `TagMerger.merge` → `saveAll()` once. Document why this is not
a loop over `save(_:)`: `save` re-reads and re-encodes the whole file per
call, so 400 affected records would be 400 full cycles and a mid-way failure
would leave a half-merged library that looks intact.

Not independently testable (no `init(fileURL:)` seam on `TranscriptionStorage`
— verify this while editing; if one exists after all, use it).

**Verify:** `xcodebuild build`.

### Task 5 — `TranscriptionViewModel.mergeTag`

`ios/AudioNote/ViewModels/TranscriptionViewModel.swift`, near `toggleTag`
(line ~945).

```swift
func mergeTag(_ target: String, from sources: [String]) async
```

- Early-return when `sources.isEmpty`, or when no record carries any source
  identity — the storage layer would write an identical file otherwise.
- `try await storage.mergeTags(into: target, from: sources)`
- `selectedTags = TagMerger.remappedSelection(selectedTags, into: target, from: sources)`
- `await loadHistory()`
- Set `errorMessage` on throw, matching `stopRecording`'s convention.

Add a doc comment naming the §3 trap, because the `selectedTags` line looks
removable to a future reader and deleting it produces an empty-looking library
with no error.

**Verify:** `xcodebuild build` + Task 8 smoke.

### Task 6 — Localization

`ios/AudioNote/Resources/en.lproj/Localizable.strings` **and** `zh-Hans.lproj/Localizable.strings`.
Follow the existing `Library.*` key style.

| Key | en | zh-Hans |
|---|---|---|
| `Library.MergeTags.Action` | Merge Tags… | 合并标签… |
| `Library.MergeTags.Title` | Merge into "%@" | 并入「%@」 |
| `Library.MergeTags.Search` | Search tags | 搜索标签 |
| `Library.MergeTags.Footer` | Merge %d tag(s) into "%@" | 将 %d 个标签并入「%@」 |
| `Library.MergeTags.Confirm.Title` | Will affect %d record(s). | 将影响 %d 条记录。 |
| `Library.MergeTags.Confirm.Body` | Content, title and summary are not affected. | 记录正文、标题、摘要不受影响。 |
| `Library.MergeTags.Confirm.Button` | Merge | 合并 |

Both files — a key present in only one locale falls back to the key string.

**Verify:** `xcodebuild build`.

### Task 7 — `MergeTagsView` + chip context menu

New `ios/AudioNote/Views/MergeTagsView.swift`.

- `struct MergeTagsView: View` — `target: String`, `viewModel:`, and an
  `@Environment(\.dismiss)`.
- Candidates: `viewModel.availableTags` minus `TagIdentity.key(target)`,
  filtered by the search field, ordered by `viewModel.tagCount(for:)` desc
  then by name for a stable tie-break. **Use `tagCount(for:)`**, not a fresh
  tally, so the number here cannot disagree with the number on the chip.
- Footer disabled while nothing is ticked.
- Footer → confirmation: headline is `Set<record ids carrying a source>`
  **counted distinctly** (build the id set; do not sum per-source counts),
  then one row per source with its own `tagCount(for:)`.

`LibraryListView.tagChip` (`LibraryListView.swift:117`) gains:

```swift
.contextMenu {
    Button("Library.MergeTags.Action".localized) { mergingInto = tag }
}
.sheet(item: $mergingInto) { target in
    MergeTagsView(target: target, viewModel: viewModel)
}
```

with `@State private var mergingInto: String?`. `.sheet(item:)` needs the
value `Identifiable` — wrap in `struct TagTarget: Identifiable { let name: String }`
rather than reaching for `.sheet(isPresented:)` plus a separate binding.

Note `tagChip` currently builds and returns a `Button` directly; the
`.contextMenu` attaches to it without changing the tap-to-filter behaviour.

**Verify:** `xcodebuild build` for both SDKs.

### Task 8 — Regenerate, build, smoke, merge

```sh
cd /Users/karsa/proj/audionote/ios && xcodegen generate   # new .swift files
xcodebuild test -project …/AudioNote.xcodeproj -scheme AudioNote \
  -destination 'platform=iOS Simulator,name=iPhone Air'
xcodebuild -project … -scheme AudioNote \
  -destination 'platform=iOS,id=3C0B7BE4-2AEF-54E4-B937-9A0C96326420' \
  DEVELOPMENT_TEAM=8V95JS2XCZ -derivedDataPath /tmp/an-dd build
codesign -d --entitlements - /tmp/an-dd/.../AudioNote.app   # expect 8V95JS2XCZ
xcrun devicectl device install app --device 3C0B7BE4-… /tmp/an-dd/.../AudioNote.app
xcrun devicectl device process launch --device 3C0B7BE4-… info.karsa.app.ios.audionote
```

`xcodegen generate` is **not** optional — `TagMerger.swift` and
`MergeTagsView.swift` are new files and `xcodebuild` will not see them
without it, failing with `Cannot find 'TagMerger' in scope`. Check
`git diff ios/AudioNote.xcodeproj/project.pbxproj` afterwards; a
`DEVELOPMENT_TEAM` change there means the signing-team trap in
`memory/ios-device-registry.md` has recurred — fix with `xcodegen generate`.

Manual smoke on the device, in this order:

1. Long-press a chip → the sheet opens as a grid of tags with counts, in
   pinyin order, target excluded, ticks showing as an accent fill.
2. **Filter by a tag, then merge that very tag away.** The records that were
   on screen must still be on screen, and the list must not be empty. It may
   legitimately show **more** — the target's own records now belong to the
   same filter. This is the §3 trap — the only automated coverage of its
   logic is Task 3, and this is the end-to-end proof.
3. Confirm a merge → check `transcriptions.json` that both spellings are gone
   from `tags`, including on archived records.
4. Switch to archive mode → the merged-away chip is **not** there.
5. Check `relatedNotes.json`'s mtime/content is untouched.
6. Cancel out of a confirmation → nothing changed.

Then: docs sync (`docs/GLOSSARY.md` rows for `TagMerger`,
`TranscriptionStorage.mergeTags`, `TranscriptionViewModel.mergeTag`;
`design-system/patterns/library-list.md` §1c gains the long-press entry), one
commit per task group, and fast-forward merge to `main`.

## Risks

- **Score semantics.** `max` is a judgement call recorded in the spec. If a
  merged tag looks over-ranked after use, that is the decision to revisit —
  not a bug to fix silently.
- **The union in Task 1** is the subtle line. Without it, a record already
  holding the target gains a duplicate. Task 2's "already carrying the
  target" case is the one that catches it.
- **Related-notes scores go stale** after a merge. Accepted per spec §5;
  worth telling the user the first time they notice.

# Pattern: Library list (search + tag chips + grouped list)

> **Status: inferred** — extracted from `ios/AudioNote/Views/LibraryListView.swift`.

## §1. Anatomy

```
NavigationView
└── VStack(spacing: 0)
    ├── searchBar                       ← HStack with magnifyingglass + TextField + clear
    ├── tagChipsRow                     ← horizontal chip row OR "no tags" caption
    ├── filterStatusBar                 ← the filters in effect: removable chips + "5 of 8" + 清除
    └── content                         ← empty | noResults | recordsListView
    .navigationTitle(navigationTitle)    // "文库" or "归档 · N" — the archive-mode indicator
    .toolbar { ToolbarItem(.topBarTrailing) { archiveToggle } }
    .sheet(item: $selectedRecord) { … }   // TranscriptionDetailView
    .alert(isPresented: $showDeleteConfirmation) { … }
    .overlay(alignment: .top) { ToastView … }
    .task { await viewModel.loadHistory() }
    .refreshable { await viewModel.loadHistory() }
```

`filterStatusBar` appears **only** while something is selected — it costs no
space the rest of the time. It sits *below* the tag row, not between the
search field and the row: the two filter **controls** stay one unbroken
block at the top, and the state appears directly above the list it filters.

## §1b. Archive mode

Archive is a **view mode, not a banner**. `isArchiveMode` flips the whole
list onto the archived half of the library; search and tag chips keep
filtering exactly as they do on the live list.

| Element | Live | Archive |
|---|---|---|
| `navigationTitle` | `Tab.Library` | `Library.ArchiveModeTitle` ("归档 · %d") |
| Toggle icon | `archivebox` | `archivebox.fill` |
| Toggle disabled | when `archivedRecordCount == 0` | **never** |
| Badge | — | `archivedRecordCount`, unfiltered |

Rules the split introduced:

- Filters are **not** cleared on toggle. A tag selected on the live side
  that no archived record carries still renders as a chip at count 0
  (`availableTags` synthesizes it) — otherwise the filter would be applied
  with nothing on screen to switch off.
- That synthesized chip sorts **last** (score `-infinity`).
- The toggle is gated on `canToggleArchiveMode`, not `archivedRecordCount`.
  Inside the archive it stays live even at 0 records: gating it on the count
  alone kills the only control that leaves archive mode when the user deletes
  the last archived record.
- `archivedRecordCount` ignores `searchQuery` / `selectedTags`: "you have
  12 archived" must not read as 0 because the user typed something.
- Un-archive is via the detail sheet's existing action, not a swipe.

## §1c. Tag chips

One chip per **tag identity**, not per spelling. Tags come from an LLM that
picks casing per record, so `availableTags` groups by `TagIdentity.key`
(lowercased) and `Work` / `work` collapse into a single chip.

| Rule | Behaviour |
|---|---|
| Displayed form | the spelling carried by the **most records**; ties → higher score; ties → raw `<` so it stays deterministic (a case-insensitive compare returns "same" for exactly this pair) |
| Chip order | by max score across the whole group desc; ties alphabetical |
| Count | sums **all** spellings — read via `tagCount(for:)`, since `tagCounts` is keyed by identity |
| Match | case-insensitive everywhere; a record spelled either way is found by the one chip |
| Blank | a whitespace-only tag is dropped, not rendered — it would be an invisible pill the user cannot tap off |

Chinese tags are unaffected by the case axis — CJK has no case, so
`lowercased()` is a no-op for them. Their dirty-data source is **vocabulary**
drift (`工作` / `工作项` / `工作会议`), which chip merging cannot fix because
those are genuinely different strings; that is what the LLM prompt's
vocabulary hint (`existingTagVocabulary`) addresses at the source.

### §1c.1. Long-press: merge tags into this one

A chip carries a `contextMenu` with one entry — **Merge Tags…** — which opens
`MergeTagsView(target:viewModel:)` for that chip's name. Long-press rather
than a visible affordance on purpose: folding tags together is a repair
action for a library that has drifted, not something to offer on every chip
on every screen.

`MergeTagsView` is **two stages in one screen** — pick, then confirm — not a
sheet plus an `alert`:

| Rule | Reason |
|---|---|
| Confirm is a screen, not an alert/dialog | There is no undo, so the confirmation is the only thing standing between a mistyped merge and a whole-library rewrite. It has to name the target *and* every tag that disappears *with its count*; `confirmationDialog` has no message slot and an `alert`'s is too small for the list |
| Affected count is **distinct records**, not the sum of per-tag counts | One record carrying two ticked tags is rewritten once. The page exists to make the blast radius clear — adding its count twice overstates it |
| Picker is a **`FlowRow`** of content-sized tiles, **pinyin/alphabetical** order | One-per-row was a blind scroll through dozens of tags. Order is `localizedStandardCompare`, **not** the chip row's score-descending `availableTags` — see below |
| `FlowRow` (custom `Layout`), **not** `LazyVGrid` / `GridItem(.adaptive)` | `GridItem(.adaptive)` computes a *column count* from a fixed minimum width and then divides the width equally, so every cell is the same size no matter what it holds. Tag names vary by an order of magnitude, so equal columns leave most of every row empty. Costs: no laziness (a `Layout` receives every subview up front — fine for dozens of two-`Text` tiles), and tiles must size to content, never `maxWidth: .infinity`, or they report infinity and each takes its own line |
| Tiles are a fixed 32pt height, `minWidth: 44` | Level lines without per-line vertical centering, and `cornerRadius(16)` on 32pt is the same pill the chip row uses. The 44pt floor keeps short tags like `AI` tappable — a pure content-width tile would be well under the HIG minimum |
| Selection is an **accent fill**, not a trailing ✓ | The checkmark worked in a single column only because it sat in the same place at the right edge of every row. In a grid with varying text widths it is too weak to scan, and *which tags are already ticked* is what has to be legible at a glance — multi-select is the point of the screen |
| Tiles echo the chip (same radius, padding, accent-when-on) | Ticking tags here should feel like ticking the chips in the chip row, not like a different UI |
| Count comes from `tagCount(for:)` | The number on a tile cannot disagree with the number on the chip that was just pressed |
| Empty search result says so | Otherwise a search that matches nothing shows a blank grid with no explanation |
| Merge button sits in a `safeAreaInset` bottom footer on both stages | The path from "I chose tags" to "I am about to rewrite my library" stays one continuous gesture instead of jumping between toolbars |
| Merge button is `.tint(.red)` | Destructive-ish, permanent, whole-library. Not the same weight as an ordinary confirm |

**Why the picker is *not* sorted like the chip row.** Consistency with the
chips looks like the obvious call, and it was the question asked. It is
wrong because the two orderings answer different questions. `availableTags`
sorts by max score desc: that is a *discovery* ranking for a horizontal
strip, whose job is to float the most important tags into view without the
user reading anything. The picker is a *lookup* surface — the job is "find
the misspelling, tick it" — and what makes a flow findable is a **position
you can predict**. A score ranking has no predictable position; you would
read every cell to decide whether to stop. Count-descending survives a single
column (scan down, stop when it gets small) and does not survive the grid;
pinyin order is what pairs with the grid. The tie-break was dropped along
with the count ordering, since with an alphabetical primary key there is
nothing to tie-break.

**A ragged flow is accepted here, knowingly.** In a grid of equal-width
cells the selected fill is a tidy matrix, which scans well; in a flow it is
ragged, which scans worse. Content sizing won anyway because the waste is
worse: equal columns leave a `学习` cell as wide as a `产品季度复盘纪要`, so
most of every row is empty. The scan is carried by the fill plus the
fixed-height pill shape instead — tiles stay visually uniform even though
their widths are not.

## §1d. The chip strip and its pinned control

The tag row is **two** things side by side, and they must not read as one:

| Element | Behaviour |
|---|---|
| Chip strip | horizontal `ScrollView`; chips scroll under the finger |
| Pinned control | `全部 %d` button, **outside** the scroll, always in the same place |

The pinned control sits outside the scroll on purpose: a button at the end
of the scroll is the one thing the user cannot reach. It carries the tag
count, so the row no longer hides what is over there.

Both horizontal strips on this screen — the tag row and the filter-status
row — follow the same two rules.

### §1d.1 The trailing fade

A scroll view cuts its content off with a hard edge, and a chip cut in
half right next to the pinned control reads as the control sitting *on*
the strip. Both strips therefore fade their trailing edge
(`fadeOutTrailingEdge()`, `LibraryListView.swift`).

| Rule | Reason |
|---|---|
| The fade **masks to transparent**, not to a colour | The strip sits on whatever the row is on; a colour fade would have to know that colour, and would be wrong the moment the row's background changes |
| The fade is on the **viewport**, not the content | A strip shorter than the screen has nothing to fade, so a short list is unaffected |
| The fade is **one-sided** (trailing only) | The leading edge is the screen edge; there is nothing to fade into |

### §1d.2 The hairline rule

The pinned control is separated from the strip by a 1pt
`Color(.separator)` rule (22pt tall) with 12pt gaps on either side.

| Rule | Reason |
|---|---|
| A **rule**, not more spacing | Spacing alone leaves the two running together; the rule is what says "the left scrolls, the right does not" |
| The rule is **22pt**, shorter than the 29pt chips | A rule as tall as the content reads as a border; shorter reads as a separator |
| `Color(.separator)`, not a fixed grey | Adapts to dark mode without a second token |

The rule appears on the **tag row only**. The filter-status row separates
its scroll strip from its pinned controls with the "5 of 8" count, which
already reads as a caption rather than as a rule.

## §2. Row visual conventions

`RecordRowView` (`LibraryListView.swift:338-451`):

```swift
VStack(alignment: .leading, spacing: 4) {
    Text(displayTitle).font(.body).lineLimit(1)
    Text(displaySummary).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
    tagsRow                                                  // optional
    HStack(spacing: 8) {
        Text(time, style: .time).font(.caption).foregroundColor(.secondary)
        if duration > 0 { Text("Duration …").font(.caption).foregroundColor(.secondary) }
        if archived { Text("Archived").font(.caption2).foregroundColor(.orange) }
    }
}
```

`tagsRow` (`:371-393`): inline `#tag × 3 max + +N` overflow; `.caption` + `.secondary`; sorted by score desc.

## §3. State branches

- `!viewModel.hasRecordsInScope` → `scopeEmptyState` (`emptyLibraryState` live, `Library.ArchiveEmpty` in archive mode)
- `viewModel.displayedRecords.isEmpty` (after filter) → `noResultsState`
- else → `recordsListView` (grouped by date: Today / Yesterday / Date)

`hasRecordsInScope` deliberately asks "is this side empty?" rather than
"is the whole library empty?", so archiving your last live record shows the
empty-library state instead of a no-results state with a pointless
"clear filters" button.

## §4. Context menu / swipe

- Swipe-trailing (destructive): Label("Action.Delete", systemImage: "trash")
- Context menu: View / Copy (with Divider) / Delete (destructive)

## §5. States covered

- ✅ empty library
- ✅ archive empty (`Library.ArchiveEmpty`)
- ✅ no-results (filtered)
- ✅ populated (grouped)
- ✅ archive mode (title + filled icon + 0-count orphan chip)
- ✅ delete-confirmation alert
- ✅ share-sheet modal
- ✅ toast

## §6. Self-review

- [x] Did I check `design-system/`? — bootstrap
- [x] Rationale? — code extraction
- [x] States covered? — §5
- [x] Provenance? — **inferred**

## §7. Open questions

1. The `tagChip` (`:113-139`) and the language chip in
   `RecordingView.swift:116-141` are visually very similar (rounded pill,
   selected vs unselected). One component to rule them both?
2. The `archivedBanner` is a one-off visual — no other place uses the
   same `Color.orange.opacity(0.1)` background + orange foreground. Keep
   inline or extract?
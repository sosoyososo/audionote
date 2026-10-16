# Pattern: Library list (search + tag chips + grouped list)

> **Status: inferred** — extracted from `ios/AudioNote/Views/LibraryListView.swift`.

## §1. Anatomy

```
NavigationView
└── VStack(spacing: 0)
    ├── searchBar                       ← HStack with magnifyingglass + TextField + clear
    ├── tagChipsRow                     ← horizontal chip row OR "no tags" caption
    └── content                         ← empty | noResults | recordsListView
    .navigationTitle(navigationTitle)    // "文库" or "归档 · N" — the archive-mode indicator
    .toolbar { ToolbarItem(.topBarTrailing) { archiveToggle } }
    .sheet(item: $selectedRecord) { … }   // TranscriptionDetailView
    .alert(isPresented: $showDeleteConfirmation) { … }
    .overlay(alignment: .top) { ToastView … }
    .task { await viewModel.loadHistory() }
    .refreshable { await viewModel.loadHistory() }
```

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

## §2. Row visual conventions

`RecordRowView` (`LibraryListView.swift:326-413`):

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
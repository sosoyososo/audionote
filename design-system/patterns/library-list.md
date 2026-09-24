# Pattern: Library list (search + tag chips + grouped list)

> **Status: inferred** — extracted from `ios/AudioNote/Views/LibraryListView.swift`.

## §1. Anatomy

```
NavigationView
└── VStack(spacing: 0)
    ├── searchBar                       ← HStack with magnifyingglass + TextField + clear
    ├── tagChipsRow                     ← horizontal chip row OR "no tags" caption
    ├── archivedBanner                  ← only when archivedHitCount > 0
    └── content                         ← empty | noResults | recordsListView
    .sheet(item: $selectedRecord) { … }   // TranscriptionDetailView
    .alert(isPresented: $showDeleteConfirmation) { … }
    .overlay(alignment: .top) { ToastView … }
    .task { await viewModel.loadHistory() }
    .refreshable { await viewModel.loadHistory() }
```

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

- `viewModel.historyRecords.isEmpty` → `emptyLibraryState`
- `viewModel.displayedRecords.isEmpty` (after filter) → `noResultsState`
- else → `recordsListView` (grouped by date: Today / Yesterday / Date)

## §4. Context menu / swipe

- Swipe-trailing (destructive): Label("Action.Delete", systemImage: "trash")
- Context menu: View / Copy (with Divider) / Delete (destructive)

## §5. States covered

- ✅ empty library
- ✅ no-results (filtered)
- ✅ populated (grouped)
- ✅ archived-banner visible
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
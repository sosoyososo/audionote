# Pattern: Detail sheet (TranscriptionDetailView)

> **Status: inferred** — extracted from `ios/AudioNote/Views/TranscriptionDetailView.swift`.

## §1. How it's launched

```swift
// LibraryListView.swift:23-30
.sheet(item: $selectedRecord) { record in
    NavigationView {
        TranscriptionDetailView(record: record, viewModel: viewModel)
    }
}
```

Identifiable binding (`item:`) + wrapped in its own `NavigationView` so the
sheet can host navigation chrome + toolbar items.

## §2. Anatomy

```
ScrollView
└── VStack(alignment: .leading, spacing: 16)
    ├── metadataSection       ← date / time / duration / recognition-mode
    ├── Divider
    ├── contentSection        ← "优化后" seal + body or TextEditor
    ├── actionsSection        ← upgrade + archive buttons
    ├── (if audioFileName) PlaybackControlBar
    └── llmResultsSection     ← title / summary / tags / status

.toolbar {
    ToolbarItem(.cancellationAction) { close-or-cancel }
    ToolbarItem(.primaryAction) { save-or-actions }
}

.sheet(isPresented: $actionsViewModel.showShareSheet) { ShareSheet(items: …) }
.overlay(alignment: .bottom) {
    ToastView(message: actionsViewModel.toastMessage,
              isShowing: $actionsViewModel.showCopiedToast)
        .padding(.bottom, 40)
}
```

## §3. Visual conventions

- Section header inside `llmResultsSection` uses `.caption` + `.secondary`
  for the field label (e.g. "Detail.LLM.Title"), and `.body` / `.headline`
  for the value.
- Recognition-mode row: SF Symbol + label, both `.foregroundColor(style.color)`
  (icon + colour share the colour).
- Upgrade button (`在线升级识别`): `.padding(.vertical, 10).padding(.horizontal, 16).background(Color.blue.opacity(0.1)).foregroundColor(.blue).cornerRadius(10)`
- Archive button: same shape, `.orange` if archived else `.gray 0.1` + `.primary`.

## §4. States covered

- ✅ viewing (read-only)
- ✅ editing (TextEditor + Cancel/Save toolbar)
- ✅ LLM processing (spinner + disabled)
- ✅ LLM completed (show title/summary/tags + re-process button)
- ✅ LLM failed (failure button + retry)
- ✅ share sheet (modal)
- ✅ toast (bottom overlay)

## §5. Self-review

- [x] Did I check `design-system/`? — bootstrap
- [x] Rationale? — code extraction
- [x] States covered? — §4
- [x] Provenance? — **inferred**

## §6. Open questions

1. The upgrade button and archive button both use `.cornerRadius(10)` —
   similar to the language chip pattern. Worth a shared `ActionChipStyle`
   view modifier?
2. The detail's edit card uses `cornerRadius(8)`, smaller than the
   `TextCard` default (12) — see `components/text-card.md §6`.
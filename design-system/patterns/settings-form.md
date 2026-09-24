# Pattern: Settings form

> **Status: inferred** — extracted from `ios/AudioNote/Views/SettingsView.swift` and `ProfileDetailView.swift`.

## §1. Anatomy

`SettingsView` uses SwiftUI's stock `Form { Section { … } header: { … } footer: { … } }` pattern:

```swift
Form {
    Section { /* rows */ }
        header: { Text("Title".localized) }
        footer: { Text("Hint".localized) }
    Section { /* rows */ }
}
.navigationTitle("Tab.Settings".localized)
```

`ProfileDetailView` reuses the same pattern with three sections (provider
info, auth, footer warning).

## §2. Row visual conventions

- Profile row: `Image(systemName: <active|inactive>)` + `VStack(alignment: .leading, spacing: 2)` containing name + baseURL (caption) + model (caption2) + trailing "Set active" `Button("…") { … } buttonStyle(.bordered)`
- Empty state: caption-only `Text("NoneActive".localized).foregroundColor(.secondary)`
- Status section: one row with key + value; "Not set" case uses `orange` foreground

## §3. Where this pattern applies

- Only `SettingsView` and `ProfileDetailView` today.
- Not relevant to the Recording Screen directly (Recording is its own
  vertical layout), but is the canonical pattern for any future settings
  additions.

## §4. States covered

- ✅ empty (no rows in a section)
- ✅ populated (rows)
- ✅ active vs inactive (different leading icon + colour)
- ✅ status unknown (orange foreground + emoji ⚠️)
- ✅ migrating (transient toast)

## §5. Self-review

- [x] Did I check `design-system/`? — bootstrap
- [x] Rationale? — code extraction
- [x] States covered? — §4
- [x] Provenance? — **inferred**

## §6. Open questions

1. The "Settings.LLM.Status" row's emoji `✅` / `⚠️` is hard-coded — should
   it use SF Symbols (`checkmark.circle.fill` / `exclamationmark.triangle.fill`)
   for consistency with the rest of the app? The ProfileDetailView already
   uses SF Symbols (`:118` / `:122` / `:130`).
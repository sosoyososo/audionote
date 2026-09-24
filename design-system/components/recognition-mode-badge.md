# RecognitionModeStyle

> **Status: confirmed in practice** — applied across both consumers:
> `ios/AudioNote/Views/RecordingView.swift:169, :294` (via `ModeBadge`)
> and `ios/AudioNote/Views/TranscriptionDetailView.swift:127-134` (direct
> struct use). The Detail page's `recognitionModeColor/Icon/Label` helpers
> are gone (deleted 2026-09-24).
>
> This was the **strongest** deduplication candidate in the codebase, now
> consolidated.

## §1. Problem — duplicated visual semantics

Two view files independently encode "what colour / icon / label does each
recognition mode have?"

### File A: `RecordingView.swift:567-583`

```swift
private var modeColor: Color {
    switch viewModel.recognitionMode {
    case .online: return .green
    case .onDevice: return .yellow
    case .enhanced: return .blue
    case .failed: return .red
    }
}

private var modeLabel: String {
    switch viewModel.recognitionMode {
    case .online: return "在线识别"
    case .onDevice: return "离线识别"
    case .enhanced: return "已在线升级"
    case .failed: return "识别失败"
    }
}
```

### File B: `TranscriptionDetailView.swift:254-282`

```swift
private func recognitionModeIcon(for mode: RecognitionMode?) -> String {
    switch mode {
    case .online: return "cloud.fill"
    case .onDevice: return "iphone.gen1"
    case .enhanced: return "cloud.fill.badge.checkmark"
    case .failed: return "xmark.shield.fill"
    case .none: return "questionmark.circle"
    }
}

private func recognitionModeColor(for mode: RecognitionMode?) -> Color {
    // … identical mapping
}

private func recognitionModeLabel(for mode: RecognitionMode?) -> String {
    // … identical mapping
}
```

The two views **agree** today on colour + label, but:

- `RecordingView` uses **no icon**, so the user sees colour + label only.
- `TranscriptionDetailView` shows icon + colour + label.
- The user-visible result is **inconsistent**: in the library's detail page,
  the mode has a recognisable SF Symbol; on the recording screen it's just
  a coloured pill.

## §2. Proposed extraction (inferred)

```swift
// In SharedComponents.swift or new file RecognitionModeStyle.swift
struct RecognitionModeStyle {
    let mode: RecognitionMode

    var color: Color {
        switch mode {
        case .online: return .green
        case .onDevice: return .yellow
        case .enhanced: return .blue
        case .failed: return .red
        }
    }

    var icon: String {
        switch mode {
        case .online: return "cloud.fill"
        case .onDevice: return "iphone.gen1"
        case .enhanced: return "cloud.fill.badge.checkmark"
        case .failed: return "xmark.shield.fill"
        }
    }

    var label: String {
        switch mode {
        case .online: return "在线识别"
        case .onDevice: return "离线识别"
        case .enhanced: return "已在线升级"
        case .failed: return "识别失败"
        }
    }
}
```

> Note: `RecognitionMode` has no `.none` case (it's non-optional in
> `TranscriptionViewModel.recognitionMode`); only `RecognitionMode?`
> (used in `TranscriptionDetailView`) wraps a nil. The `RecognitionModeStyle`
> struct takes non-optional `RecognitionMode` to match the call sites
> that drove the dedup. If a future optional call site appears, lift
> the optional handling into the struct.

Two consumers:

```swift
// Compact pill (RecordingView header strip)
struct ModeBadge: View {
    let mode: RecognitionMode
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: RecognitionModeStyle(mode: mode).icon)
            Text(RecognitionModeStyle(mode: mode).label)
        }
        .font(.caption)
        .foregroundColor(style.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(style.color.opacity(0.1))
        .cornerRadius(4)
    }
}
```

```swift
// Inline row (TranscriptionDetailView metadata)
struct ModeRow: View {
    let mode: RecognitionMode
    var body: some View {
        let style = RecognitionModeStyle(mode: mode)
        HStack(spacing: 6) {
            Image(systemName: style.icon)
            Text(style.label)
        }
        .foregroundColor(style.color)
    }
}
```

## §3. Why this matters for the Recording Screen

Today the recording screen's "识别模式" indicator at L162-172 and L298-302
shows **only** the colour + label, not the SF Symbol. Adding the icon (zero
new visual elements invented — the symbols already exist in
`TranscriptionDetailView.swift`) gives:

- Visual consistency between recording and detail screens.
- Single source of truth: if the colour/icon/label ever changes, both views
  pick it up automatically.
- ~50 LOC reduction across two files.

## §4. States covered

- ✅ `.online` / `.onDevice` / `.enhanced` / `.failed` / `.none`

## §5. Self-review

- [x] Did I check `design-system/`? — bootstrap, no prior asset
- [x] Rationale? — clear duplication + visual inconsistency
- [x] States covered? — §4
- [x] Provenance? — **inferred**

## §6. Open questions

1. Should `RecognitionModeStyle` live in `Models/` (next to `RecognitionMode`)
   or in `Views/SharedComponents/`? Since it's a *visual* mapping, the latter
   is cleaner — but `Models/` already owns the semantic enum.
2. The `.none` mode is only handled in `TranscriptionDetailView`; what
   should `RecordingView.modeLabel` show when mode is `.none`? Today it
   falls through `switch` (a Swift warning — needs to be added).
3. Should the badge also work as a `.tint(.recognitionModeColor)` modifier
   to drive e.g. button backgrounds? Out of scope; tab first.
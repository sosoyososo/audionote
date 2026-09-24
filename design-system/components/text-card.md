# TextCard

> **Status: inferred → confirmed in practice** — applied as
> `View.textCard(radius:)` modifier in `ios/AudioNote/Views/SharedComponents.swift:74-91`,
> and consumed by all 7 sites in `ios/AudioNote/Views/RecordingView.swift`
> (lines 344/357/377/388/398/425/436) — each previously a
> `.background(Color(.systemGray6)).cornerRadius(12)` pair (2026-09-24).

## §1. Problem

The "gray6 background + 12 radius + padded content" container is repeated
6+ times inside `RecordingView.swift` alone:

| File:Line | Variant |
|---|---|
| `RecordingView.swift:352-353` | loading (LLM) |
| `RecordingView.swift:366-367` | failed (LLM) |
| `RecordingView.swift:387-388` | live partial text |
| `RecordingView.swift:399-400` | "Speak now" placeholder |
| `RecordingView.swift:410-411` | editing text editor |
| `RecordingView.swift:438-439` | final result text |
| `RecordingView.swift:450-451` | empty result |
| `TranscriptionDetailView.swift:158-159` | detail edit mode (radius 8, smaller) |

Each copy is a `VStack` / `ScrollView` / `TextEditor` wrapped in:

```swift
.background(Color(.systemGray6))
.cornerRadius(12)
```

## §2. Implementation (applied)

```swift
extension View {
    func textCard(radius: CGFloat = 12) -> some View {
        self
            .background(Color(.systemGray6))
            .cornerRadius(radius)
    }
}
```

The frame (`minHeight: 120, maxHeight: 250`) is left at the caller — it
varies per container (live text card vs. loading/failed card vs. result
card share the same parent frame; the recording button section does not
need a frame at all). Extracting frame into the modifier would couple
unrelated layout decisions to the visual style.

## §3. States covered

| State | Current handling |
|---|---|
| idle | uses TextCard (empty-result variant) |
| loading | TextCard with `ProgressView` |
| error | TextCard with orange icon |
| recording | TextCard with live partial |
| editing | TextCard with `TextEditor` |
| result | TextCard with final text |
| disabled | n/a (text card always shown) |

## §4. Self-review

- [x] Did I check `design-system/`? — bootstrap, no prior asset
- [x] Rationale? — eliminates 6+ duplicates in `RecordingView`
- [x] States covered? — §3
- [x] Provenance? — **inferred**

## §5. Why this matters for the Recording Screen

Today the recording screen's text-section uses an *inline* `Group { if … }
else if … }` chain (lines 333-372) with five different code paths each
re-implementing the card pattern. Extracting `TextCard` would:

1. Remove ~30 lines of duplication.
2. Make adding new states (e.g. transcription-not-supported, retry-success)
   a one-line change.
3. Keep visual consistency locked to the dominant radius/background.

## §6. Open questions

1. Should `TextCard` be a generic container or a `ViewModifier`? Modifier is
   lighter weight but cannot carry state.
2. Should `TextCard` own the optional "header strip" (status + actions row)
   seen above each card in `RecordingView.swift:237-331`? That's a different
   pattern (`StatusHeaderStrip`) — keep them separate.
3. The Detail-page edit card uses `cornerRadius(8)` — should `TextCard`
   expose a `radius:` parameter, or have a separate `TextCardCompact`?
# Pattern: Recording Screen

> **Status: inferred** — extracted from `ios/AudioNote/Views/RecordingView.swift`.

## §1. Anatomy (top to bottom)

```
NavigationView
└── ZStack
    ├── VStack(spacing: 0)
    │   ├── headerSection        ← language picker row + label
    │   ├── Spacer()
    │   ├── recordingControlSection  ← duration / pulse / main button / status
    │   ├── Spacer()
    │   └── textSection          ← status strip + content card
    ├── (overlay) permissionOverlay       ← shown only when denied/restricted
    └── (overlay) toastOverlay            ← top-aligned
    .sheet (modal)
    .alert (modal)
```

The screen is composed of exactly **three sections** separated by `Spacer()`
to keep the recording button visually centred. This is a deliberate vertical
rhythm — see `tokens/spacing-and-shape.md §2`.

## §2. Header section (`RecordingView.swift:99-114`)

```swift
VStack(alignment: .leading, spacing: 12) {
    Text("Language.Selection".localized)
        .font(.caption).foregroundColor(.secondary)
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            ForEach(RecognitionLanguage.sortedCases) { lang in
                languageTag(for: lang)
            }
        }
    }
}
.frame(maxWidth: .infinity, alignment: .leading)
```

- Label + horizontal scroll of capsule chips.
- Disabled + dimmed while recording.

## §3. Recording control section (`RecordingView.swift:145-231`)

```swift
VStack(spacing: 20) {
    if isRecording { durationLabel() }                // optional
    if isRecording { modeIndicator() }                // optional
    recordingButton()                                  // always
    if !isRecording && text.isEmpty { tapToStart() }  // optional
    if denied/restricted { permissionHint() }         // optional
}
```

The button is a **concentric circle stack**:

| Layer | Size | Treatment | Why |
|---|---|---|---|
| outer ring | `100 × 100` | `Circle().stroke(... lineWidth: 4)` | idle: accent 0.3 opacity; active: red 1.0 |
| pulse halo | `100 × 100` | `Circle().fill(red 0.1)` + `PulsingModifier` | active only |
| inner solid | `80 × 80` | `Circle().fill(...)` + shadow (radius 10, y 4, 0.4 opacity) | tappable target; matches ring colour |
| icon | `32 pt` | `mic.fill` / `stop.fill`, white | centre label

## §4. Text section (`RecordingView.swift:235-454`)

```swift
VStack(spacing: 12) {
    headerStrip           // status / mode / actions row
    contentCard           // one of { recording / editing / loading / failed / result / empty }
}
.contentCard.frame(minHeight: 120, maxHeight: 250)
```

The header strip has **five** exclusive `if`/else branches (lines 239-330)
each with a different layout — see `MASTER.md §5` and
`components/text-card.md §1`.

## §5. States the screen must render correctly

| State | Visible elements |
|---|---|
| pre-permission | header + button (idle) + tap-to-start |
| permission denied | permission overlay covers everything |
| permission granted (no recording) | full layout + tap-to-start |
| recording active | duration + pulse + red button + live-text card |
| recording stopped (LLM processing) | loading card |
| recording stopped (LLM failed) | failed card with retry |
| recording stopped (text ready) | result card with copy / share / edit |
| editing text | editor card with cancel / save |
| toast | top overlay |

## §6. Pain points / smells (status after 2026-09-24 pass)

1. ~~`modeColor` / `modeLabel` duplicate `recognitionModeColor/Label`~~ —
   **resolved** via `RecognitionModeStyle` + `ModeBadge` (see
   `components/recognition-mode-badge.md`).
2. ~~Inline `toastOverlay`~~ — **resolved** by reusing `ToastView` +
   `RecordActionsViewModel` (see `components/toast-view.md`).
3. **`Group { if … else if … }` chain for the text card** with 5+
   near-duplicate layout branches — see `components/text-card.md` —
   *not yet extracted, candidate for follow-up*.
4. ~~No `.none` case in `modeColor` / `modeLabel`~~ — **resolved**; the
   inline switch is gone; `RecognitionModeStyle` now has exhaustive
   non-optional switch (matches `RecognitionMode`'s actual cases).
5. `saveEditedText` reconstructs `TranscriptionRecord` but did not preserve
   `audioFileName`, `optimizedContent`, `archived`, `archivedAt`, `tags`,
   `summary`, `title` — drops LLM fields silently. Fixed in commit
   `531ef68` (out of scope here).
6. ~~Header strip's inline `modeLabel` pill~~ — **resolved** by `ModeBadge`.

### Net change

`RecordingView.swift`: **619 → 563 lines (-56 lines, -9 %)**.
`SharedComponents.swift`: **121 → 182 lines (+61 lines)** — the new
`RecognitionModeStyle` + `ModeBadge` extraction (+ inline documentation
pointing at `design-system/components/recognition-mode-badge.md`).

## §7. Self-review

- [x] Did I check `design-system/`? — bootstrap
- [x] Rationale? — code extraction
- [x] States covered? — §5
- [x] Provenance? — **inferred**

## §8. Audit checklist (used in §5 of the user's task)

1. Token consistency — see `tokens/`.
3. State coverage (see §5).
4. Duplications (see §6).
6. The above produces the optimisation recommendations.
# AudioNote Design System — MASTER

> Initialised by extracting visual conventions from `ios/AudioNote/Views/` and `Models/` (2026-09-24).
> Every asset below is marked **`inferred`** unless explicitly approved — see §0.

## §0. Provenance

This Design System was **inferred** by static analysis of the existing codebase.
Nothing here has been confirmed by the user yet. Until each asset is reviewed
and approved, treat it as a working assumption that may be revised.

Self-review checklist (per asset, see `~/.claude/design-system-engine.md` §6):

- [x] Did I check `design-system/` for existing? (Reuse First) — n/a, bootstrapping
- [x] What's the rationale? — extracted from existing code, no new rules invented
- [x] What states does it cover? — explicit per asset
- [x] Inferred vs Confirmed? — **inferred** for all (waiting for user review)

## §1. Inventory of source-of-truth files

| Concern | File |
|---|---|
| Tab bar / root navigation | `ios/AudioNote/Views/ContentView.swift` |
| Recording screen (the focus of this bootstrap) | `ios/AudioNote/Views/RecordingView.swift` |
| Library list / row | `ios/AudioNote/Views/LibraryListView.swift` |
| Detail (read / edit / LLM re-process) | `ios/AudioNote/Views/TranscriptionDetailView.swift` |
| Provider profiles (settings) | `ios/AudioNote/Views/SettingsView.swift`, `ProfileDetailView.swift` |
| Reusable: toast, share sheet, playback bar | `ios/AudioNote/Views/SharedComponents.swift` |
| Recognition-mode semantics (colour / icon / label) | duplicated: `RecordingView.swift:567-583` AND `TranscriptionDetailView.swift:254-282` |
| Language icon mapping | `ios/AudioNote/Models/RecognitionLanguage.swift` |

## §2. Token summary

| Token group | File | Status |
|---|---|---|
| Colour (semantic + recognition-mode mapping) | `tokens/colors.md` | inferred |
| Typography (iOS system font scale) | `tokens/typography.md` | inferred |
| Spacing / radii / sizing | `tokens/spacing-and-shape.md` | inferred |
| Iconography (SF Symbols) | `tokens/icons.md` | inferred |
| Motion (durations, easing) | `tokens/motion.md` | inferred |

## §3. Component inventory

| Component | Current source | Status |
|---|---|---|
| `TextCard` (gray6 bg + radius 12, padded text container) | `RecordingView.swift:352/366/387/410/438/450`, `TranscriptionDetailView.swift:158` | inferred — **candidate for extraction**, see `components/text-card.md` |
| `EmptyStateView` (large SF Symbol + headline + sub) | `LibraryListView.swift:178-191/194-209/430-437` | inferred — candidate for extraction |
| `StatusHeaderStrip` (mode label + caption + trailing actions) | `RecordingView.swift:237-331` | inferred — internal to RecordingView |
| `RecognitionModeBadge` (color + label + opacity bg) | `RecordingView.swift:298-302`, plus icon helpers in `TranscriptionDetailView.swift:254-282` | inferred — **duplicated**, see `components/recognition-mode-badge.md` |
| `ToastView` | `SharedComponents.swift:17-45` | confirmed (already used by Library + Detail) — but `RecordingView` re-implements it inline at `:458-477` (smell) |
| `ShareSheet` | `SharedComponents.swift:5-13` | confirmed |
| `PlaybackControlBar` | `SharedComponents.swift:76-120` | confirmed |
| `PulsingModifier` (recording pulse animation) | `RecordingView.swift:588-613` | inferred — single use |
| `TagFlowView` | `TranscriptionDetailView.swift:448-479` | inferred |
| `LanguageChipButton` | `RecordingView.swift:116-141` | inferred — language-tag chip with capsule bg |

## §5. Reuse First verdict

- The codebase already follows Reuse First reasonably well for toast / share-sheet / playback.
- Two **clear duplications** that this Design System flags:
  1. **Recognition-mode visuals** — `RecordingView.modeColor/Label` vs `TranscriptionDetailView.recognitionModeColor/Icon/Label`. **A `RecognitionModeStyle` is the natural extraction.**
  2. **Gray6 text-card pattern** — repeated 6+ times in RecordingView alone. **A `TextCardStyle` view modifier is the natural extraction.**

## §6. Controlled Evolution stance

Any future asset additions follow the engine's §6:

1. invoke `ui-ux-pro-max` only for visual generation of *missing* assets
2. document intent inline
3. mark provenance (`inferred` vs `confirmed`)
4. enumerate states
5. persist under `design-system/`
6. update this MASTER

## §7. Project Isolation

This Design System is AudioNote-specific. Do not share assets with other
projects (e.g. voicenote). If a later cross-project need arises, copy and
adapt manually — see engine §3.

## §8. Open questions for the user

These are the points where the inferred asset disagrees with what *might* be
the cleaner ground truth. Each one is a candidate for a `confirmed` decision
after discussion.

1. Should `Color(.systemGray6)` become a semantic token `tokens/colors.md §CardBackground`, or stay as raw SwiftUI platform colour?
2. Should `cornerRadius(12)` become a token `tokens/spacing-and-shape.md §CardRadius`, given it's the dominant radius (9 uses)?
3. Should the duplicated recognition-mode visuals be extracted into `RecognitionModeStyle` now, or left as-is?
4. Should the recording page's inline toast (`RecordingView.swift:458-477`) be replaced by the existing `ToastView`?
5. The recording screen has multiple text-card sub-states (idle / recording / editing / loading / failed / result) — should we extract a single `RecordingTextCard` that switches by state?

See `decisions/` for any confirmed answers.
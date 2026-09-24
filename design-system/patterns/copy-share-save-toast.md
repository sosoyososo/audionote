# Pattern: Copy / Share / Save toast

> **Status: inferred → confirmed in practice** — three-screen consolidation
> landed in commit `feat/design-system-and-recording-screen` (2026-09-24).

## §1. Canonical pattern today

All three record-bearing screens now use the same toast coordinator:

```swift
@StateObject private var actionsViewModel = RecordActionsViewModel()
// …
.overlay(alignment: .top) {
    ToastView(
        message: actionsViewModel.toastMessage,
        isShowing: $actionsViewModel.showCopiedToast
    )
}
.sheet(isPresented: $actionsViewModel.showShareSheet) { ShareSheet(items: …) }
```

Consumers (as of 2026-09-24):

| Screen | File:Line |
|---|---|
| Recording | `ios/AudioNote/Views/RecordingView.swift:6, :44-49, :52` |
| Library | `ios/AudioNote/Views/LibraryListView.swift:10, :46` |
| Detail | `ios/AudioNote/Views/TranscriptionDetailView.swift:7, :79, :93, :97` |

Trigger API on `RecordActionsViewModel` (in `SharedComponents.swift:50-72`):

```swift
func copyText(_ text: String)              // sets toastMessage = "Toast.Copied", shows
func showSaveConfirmation()                 // sets toastMessage = "Toast.Saved", shows
```

Auto-hide lives inside `ToastView` (`SharedComponents.swift:17-45`) — 1.5 s,
slide-in transition `.move(edge: .top).combined(with: .opacity)`.

## §2. Pre-consolidation history (was 3 → now 1)

This pattern started as **three independent coordinators**:
- A — `RecordingView` inline `@State` flags + manual `asyncAfter` (no animation)
- B — `RecordActionsViewModel` in `SharedComponents` (the canonical one)
- C — `SettingsViewModel` with two `@Published` flags + manual binding

Recording was the last holdout of A. The Recording refactor in this commit
moved it to B, collapsing A.

## §3. SettingsView (the remaining outlier)

`SettingsView.swift` still uses the C pattern (two `@Published` flags with
manual binding construction in `SettingsViewModel`). It is intentionally
left alone because:

- Its two toasts are **different** from copy/save (provider-test result,
  migration notice), so they can't share `RecordActionsViewModel.toastMessage`.
- Consolidating would require either:
  - Generalising `RecordActionsViewModel` into a "toast of arbitrary string"
    pattern (loses typing)
  - Or introducing a global `ToastCenter` singleton (risky — concurrent
    toasts collide across screens)

Both options are bigger than the win. See §5 for a possible future
extraction.

## §4. Self-review

- [x] Did I check `design-system/`? — bootstrap
- [x] Rationale? — three duplicates + inconsistent timing/animation
- [x] States covered? — shown / hidden / auto-hide
- [x] Provenance? — **inferred → confirmed in practice** (Recording moved to
       `RecordActionsViewModel` in commit `feat/design-system-and-recording-screen`)

## §5. Open questions

1. Should `SettingsView`'s toast fields be lifted into a generic
   `ToastCenter` so all four screens use one pattern? Deferred — current
   working set has zero divergence in user-visible behaviour; cost of
   extraction > benefit until a fifth toast type appears.
2. `RecordActionsViewModel.showSaveSuccess` is a published flag that's
   never read (only `showCopiedToast` is bound to `ToastView`). Dead
   state — candidate for deletion in a future cleanup.
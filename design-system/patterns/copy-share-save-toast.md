# Pattern: Copy / Share / Save toast

> **Status: inferred** — extracted from current `RecordingView`,
> `LibraryListView`, `TranscriptionDetailView`, `SettingsView`.

## §1. Where it appears

| Action | File:Line | Mechanism |
|---|---|---|
| Copy text | `RecordingView.swift:555-559` | inline `showCopiedToast = true; autoHideToast()` |
| Copy text | `LibraryListView.swift:308` (via `RecordActionsViewModel`) | `actionsViewModel.copyText(record.content)` |
| Copy text | `TranscriptionDetailView.swift:73` (via `RecordActionsViewModel`) | `actionsViewModel.copyText(currentRecord.content)` |
| Save edit | `TranscriptionDetailView.swift:429` (via `RecordActionsViewModel`) | `actionsViewModel.showSaveConfirmation()` |
| Save edit (recording) | `RecordingView.swift:546` | inline `showCopiedToast = true` (re-uses copy toast!) |
| Provider profile test | `SettingsView.swift:75-92` | inline `viewModel.migrationToast` / `viewModel.pingResult` |
| Toast content migration | `SettingsView.swift:75` | inline `viewModel.migrationToast` |

## §2. Three independent "toast coordinators"

The codebase has **three** separate toast-management strategies today:

### A — `RecordingView` ad-hoc

```swift
@State private var showCopiedToast = false
@State private var toastMessage = ""  // unused; hard-coded "Toast.Copied"
private func copyText() {
    UIPasteboard.general.string = viewModel.transcribedText
    showCopiedToast = true
    autoHideToast()
}
private func autoHideToast() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        showCopiedToast = false
    }
}
```

Auto-hide is `1.5 s` and direct toggle — no `withAnimation`, no slide-in
transition animation.

### B — `RecordActionsViewModel` (SharedComponents)

```swift
@MainActor
public final class RecordActionsViewModel: ObservableObject {
    @Published public var showShareSheet = false
    @Published public var showCopiedToast = false
    @Published public var showSaveSuccess = false
    @Published public var toastMessage = ""

    public func copyText(_ text: String) {
        UIPasteboard.general.string = text
        toastMessage = "Toast.Copied".localized
        withAnimation { showCopiedToast = true }
    }
    public func showSaveConfirmation() {
        toastMessage = "Toast.Saved".localized
        withAnimation { showSaveSuccess = true }
    }
}
```

But `RecordActionsViewModel` triggers the flag but does **not** auto-hide it
— the auto-hide is inside `ToastView` itself (good — DRY for the auto-hide).

### C — `SettingsViewModel`

Two separate `@Published` flags for two different toasts, with manual binding
construction:

```swift
ToastView(message: toast, isShowing: Binding(
    get: { viewModel.migrationToast != nil },
    set: { newValue in if !newValue { viewModel.migrationToast = nil } }
))
```

This is the most verbose of the three.

## §3. Proposed canonical pattern

```swift
// Single coordinator per screen (or shared if no other concerns).
final class ToastCoordinator: ObservableObject {
    @Published var message: String?
    @Published var isShowing = false

    func show(_ message: String) {
        self.message = message
        withAnimation { isShowing = true }
    }

    func dismiss() {
        withAnimation { isShowing = false }
    }
}
```

Then every screen renders the same overlay:

```swift
.overlay(alignment: .top) {
    if let message = toastCoordinator.message {
        ToastView(message: message, isShowing: $toastCoordinator.isShowing)
            .padding(.top, 60)
    }
}
```

`ToastView` already auto-hides after 1.5 s — so the coordinator only has to
*trigger* `isShowing = true`, not manage its lifecycle.

## §4. Self-review

- [x] Did I check `design-system/`? — bootstrap
- [x] Rationale? — three duplicates + inconsistent timing/animation
- [x] States covered? — shown / hidden / auto-hide
- [x] Provenance? — **inferred**

## §5. Why this matters for the Recording Screen

`RecordingView` is the only screen that does not use `RecordActionsViewModel`
or `ToastView`. Switching it over:

- Removes ~25 lines of inline toast logic (`showCopiedToast`, `toastMessage`,
  `autoHideToast`, the inline `toastOverlay`).
- Replaces its hard-coded `showCopiedToast` flag with a single
  `coordinator.show("Toast.Copied".localized)` call.
- Aligns auto-hide timing (1.5 s) and animation (`.move(.top) + .opacity`)
  with the rest of the app — currently the recording page's hide transition
  is missing.

## §6. Open questions

1. Should we introduce `ToastCoordinator` (one per screen) or a global
   `ToastCenter` (one for the whole app)? Global is risky (concurrent
   toasts collide). Per-screen is conservative and matches existing
   per-screen VMs (`RecordActionsViewModel`, `SettingsViewModel`'s toast
   fields).
2. Should `Toast.Copied` and `Toast.Saved` strings live in the
   `Localizable.strings` table today? Yes (see `i18n/`).
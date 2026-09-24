# ToastView

> **Status: inferred → confirmed in practice** — applied in
> `ios/AudioNote/Views/RecordingView.swift:44-49` (now reuses `ToastView`
> with `RecordActionsViewModel` coordinator). `RecordingView`'s inline
> `toastOverlay` + `showCopiedToast`/`autoHideToast` are gone (2026-09-24).

The codebase has a working `ToastView` at `SharedComponents.swift:17-45`.
It is already reused in `LibraryListView.swift:46` and
`TranscriptionDetailView.swift:97` and `SettingsView.swift:76/83`.

## §1. Current shape

```swift
struct ToastView: View {
    let message: String
    @Binding var isShowing: Bool

    var body: some View {
        if isShowing {
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.8))
                .cornerRadius(20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { isShowing = false }
                    }
                }
        }
    }
}
```

Auto-hide after 1.5 s; show/hide transition `.move(edge: .top) + .opacity`.

## §2. The duplication smell — `RecordingView`

`RecordingView.swift:458-477` re-implements an **inline** toast overlay instead
of using `ToastView`:

```swift
private var toastOverlay: some View {
    VStack {
        if showCopiedToast {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                Text("Toast.Copied".localized)
            }
            .font(.subheadline.weight(.medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.8))
            .cornerRadius(20)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        Spacer()
    }
    .padding(.top, 60)
    .animation(.easeInOut(duration: 0.2), value: showCopiedToast)
}
```

Differences from `ToastView`:

- Has a leading `Image(systemName: "checkmark.circle.fill")` — ToastView has none.
- Font: `.subheadline` (vs ToastView's `.caption`).
- Auto-hide is driven by `autoHideToast()` (RecordingView:561-565) — uses
  `DispatchQueue.main.asyncAfter(deadline: .now() + 1.5)` then sets
  `showCopiedToast = false` directly (no animation).
- `.animation(.easeInOut(duration: 0.2), value: showCopiedToast)` — ToastView
  uses `withAnimation` inside its `onAppear`.

## §3. Proposed action

Reuse `ToastView` in `RecordingView` — see `patterns/copy-share-save-toast.md`.

If the leading checkmark icon is desired, push that into `ToastView` as an
optional `systemImage: String?` parameter (default `nil`) — preserves all
current consumers.

## §4. States covered

- ✅ shown (with `isShowing: true`)
- ✅ hidden (with `isShowing: false`; the view returns `EmptyView`)
- ✅ auto-hide transition

## §5. Self-review

- [x] Did I check `design-system/`? — bootstrap
- [x] Rationale? — existing component
- [x] States covered? — §4
- [x] Provenance? — **inferred** for the design-system document itself; the
       component is already in code (treated as "confirmed in practice"
       but not formally approved)

## §6. Open questions

1. Confirm that promoting `ToastView` to a *formal* component (this doc) is
   desired, vs leaving it as a private helper.
2. Should the leading-icon variant be added (covers RecordingView case), or
   should RecordingView drop the icon to match ToastView?
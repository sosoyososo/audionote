# EmptyState (candidate)

> **Status: inferred** — extraction candidate, **not** yet refactored in code.

## §1. Problem

Three copies of "icon + headline + sub-headline, vertically centered" exist:

### A — `LibraryListView.swift:178-191`

```swift
VStack(spacing: 16) {
    Image(systemName: "list.bullet.clipboard")
        .font(.system(size: 60))
        .foregroundColor(.secondary)
    Text("History.Empty".localized)
        .font(.headline)
        .foregroundColor(.secondary)
    Text("History.Empty.Hint".localized)
        .font(.subheadline)
        .foregroundColor(.secondary)
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
```

### B — `LibraryListView.swift:194-209` (no-results)

```swift
VStack(spacing: 16) {
    Image(systemName: "magnifyingglass")
        .font(.system(size: 60))
        .foregroundColor(.secondary)
    Text("Library.NoResults".localized)
        .font(.headline)
        .foregroundColor(.secondary)
    Button("Library.ClearFilters".localized) { … }
        .buttonStyle(.bordered)
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
```

### C — `LibraryListView.swift:430-437` (archived no-results)

```swift
VStack(spacing: 16) {
    Image(systemName: "archivebox")
        .font(.system(size: 60))
        .foregroundColor(.secondary)
    Text("Library.NoResults".localized)
        .font(.headline)
        .foregroundColor(.secondary)
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
```

`RecordingView.swift:441-451` is a fourth (smaller) variant of the same
pattern but constrained to the text-card frame.

## §2. Proposed extraction

```swift
struct EmptyState: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let actionTitle: LocalizedStringKey?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

## §3. States covered

- ✅ empty (icon + title)
- ✅ empty + hint (icon + title + subtitle)
- ✅ empty + action (icon + title + button)
- ✅ full (icon + title + subtitle + button)

## §4. Self-review

- [x] Did I check `design-system/`? — bootstrap
- [x] Rationale? — eliminates 3–4 duplicates
- [x] States covered? — §3
- [x] Provenance? — **inferred**

## §5. Open questions

1. Should this be a generic `EmptyState` (above) or a *typeless* SwiftUI
   container that callers fill (closer to Apple's stock design)? Generic
   forces `LocalizedStringKey` everywhere; non-generic is more flexible.
2. The recording-screen empty-result variant is inside a `TextCard` frame
   (`minHeight 120, maxHeight 250`) — should it still use `EmptyState`? In
   that case the `.frame(maxHeight: .infinity)` would have to be conditional.
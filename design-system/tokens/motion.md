# Motion Tokens

> **Status: inferred** — extracted from `ios/AudioNote/Views/`, 2026-09-24.

## §1. Durations observed

| Duration | Use | File |
|---|---|---|
| `1.0 s` `repeatForever(autoreverses: true)` `easeInOut` | pulse halo animation while recording | `RecordingView.swift:594-598` |
| `1.5 s` `asyncAfter` | toast auto-hide | `SharedComponents.swift:37`, `RecordingView.swift:561` |
| `0.2 s` `easeInOut` | toast show/hide animation | `RecordingView.swift:476` |

## §2. Easing

| Easing | Use |
|---|---|
| `easeInOut(duration:)` | toast show/hide; pulse halo |
| `withAnimation { … }` (default) | toast trigger (`SharedComponents.swift:38`), share-sheet save (`SharedComponents.swift:62/68`) |

## §3. Transitions

| Transition | Use | File |
|---|---|---|
| `.move(edge: .top).combined(with: .opacity)` | toast | `SharedComponents.swift:35`, `RecordingView.swift:471` |
| `.move(edge: .bottom).combined(with: .opacity)` | settings toast | `SettingsView.swift:81/91` |

## §4. Search debounce

| Value | Use | File |
|---|---|---|
| `150 ms` | search-input debounce (only `LibraryListView`) | `LibraryListView.swift:292` |

## §5. States covered

- ✅ recording pulse
- ✅ toast lifecycle
- ✅ show/hide sheet-style toasts

## §6. Self-review

- [x] Did I check `design-system/` for existing? — bootstrap
- [x] Rationale? — code extraction
- [x] States covered? — §5
- [x] Provenance? — **inferred**

## §7. Open questions

1. Should the toast auto-hide `1.5 s` and the toast transition `0.2 s` become tokens?
2. The `150 ms` search debounce is purely a List concern — keep inline or extract?
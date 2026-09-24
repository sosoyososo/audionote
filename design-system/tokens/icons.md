# Iconography Tokens (SF Symbols)

> **Status: inferred** — extracted from `ios/AudioNote/Views/`, 2026-09-24.
> The app uses SF Symbols exclusively. No custom icon assets.

## §1. Tab bar (root navigation)

| SF Symbol | Localisation key | File |
|---|---|---|
| `mic.fill` | `Tab.Recording` | `ContentView.swift:13` |
| `list.bullet` | `Tab.Library` | `ContentView.swift:18` |
| `gear` | `Tab.Settings` | `ContentView.swift:23` |

## §2. Recording screen

| SF Symbol | Use | File |
|---|---|---|
| `mic.fill` | recording button (idle) | `RecordingView.swift:208` |
| `stop.fill` | recording button (active) | `RecordingView.swift:208` |
| `mic.slash.circle` | permission overlay (size 60) | `RecordingView.swift:485` |
| `globe` | language picker nav-bar | `RecordingView.swift:90` |
| `text.badge.xmark` | empty-result card | `RecordingView.swift:442` |
| `doc.on.doc` | copy text button | `RecordingView.swift:310` |
| `square.and.arrow.up` | share text button | `RecordingView.swift:317` |
| `pencil` | enter editing button | `RecordingView.swift:324` |
| `checkmark.seal.fill` | "优化后" optimised seal | `RecordingView.swift:422` |
| `exclamationmark.triangle` | LLM-failed inline icon | `RecordingView.swift:275/357` |
| `checkmark.circle.fill` | toast success indicator | `RecordingView.swift:462` |
| `character.cursor.ibeam` | language chip (zh-CN) | `RecognitionLanguage.swift:18` |
| `abc` | language chip (en-US) | `RecognitionLanguage.swift:19` |

## §3. Library / list

| SF Symbol | Use | File |
|---|---|---|
| `magnifyingglass` | search bar leading / no-results | `LibraryListView.swift:61/196` |
| `xmark.circle.fill` | search-clear button | `LibraryListView.swift:76` |
| `list.bullet.clipboard` | empty-state icon (size 60) | `LibraryListView.swift:179` |
| `archivebox` | archived-banner leading | `LibraryListView.swift:148/431` |
| `chevron.right` | archived-banner trailing | `LibraryListView.swift:152` |
| `eye` | context menu "View" | `LibraryListView.swift:304` |
| `trash` | context menu / swipe delete | `LibraryListView.swift:232/319` |

## §4. Detail

| SF Symbol | Use | File |
|---|---|---|
| `calendar` | metadata row | `TranscriptionDetailView.swift:105` |
| `clock` | metadata row | `TranscriptionDetailView.swift:112` |
| `timer` | metadata row | `TranscriptionDetailView.swift:120` |
| `cloud.fill` | recognition-mode `.online` | `TranscriptionDetailView.swift:256` |
| `iphone.gen1` | recognition-mode `.onDevice` | `TranscriptionDetailView.swift:257` |
| `cloud.fill.badge.checkmark` | recognition-mode `.enhanced` | `TranscriptionDetailView.swift:258` |
| `xmark.shield.fill` | recognition-mode `.failed` | `TranscriptionDetailView.swift:259` |
| `questionmark.circle` | recognition-mode `.none` | `TranscriptionDetailView.swift:260` |
| `arrow.up.doc` | "在线升级识别" button | `TranscriptionDetailView.swift:299` |
| `archivebox` / `archivebox.fill` | archive / unarchive button | `TranscriptionDetailView.swift:324` |
| `arrow.clockwise` | re-process LLM (status `.completed`) | `TranscriptionDetailView.swift:238` |
| `sparkles` | re-process LLM (default) | `TranscriptionDetailView.swift:240` |

## §5. Settings / Provider

| SF Symbol | Use | File |
|---|---|---|
| `plus.circle.fill` | add new provider profile | `SettingsView.swift:31` |
| `circle` | inactive provider row | `SettingsView.swift:113` |
| `checkmark.circle.fill` | active provider row | `SettingsView.swift:113` |
| `checkmark.circle.fill` | provider-test success | `ProfileDetailView.swift:118` |
| `xmark.circle.fill` | provider-test failure | `ProfileDetailView.swift:122` |
| `exclamationmark.triangle.fill` | provider detail warning | `ProfileDetailView.swift:130` |

## §6. Pattern: "duplicate-recognised-but-missing-from-recording"

Recognition-mode icons exist only in `TranscriptionDetailView.swift`. The
`RecordingView.swift` shows the mode label + colour but no icon. This is
inconsistent — see `components/recognition-mode-badge.md`.

## §7. States covered

- ✅ All current visual states have a matching symbol
- ✅ Dark mode works (template rendering)
- ❓ No `decrease/increase` symbols anywhere — UI never exposes sliders except playback

## §8. Self-review

- [x] Did I check `design-system/` for existing? — bootstrap
- [x] Rationale? — code extraction
- [x] States covered? — §7
- [x] Provenance? — **inferred**

## §9. Open questions

1. SF Symbols in dark mode are template-coloured; no need for explicit variants.
2. Promote recognition-mode icons into a single `RecognitionModeStyle` extraction so RecordingView also shows an icon?
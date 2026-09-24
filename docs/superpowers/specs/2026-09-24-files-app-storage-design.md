# Files App Storage — Design Spec

**Date**: 2026-09-24
**Status**: Backlog spec — locked decision, no implementation yet
**Author**: brainstorming session

## Why

Current storage writes `transcriptions.json` + `Recordings/{UUID}.m4a` to
the iOS sandbox `Documents/` directory. When the user uninstalls the
app, both are wiped. There is no user-visible way to inspect, back up,
or move recordings outside the app.

The goal is to let users **store their recordings in the Files app**
(On My iPhone), so that:
- The folder is visible in iOS Files and Finder (macOS Catalina+).
- Recordings survive an uninstall of the app.
- Users can manually back up, sync via iTunes/Finder, or move the
  folder to another location.

## Locked Decisions

These are decisions made during brainstorming on 2026-09-24 and are
**locked** — do not re-litigate without an explicit new ask.

| # | Decision | Rationale |
|---|---|---|
| 1 | **Storage location**: `On My iPhone > AudioNote/` (within the iOS Files app) | User explicitly chose "On My iPhone 本地文件夹" over iCloud Drive or arbitrary picker location. No iCloud entitlement needed. |
| 2 | **Folder name**: `AudioNote` (fixed) | Single canonical name; APP auto-uses if exists, creates on first picker. |
| 3 | **Folder structure**: `AudioNote/transcriptions.json` + `AudioNote/Recordings/{UUID}.m4a` (matches current sandbox layout, just moved) | Minimal blast radius; JSON loader stays unchanged. |
| 4 | **Bookmark strategy**: One `security-scoped bookmark` for the root folder, stored in `UserDefaults`. Per-file bookmarks are out of scope. | Simplest viable. File-level resilience to external moves is not required for v1. |
| 5 | **First-launch UX**: APP shows a one-time `OnboardingView` with a "选择存储位置" button → `UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)`. User can pick an existing folder or create a new one named `AudioNote`. | Required by iOS — APP cannot programmatically create folders under "On My iPhone" without going through the picker first. |
| 6 | **Subsequent launches**: Read the bookmark from `UserDefaults`, resolve the URL, `startAccessingSecurityScopedResource()` for the session, no UI prompt. | Smooth UX after onboarding. |
| 7 | **Settings override**: Add a "更换存储位置" button in `SettingsView` that re-triggers the picker and replaces the stored bookmark. | Lets users move to a different folder later without reinstalling. |
| 8 | **Migration of existing data**: **Not required.** Development phase; users accept that old sandbox data will be lost. No import flow, no dual-write period. | Explicit user confirmation on 2026-09-24. |
| 9 | **iCloud sync**: **Not in scope.** No iCloud entitlement, no `ubiquityContainer` use, no cross-device sync. | User chose On My iPhone only. |
| 10 | **Custom Files app icon for the folder (like 多看 / 1Password)**: **Not in scope.** Would require registering a `FileProvider` extension or custom UTI — separate product effort. | Explicitly deferred. |

## Behavior summary

- **First launch**: OnboardingView → user picks/creates `AudioNote` folder → bookmark saved.
- **Recording**: `AudioRecorderService` writes `.m4a` into the user's `AudioNote/Recordings/` folder.
- **Saving a record**: `TranscriptionStorage` writes `transcriptions.json` into the user's `AudioNote/` folder.
- **Playback**: `AudioPlayerManager` resolves `audioFileName` → URL under the user's folder → `AVAudioPlayer`.
- **Deleting a record**: also delete the matching `.m4a` (closes the existing orphan-file gap noted in `TranscriptionStorage`).
- **Bookmark lost / folder removed externally**: detect on next launch, return to OnboardingView.
- **App backgrounded**: stop accessing the security-scoped resource; resume on foreground (standard iOS pattern).

## Out of scope (explicit non-goals)

- iCloud Drive or any cloud sync.
- Custom Files-app icons / FileProvider extensions.
- Migration of existing sandbox data.
- Per-file bookmarks (so files renamed externally may become "lost"; UI should surface this gracefully).
- Export/import UI in Settings (JSON export, etc.) — separate feature if needed.

## Components to be touched when implemented (reference only)

These are the files that *would* change when this feature is picked up.
**Do not edit now.**

- New: `ios/AudioNote/Services/StorageCoordinator.swift` — owns root URL + bookmark, exposes `audioURL(for:)`, `jsonURL`, `bootstrap()`, `changeLocation()`.
- New: `ios/AudioNote/Views/OnboardingView.swift` — first-launch UI + picker trigger.
- Modified: `ios/AudioNote/Services/AudioRecorderService.swift` — `generateFileUrl(for:)` reads from `StorageCoordinator` instead of `Documents/`.
- Modified: `ios/AudioNote/Services/TranscriptionStorage.swift` — `fileURL` reads from `StorageCoordinator`.
- Modified: `ios/AudioNote/Services/AudioPlayerManager.swift` — URL resolution via `StorageCoordinator`.
- Modified: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` — await `StorageCoordinator.bootstrap()` before any read/write; gate `loadHistory` on completion.
- Modified: `ios/AudioNote/Views/SettingsView.swift` — add "更换存储位置" entry.
- Modified: `ios/AudioNote/App/AudioNoteApp.swift` (or wherever the root view lives) — show `OnboardingView` when `StorageCoordinator.isReady == false`.

## Risks to acknowledge before implementation

1. **iOS 16+ `UIDocumentPickerViewController` folder picker**: confirm supported APIs exist on the project's minimum iOS version. If the project targets iOS 15 or earlier, this feature is not viable without bumping the deployment target.
2. **External file rename/move** (out of scope but worth noting): with a single root bookmark, if a user renames `Foo.m4a` to `Bar.m4a` in Files, the app will fail to find it. A future iteration could either (a) re-link by inspecting folder contents, or (b) move to per-file bookmarks.
3. **No background-write safety**: `startAccessingSecurityScopedResource` is per-process. The app must re-acquire on every cold start and on foregrounding. This is standard, but easy to forget when adding new entry points.

## Open questions before implementation

None — all clarifying questions were resolved during the 2026-09-24 session. The spec is ready to be picked up by an implementation plan when desired.

## Related

- `docs/GLOSSARY.md` — update when `StorageCoordinator` is added.
- `docs/decisions/` — a new ADR may be warranted when implementation begins, codifying decisions 1–10.
- `ios/AudioNote/Services/TranscriptionStorage.swift:31-33` — current `Documents/` path that this spec replaces.

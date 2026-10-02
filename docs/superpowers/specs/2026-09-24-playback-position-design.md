# Playback Position Per Record — Backlog Stub

**Status:** ✅ RESOLVED — implemented 2026-09-24 in `be428dc` (shipped to `origin/main`)
**Created:** 2026-09-24
**Branch at filing:** `feat/llm-test-connection`

> **Resolution (see "What actually shipped" below).** The user chose **§3.1 = C
> (no resume at all)** and **§3.2 = A (auto-stop A, start B)**. The cross-detail
> progress bleed is fixed without a schema change to `TranscriptionRecord`.
> This stub is kept for the root-cause analysis (§2) and the decision record;
> it is no longer a work item.

---

## 1. Problem

In the 思路 (Library) tab the user opens a record's detail, plays the audio, pauses partway through, then opens a *different* record's detail. That second detail's `PlaybackControlBar` is showing the first record's progress — both bars stay in lockstep as if the whole app shared one player state. The user expects each detail to have its own independent playback position.

## 2. Root Cause (verified)

- `ios/AudioNote/Services/AudioPlayerManager.swift:7` — `static let shared = AudioPlayerManager()` is a global singleton. It holds exactly one set of `@Published` state (`isPlaying`, `currentTime`, `duration`, `progress`).
- `ios/AudioNote/Views/SharedComponents.swift:76-119` — every `PlaybackControlBar` binds to that singleton via `@ObservedObject var playerManager = AudioPlayerManager.shared`. Therefore every bar reads from (and writes to) the same source.
- `AudioPlayerManager.play(fileName:)` (line 22) calls `stop()` (line 30) whenever the file name changes, which resets `currentTime = 0`, `progress = 0`, `duration = 0`, `currentFileName = nil`. So the second detail is not "resuming" — it's just that the singleton's state happens to match whatever the first detail left behind.

## 3. Open Design Questions (must be answered before any plan)

The user did not commit to either side at filing time. Stop and ask here.

### 3.1 Persistence scope

| Option | What it does | Trade-off |
|---|---|---|
| **A. Persist per record** | Extend `TranscriptionRecord` with `playbackPosition: Double` + `playbackUpdatedAt: Date?`. Write back via `TranscriptionViewModel.updateRecord` on pause / view-dismiss / periodic flush. | Survives app kill; cross-file change (model + storage + VM + UI). |
| B. In-memory only | `[fileName: TimeInterval]` dictionary inside the manager for the current process lifetime. | Lost on app kill. Simplest fix. |
| C. No resume at all | Each `play(fileName:)` starts at 0. Only fix the cross-detail bleed. | Smallest change. Loses any "continue where I left off" UX. |

### 3.2 Cross-detail behavior

When the user navigates from detail A (currently playing/paused) to detail B:

| Option | Behavior | Notes |
|---|---|---|
| **A. Auto-stop A, start B** | Single active player. Matches Apple Music / Podcasts mental model. | Most familiar. |
| B. Continue A in background, B gets independent bar | Multi-instance player. | Unusual for a voice-note app; bigger refactor. |
| C. Background A, plus a single global mini-player | Spotify-style. | Heaviest UX + code change. |

## 4. Files That Will Need to Change (any path)

- `ios/AudioNote/Services/AudioPlayerManager.swift` — refactor from singleton-with-global-state to either per-file state map or per-file player pool; `seek` / `pause` / `togglePlayPause` / `stop` semantics need per-record awareness.
- `ios/AudioNote/Views/SharedComponents.swift` — `PlaybackControlBar` currently `@ObservedObject`s the singleton. Needs to either take a per-record sub-state or be restructured so the manager dispatches events by `fileName`.
- `ios/AudioNote/Models/TranscriptionRecord.swift` — only if §3.1 option A wins: add `playbackPosition` + `playbackUpdatedAt`, update `init(from:)` / `CodingKeys` / `init(...)`, follow the legacy-shape handling pattern already used for `tags` / `archived` / `archivedAt`.
- `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` — only if §3.1 option A wins: persist flush path (similar to the `updateRecord` fix from `46d575c`).

## 5. Tests / Verification (deferred until plan)

No tests currently cover `AudioPlayerManager` or `PlaybackControlBar` (`codegraph` reports zero covering tests for both). When implementation starts, at minimum:

- Unit: per-record state isolation (open A, pause, open B, B's progress is independent).
- Unit: persistence round-trip (record A's position, kill, reopen → resume at saved position).
- Manual smoke on iPhone Air sim: see `memory/ios-device-registry.md` for the UDID + `xcodebuild` / `xcrun simctl` commands.

## 6. Out of Scope

- Background audio / lock-screen controls (`MPRemoteCommandCenter`).
- Playback speed (1x / 1.5x / 2x).
- Skip-back-10s / skip-forward-30s controls.
- Multi-file concurrent playback.

## 7. Next Step

~~User must answer §3.1 and §3.2.~~ **Done 2026-09-24 — see "What actually shipped" below.**

## 8. What actually shipped (`be428dc`)

| Stub question | Decision | Implementation |
|---|---|---|
| §3.1 持久化范围 | **C. No resume at all** | No `playbackPosition` field on `TranscriptionRecord`; each `play(fileName:)` starts at 0. |
| §3.2 跨详情行为 | **A. Auto-stop A, start B** (single active player) | `AudioPlayerManager.shared` stays a singleton; `play()` keeps the existing `guard fileName != currentFileName` stop-then-start path. |

Concrete change:

1. `AudioPlayerManager.currentFileName` → `@Published private(set)` so views can
   observe which file the global player is bound to.
2. `PlaybackControlBar` gained a private `isDifferentAudioPlaying` computed
   property: true when the bound `audioFileName` differs from
   `playerManager.currentFileName` and audio is live.
3. When true, the bar renders `"正在播放另一条录音"` + a "切到这条" button
   instead of the slider/time row — the other record's progress can no longer
   leak into this record's controls.
4. Tapping that button calls `togglePlayPause`, which stops A and starts B
   from 0.

User-stated rules encoded: closing the playing detail keeps audio alive;
navigating to another detail keeps audio alive but shows the switch hint;
tapping play on B stops A and starts B from 0; re-entering the playing page
resumes that same playback (it's the same `currentFileName`, so the progress
still belongs to it).

Verification: `xcodebuild` iphonesimulator + iphoneos BUILD SUCCEEDED, then
installed and launched on the iPhone Air.
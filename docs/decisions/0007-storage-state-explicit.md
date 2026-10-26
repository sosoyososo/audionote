# ADR-0007: 存储状态显式化 —— 「读不出来」不等于「空」

| Field | Value |
|---|---|
| **Status** | ACCEPTED (2026-10-22) |
| **Date** | 2026-10-22 |
| **Supersedes** | — |
| **Superseded-by** | — |
| **Author** | — |
| **Related** | `docs/superpowers/specs/2026-10-22-data-layer-architecture-design.md`（P0 改造项） |

## Context (one paragraph)

The data lives in a user-picked folder under `On My iPhone`, not in the app's
sandbox. The app's *memory* of that folder — the security-scoped bookmark — lives
in `UserDefaults`, which dies with the app. So the data and the app's ability to
find it have different lifetimes, and every abnormal flow follows from that
mismatch: an uninstall leaves the data behind and takes the bookmark with it, and
a reinstalled app cannot find the folder again without the user re-picking it.

Two consequences were invisible until the storage layer was read end to end.

**First, one `isReady` Bool was carrying five meanings.** It had to be false for
"never configured", false for "configured but the folder is gone", false for
"configured but the bookmark no longer resolves", true for "the directory is
reachable" — and, by way of `TranscriptionStorage`, it was also the only signal
the UI had for "the records file does not parse". A corrupted `transcriptions.json`
produced an empty library and an `errorMessage` that was surfaced **only on the
recording tab** (`RecordingView.swift:85`), so a user sitting on the library tab
saw "没有记录" and concluded their data was gone. `bootstrap()`'s failure branch
set no message at all, so the OnboardingView that replaced the whole app gave the
user no way to tell "you never set this up" from "your folder went missing".

**Second, `save()` could destroy the library.** `TranscriptionStorage.save` read
the library with `(try? await loadAll()) ?? []`. A read failure was therefore an
*empty library*, and the next write replaced the whole file with the single
record being saved. One corrupt file, one save, and every record the user had was
gone — with a symptom indistinguishable from the user having deleted them by
hand. The write path is atomic (`.atomic`), so the app could not corrupt the file
itself; the corruption had to come from outside (a sync conflict, an external
edit, a full disk), and the app's response to it was total loss.

## Decision

**Split the storage state in two, and let each half live in the layer that owns
it.**

`StorageCoordinator.state` is an explicit enum about **access**:

```swift
enum StorageState: Equatable {
    case unconfigured
    case unreachable(UnreachableReason)   // bookmarkInvalid / folderMissing / accessDenied / notSecurityScoped
    case ready
}
```

`TranscriptionStorage.LoadOutcome` is an explicit enum about **the file**:

```swift
enum LoadOutcome {
    case noFile
    case records([TranscriptionRecord])
    case corrupted(Error)
}
```

The two halves land on different screens — the access half on OnboardingView, the
file half on the library list — so they belong to different layers. `isReady`
survives as a computed property (`state == .ready`) so the 40-odd existing
call sites keep working, but it can no longer disagree with `state`.

### Locked

1. **A library that could not be read MUST NOT render as an empty library.**
   `corrupted` and `noFile` are different states and must look different on
   screen. The empty state means "you haven't recorded anything"; the corrupted
   state means "your data is there and I can't parse it" — and in the corrupted
   case the `.m4a` files are still sitting in the folder. Rendering them the same
   way is how a recoverable problem becomes "my data is gone".
2. **A failed read MUST NOT be treated as an empty library by a writer.**
   `save()` propagates the read failure. It no longer falls back to `[]`.
3. **The app MUST NOT destroy its only access credential because a resolution
   attempt failed.** `resolveBookmarkSync` and `resolvePathFallbackSync` keep
   the stored bookmark and path on every failure path and report a reason
   instead. A bookmark that no longer resolves does not prove the folder is
   gone — the folder may have been moved, renamed, or merely be unavailable
   right now (an iCloud Drive folder that hasn't downloaded). Destroying it
   turned a recoverable "can't find the folder" into "re-pick from scratch",
   and the re-pick is exactly the step people get wrong: pick a new empty
   folder, and the app shows an empty library with no explanation.
4. **The app MUST say why it cannot reach the data.** `bootstrap()` publishes
   `state = .unreachable(reason)` and sets `errorMessage` to the reason's
   message; OnboardingView renders the reason and the hint.
5. **After a reinstall, the app MUST tell the user to pick the same folder
   again.** The data survived; the bookmark did not. The OnboardingView body
   copy says so, because a user who picks a *different* folder gets a working
   app with an empty library, and nothing else in the app would explain why.

### Not locked (deliberately)

- The exact wording of the user-facing strings.
- The cap on the launch-time recovery sweep (that is ADR-0006's business, and
  it is not decided yet).
- Whether provider profiles move out of `UserDefaults` and into the data
  folder. That is a P1 item with its own trade-offs (see the spec §7), and it
  is not needed for any of the five rules above.

## Consequences

**Good**

- "My data is gone" stops being a conclusion the user draws from a blank
  screen. There is now a screen that says "the file is there but I can't read
  it" and a screen that says "your folder is at such-and-such a place".
- A corrupt file is survivable: the next save fails loudly and leaves the file
  alone, so the user can inspect `transcriptions.json` in the Files app, repair
  it, and carry on. Before, the first save after the corruption destroyed
  everything.
- The bookmark survives transient failures, so a folder that comes back (an
  iCloud download completing, a folder being moved back) reconnects without
  the user re-picking anything.

**Bad / accepted**

- `StorageCoordinator` grew two public types (`StorageState`,
  `UnreachableReason`) and `TranscriptionStorage` grew one
  (`LoadOutcome`). The alternative was one mega-enum, which would have put a
  JSON-parsing concern inside the layer that owns folder access.
- `TranscriptionStorage` gained an `init(fileURL:)` test seam, mirroring
  `RelatedNotesStorage`. It is a public initializer on a production type, but
  it is the only way to test the layer where data is won and lost.
- The library list has a third state view it didn't have before. That is the
  point of the change.

## Verification

- `ios/AudioNoteTests/TranscriptionStorageTests.swift` — 9 tests. The
  load-outcome cases (missing file / parsed file / corrupt file / empty-but-
  present file) and the data-loss regression.
- The data-loss test was verified **red** against the old implementation: with
  `(try? await loadAll()) ?? []` restored, 2 of the 9 fail. It is a test of the
  behaviour, not of the compile.
- Full suite: 203 tests, 0 failures.
- The UI half (OnboardingView's reason text, the library's error state) is
  build-verified only — there is no UI-test target in this project.

## Amendment log

- **2026-10-22.** Original. Written as part of the P0 tranche of
  `2026-10-22-data-layer-architecture-design.md`.

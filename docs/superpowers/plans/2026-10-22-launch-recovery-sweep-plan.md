# Launch Recovery Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Give the app a second trigger for the recovery pipeline, so a record stranded by a previous session (audio on disk with no transcript, or an LLM pass that failed) recovers on the next launch instead of waiting for the user to toggle the network off→on during the current session.

**Architecture:** Extract the candidate selection of the existing `networkDidRecover` steps into a pure static function on `PendingRecognitionPolicy`, so both sweeps draw from one source and cannot drift. The launch sweep runs the same steps 1 / 3 / 4 — it deliberately skips step 2 (the on-device→online upgrade), which is an improvement rather than a recovery. The launch sweep's LLM work is capped, because an unattended launch must not turn into an unbounded burst of API calls.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 16+, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-22-launch-recovery-sweep-design.md` — the plan argues from the spec, so the spec travels with it; executors read both.

## Global Constraints

- **Any online call (LLM, online recognition) MUST be gated by `NetworkMonitor.shared.checkConnectivity()` first.** No exceptions. (Project CLAUDE.md locked decision.)
- **`llmQueue` and `recognitionRetryQueue` are locked by ADR-0005.** This plan does not change what they return. It adds a *caller* and a *cap* around them.
- **A `.pending` record MUST be excluded from every LLM path.** (ADR-0005.) `llmQueue` already does this; the launch sweep inherits it by construction.
- **Writes go through the `TranscriptionStorage` class.** Never write the record JSON directly.
- **The sweep MUST NOT run unless `StorageCoordinator.state == .ready`.** (ADR-0007.) A `.unreachable` state can leave a stale `resolvedRoot`, and recovering against a folder the user is no longer using is worse than not recovering.
- **New storage files hang off `StorageCoordinator`'s derived properties.** This plan adds none.
- **Every user-facing string goes in both `zh-Hans.lproj/Localizable.strings` and `en.lproj/Localizable.strings`** with identical keys. This plan adds none.
- **`xcodegen generate` must be run after adding any new file**, and it must exit 0.
- Deployment target is iOS 16.0. Swift 5.9.

### Commands (run from `ios/`)

```sh
xcodegen --spec project.yml

xcodebuild build -project AudioNote.xcodeproj -scheme AudioNote \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4' \
  -derivedDataPath .build/DerivedData

xcodebuild test -project AudioNote.xcodeproj -scheme AudioNote \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4' \
  -only-testing:AudioNoteTests \
  -derivedDataPath .build/DerivedData

# Install + launch on the real device (iPhone Air)
xcodebuild build -project AudioNote.xcodeproj -scheme AudioNote \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData -allowProvisioningUpdates
xcrun devicectl device install app \
  --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 \
  .build/DerivedData/Build/Products/Debug-iphoneos/AudioNote.app
xcrun devicectl device process launch \
  --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 info.karsa.app.ios.audionote
```

`-derivedDataPath .build/DerivedData` is required: the default `~/Library/Developer/Xcode/DerivedData` is not writable in this environment, and `ENABLE_BUILD_SANDBOXING=NO` does not fix the macro-plugin failure.

`devicectl` may print `Failed to load provisioning parameter list … No provider was found` on success — benign.

## File Structure

| File | Responsibility |
|---|---|
| `ios/AudioNote/Services/PendingRecognitionPolicy.swift` (modify) | `RecoveryCandidates`, `recoveryCandidates(from:)`, `llmPool(from:limit:)`, `launchLLMLimit`. Pure statics — the only testable seam, because the view model wires its collaborators as `private let` singletons. |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` (modify) | `runRecoverySweep(includeOnDeviceUpgrade:llmLimit:)` — the shared body; `recoverStrandedRecords()` — the launch entry point; the `isRecovering` guard; `isBackgroundRecovery` / `isAwaitingUserLLMResult`. |
| `ios/AudioNote/Views/RecordingView.swift` (modify) | Two `isLLMProcessing` → `isAwaitingUserLLMResult`. |
| `ios/AudioNote/Views/TranscriptionDetailView.swift` (modify) | Two `isLLMProcessing` → `isAwaitingUserLLMResult`. |
| `ios/AudioNoteTests/LaunchRecoverySweepTests.swift` (create) | All tests for this feature. |

## Review Focus

Five things a reasonable user would exercise that the happy path won't cover.

1. **The user launches the app while offline.** The sweep must not run and must not leave the app in a "recovering" state that blocks the next launch. → Task 3 test.
2. **The user launches the app with a storage folder that is no longer reachable.** The sweep must not recover against the stale path. → Task 3 test (the `state == .ready` guard).
3. **A `.pending` record reaches the LLM.** The launch sweep must exclude it, or the model gets an empty string and invents a title. → Task 1 test.
4. **The user hand-edited a record.** The launch sweep must not overwrite their text with an LLM rewrite. → Task 1 test.
5. **The user launches the app while a network recovery is already running.** The same record must not be processed twice — two LLM calls, two writes. → Task 3 test.

A sixth, from the UI side: **the user opens a note while the background sweep is running.** The detail view's LLM button must still be there. `processWithLLM` sets `isLLMProcessing`, which is a *user-facing* signal ("you are waiting for a result"); a background catch-up is not that. → Task 4 test.

---

### Task 1: The policy — one candidate source, capped

**Files:**
- Modify: `ios/AudioNote/Services/PendingRecognitionPolicy.swift`
- Test: `ios/AudioNoteTests/LaunchRecoverySweepTests.swift` (create)

**Interfaces:**
- Consumes: `llmQueue(from:)`, `recognitionRetryQueue(from:)`, `isHandEdited(_:)` (all existing)
- Produces:
  - `struct RecoveryCandidates { let neverProcessed: [TranscriptionRecord]; let failedLLM: [TranscriptionRecord]; let recognitionRetry: [TranscriptionRecord] }`
  - `static func recoveryCandidates(from records: [TranscriptionRecord]) -> RecoveryCandidates`
  - `static func llmPool(from records: [TranscriptionRecord], limit: Int?) -> [TranscriptionRecord]`
  - `static let launchLLMLimit: Int`

- [x] **Step 1: Write the failing tests**

`LaunchRecoverySweepTests.swift` must cover:

- `recoveryCandidates` splits the library three ways: never-LLM'd records, failed-LLM records, records awaiting recognition.
- `recoveryCandidates` excludes `.pending` records from the LLM side (ADR-0005).
- `recoveryCandidates` excludes hand-edited records from both sides.
- `recoveryCandidates` puts a `.pending` record with audio in `recognitionRetry`.
- `llmPool(limit: nil)` returns every pending-LLM record, in the input order — this is the **network-recovery** behaviour, and it must not change.
- `llmPool(limit: 10)` returns at most 10, **oldest first**.
- The recognition-retry side is **not** affected by the LLM limit (re-recognition is free; ADR-0005 §4.6 says retries are unlimited).

- [x] **Step 2: Run the tests — they must fail**

- [x] **Step 3: Implement**

`RecoveryCandidates` is a plain struct of three arrays. `recoveryCandidates(from:)` builds the two LLM buckets out of `llmQueue(from:)` (so ADR-0005's `.pending` and hand-edit exclusions are inherited, not re-implemented) and the recognition bucket out of `recognitionRetryQueue(from:)`.

`llmPool(from:limit:)` returns `llmQueue` records whose status is `nil` **or** `.failed` — the two LLM steps' combined pool. With `limit == nil` it returns them in input order (unchanged network-recovery behaviour). With a limit it sorts by `createdAt` ascending and truncates. The sort is applied **only** when there is a limit: the network sweep's order is existing behaviour and must not shift underneath it.

Why oldest-first when capping: the cap decides *which* stranded records get finished this launch. Oldest-first means the ones that have been waiting longest go first, and the ones that get skipped are the most recent — the ones the user is most likely to still care about, and most likely to be picked up by the next launch anyway.

- [x] **Step 4: Run the tests — they must pass**

### Task 2: The view model — one sweep body, two triggers

**Files:**
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`

**Interfaces:**
- Consumes: `PendingRecognitionPolicy.recoveryCandidates(from:)`, `.llmPool(from:limit:)`
- Produces: `func recoverStrandedRecords() async`, `private func runRecoverySweep(includeOnDeviceUpgrade: Bool, llmLimit: Int?) async`

- [x] **Step 1: Extract the shared body**

`networkDidRecover` becomes a call to `runRecoverySweep(includeOnDeviceUpgrade: true, llmLimit: nil)`. The four steps keep their order and their bodies; only the candidate lists come from the policy now.

`recoverStrandedRecords()` calls `runRecoverySweep(includeOnDeviceUpgrade: false, llmLimit: .launchLLMLimit)`.

**Step 2 (network sweep) stays before step 4 (failed LLM) — do not merge them.** The two steps have identical bodies today, and merging them looks like a simplification. It is not: step 2 replaces `content` with the online-recognized text while leaving the LLM metadata alone, so an LLM pass that ran *before* step 2 would write a title and summary describing the *old* text. Keeping step 4 after step 2 means the LLM sees the final text. Merging the two steps would silently reintroduce that skew, so the four steps stay four steps.

- [x] **Step 2: Add the guards**

The sweep body refuses to run unless:

- `StorageCoordinator.shared.state == .ready` — a `.unreachable` state can leave a stale `resolvedRoot`, and recovering against a folder the user is no longer using is worse than not recovering at all.
- `NetworkMonitor.shared.checkConnectivity()` — every step already re-checks it, but the sweep should not even start offline.

And it refuses to run if a sweep is already running (`isRecovering`): the launch sweep and a network recovery can overlap (launch offline, network returns mid-sweep), and the same record processed twice means two LLM calls and two writes.

- [x] **Step 3: Add the launch trigger**

`init()`'s existing `Task { @MainActor in … }` calls `recoverStrandedRecords()` after `loadHistory()`.

- [x] **Step 4: Build**

### Task 3: The background-recovery UI distinction

**Files:**
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`
- Modify: `ios/AudioNote/Views/RecordingView.swift`
- Modify: `ios/AudioNote/Views/TranscriptionDetailView.swift`

**Interfaces:**
- Produces: `@Published private(set) var isBackgroundRecovery: Bool`, `var isAwaitingUserLLMResult: Bool`

- [x] **Step 1: Add the flag**

`runRecoverySweep` sets `isBackgroundRecovery = true` for the duration when it is running as a background catch-up. The views read `isAwaitingUserLLMResult` (`isLLMProcessing && !isBackgroundRecovery`) instead of `isLLMProcessing`.

`processWithLLM` stays the single LLM choke point — a separate background variant would duplicate the call, the guards and the error handling, and the duplication is exactly what let the last three bugs through.

- [x] **Step 2: Update the four call sites**

`RecordingView` (2) and `TranscriptionDetailView` (2).

- [x] **Step 3: Build + run the full suite**

### Task 4: Tests for the whole thing

**Files:**
- Test: `ios/AudioNoteTests/LaunchRecoverySweepTests.swift` (add to Task 1's file)

- [x] **Step 1: The regression guarantee that matters**

`llmPool(from: limit: nil)` must return exactly the union of what step 1 and step 4 used to select, in the same order. That is the guarantee that the refactor did not change the network-recovery sweep's behaviour.

- [x] **Step 2: `xcodegen generate` + full suite**

### Task 5: Documentation

**Files:**
- Create: `docs/decisions/0006-launch-recovery-sweep.md`
- Modify: `docs/GLOSSARY.md`, `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-10-22-launch-recovery-sweep-design.md` (mark implemented)

- [x] **Step 1: Write ADR-0006**

The locked parts: the launch sweep runs steps 1/3/4 and not step 2; the LLM cap; the launch sweep is capped and the network sweep is not; the two sweeps must not overlap; the sweep requires `state == .ready`; a background sweep must not hold the UI's "user is waiting" signal.

- [x] **Step 2: Update the glossary and `CLAUDE.md`**

- [ ] **Step 3: Device verification** — *build + install + launch done; the end-to-end path still needs a stranded record*

Build, install, launch. The observable effect: a `.pending` record left over from a previous session gains a transcript on the next launch. Verify on the device by recording with the network off (producing a `.pending` record), then turning the network on and relaunching.

**Note for whoever deploys this**: the first launch after installing will run the sweep against the real library, and the sweep spends real API calls — up to 10 LLM calls. That is the feature working, not a bug, but it is a bill.

## Not in scope

- **Changing the network-recovery sweep's behaviour.** It stays uncapped and keeps its four steps. Its unbounded LLM burst is a pre-existing issue; capping it would mean a backlog can only be cleared by toggling the network repeatedly, which is worse. Recorded in the spec as a known issue.
- **Reordering the network-recovery steps.** Step 1 (never LLM'd) runs before step 2 (on-device upgrade), so an on-device record can end up with a title and summary describing the pre-upgrade text. That is pre-existing and is left alone here — the launch sweep does not run step 2, so it does not have the problem.
- **Recovering orphaned audio.** Rejected 2026-10-22; see the data-layer spec §"P2-1 的否决理由".

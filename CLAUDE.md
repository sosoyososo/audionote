# CLAUDE.md — agent entry point for audionote

> Read this before touching code. Use `codegraph_explore` (not grep) for symbol lookup; this file points you at the docs and locks.

## What this project is

iOS voice transcription app (SwiftUI, single-target). Records audio, runs recognition (Apple Speech, on-device or online), optionally sends to a cloud LLM for punctuation/homophone cleanup. Persists records locally.

- iOS source: `ios/AudioNote/`
- Design specs: `docs/superpowers/specs/`
- Implementation plans: `docs/superpowers/plans/`

## Architecture docs (read first when changing behavior)

| Doc | When to read |
|---|---|
| `docs/GLOSSARY.md` | Adding a feature, naming a type, looking for the canonical symbol for a concept |
| `docs/decisions/0001-assess-enhance-llm-pipeline.md` | Touching `TranscriptionViewModel.assessAndEnhance` or `RecognitionMode` |
| `docs/decisions/0002-merge-llm-calls.md` | Touching `LLMService.optimizeAndProcess` or its 4-field response schema |
| `docs/decisions/0005-pending-recognition-mode.md` | Touching `RecognitionMode.pending`, `PendingRecognitionPolicy`, or the `networkDidRecover` queues |
| `docs/decisions/0006-launch-recovery-sweep.md` | Touching the recovery sweeps, `PendingRecognitionPolicy.recoveryCandidates`, or the `isLLMProcessing` UI flags |
| `docs/decisions/0007-storage-state-explicit.md` | Touching `StorageCoordinator.state`, `TranscriptionStorage.loadOutcome`/`save`, or the storage-failure UI |
| `docs/decisions/0009-folder-hint-outlives-the-app.md` | Touching `StorageFolderHint`, the access bookmark's location, or the reinstall copy |
| `docs/decisions/0008-provider-profiles-in-the-data-folder.md` | Touching `ProviderProfileStore`, `ProviderProfileStorage`, or where the LLM provider profiles live |
| `docs/decisions/` (new ADRs go here) | Touching any locked decision |
| `docs/ROADMAP.md` | List of deferred doc types + when to activate them (RISKS / state-machines / contracts / etc.) |
| `docs/superpowers/specs/<date>-<topic>-design.md` | Adding a new feature or behavior (read the design doc first) |

## Open work

Decided but not done. This is an **index**, not the content — each row says what the item is and where the detail lives.

**Rule:** a row exists only while the item is genuinely open. When it lands, delete the row **and** set the owning spec's `Status` to `IMPLEMENTED` — the index and the spec must never disagree. Items decided *against* belong in "Don't do these" below, not here.

| Open item | Where the detail is |
|---|---|
| Tag vocabulary: 158 tags over 40-odd notes. Direction A — reuse existing tags when extracting (the prompt hint exists but the vocabulary is capped at the 30 *most frequent* tags, so the long tail never reaches the model); direction B — LLM-based semantic merging of existing tags | `docs/superpowers/specs/2026-10-26-tag-vocabulary-maintenance-design.md` (Status: IDEA) |
| Show the current data folder path in Settings | `docs/superpowers/specs/2026-10-22-data-layer-architecture-design.md` §7 (P1-5) |
| Record a "the audio file is gone" state | same spec, §7 (P2-2) |
| Back up `relatedNotes.json` | same spec, §7 (P2-3) |

## Locked decisions (don't change without checking the doc)

- **RecordingViewModel** does not exist. The orchestrator is `TranscriptionViewModel` (`ios/AudioNote/ViewModels/TranscriptionViewModel.swift`). Don't create a parallel one.
- `assessAndEnhance` dispatch shape (4 cases by `RecognitionMode`) is locked. See ADR-0001, ADR-0005.
- Any online call (LLM, online recognition) MUST be gated by `NetworkMonitor.shared.checkConnectivity()` first. No exceptions.
- `optimizedContent != content` ⇒ auto-enhance and every automatic recovery pass MUST skip. Note the predicate is overloaded: it is true for LLM-written text too, so `isHandEdited` means "content diverged from its source", not "a human typed this". See ADR-0005.
- A `RecognitionMode.pending` record (audio, no transcript) MUST be excluded from every LLM path. See ADR-0005.
- A bare `record.optimizedContent ?? record.content` at a new LLM call site is a bug — it silently sends the user's pre-edit text to the model. Resolve input through `PendingRecognitionPolicy.llmInputText(for:)` instead. See ADR-0005.
- A library that could not be read MUST NOT render as an empty library. `TranscriptionStorage.loadOutcome()` distinguishes `.noFile` / `.noFileButAudioRemains(count)` / `.records` / `.corrupted`; `StorageCoordinator.state` distinguishes `.unconfigured` / `.unreachable(reason)` / `.ready`. A failed read is never an empty library — not for the UI, and not for a writer (`save` propagates the failure instead of defaulting to `[]`). An *empty* library is not an *absent* one either: when the records file is gone but `.m4a` files remain in `Recordings/`, say so. The app also must not delete its bookmark because a resolution attempt failed. See ADR-0007.
- The folder's **name** is remembered in the Keychain (`StorageFolderHint`) so a reinstalled app can say which folder to pick. The **access bookmark stays in `UserDefaults`** and must not move to the Keychain (a reinstalled app must not inherit folder access without the user re-authorizing it) and must not move into the data folder either (without a bookmark there is no permission to read the folder, so a credential kept in the thing it unlocks can never be read). See ADR-0009.
- The LLM provider profiles live in the **data folder** (`profiles.json`), not in `UserDefaults`: a profile's `id` is the Keychain account its API key is stored under, and `UserDefaults` dies with the app, so a profile that did not come back after a reinstall orphaned its key in the Keychain. The **API key stays in the Keychain** and must never be written to the folder — the folder syncs and gets shared. The read is asynchronous: call `ProviderProfileStore.ensureLoaded()` before reading `profiles` / `active`, or the LLM path will read an empty list and skip itself. The migration from `UserDefaults` MUST preserve the profile ids — a regenerated id orphans the key irrecoverably. See ADR-0008.
- The launch recovery sweep MUST run the same steps as the network-recovery sweep (1 / 3 / 4, not step 2) and MUST draw its candidates from the same function — `PendingRecognitionPolicy.recoveryCandidates(from:llmLimit:)`. Two sweeps with their own candidate logic would drift invisibly. The launch sweep's LLM work is capped at `launchLLMLimit` (10 per launch, both buckets together, oldest first); the network sweep's is not. The cap does NOT bound re-recognition. A sweep requires `StorageCoordinator.state == .ready` and MUST NOT overlap another sweep. See ADR-0006.
- A background sweep MUST NOT take the UI's "the user is waiting for a result" signal. `isLLMProcessing` / `llmProcessingFailed` are global, not per record, so the views read `isAwaitingUserLLMResult` / `hasUserFacingLLMFailure` instead. A background sweep's failures are delayed, not swallowed. See ADR-0006.
- An update MUST NOT delete LLM metadata the caller did not restate. `TranscriptionViewModel.updateRecord` derives the stored record through `PendingRecognitionPolicy.mergedRecord(incoming:existing:)`, where every optional field is `incoming ?? existing` — a caller that omits a field is not asking for it to be cleared. Do not hand-build a `TranscriptionRecord` at a call site and pass it to `updateRecord` without restating the fields it means to keep. See ADR-0005.

## Don't do these

- Don't add a `RecordingViewModel` — it confuses readers.
- Don't introduce a new `RecognitionMode` case without extending the `assessAndEnhance` switch.
- Don't write to `TranscriptionStorage` JSON directly — go through the storage class.
- Don't store audio file URLs in `TranscriptionRecord` — store the UUID-based filename and reconstruct via `AudioRecorderService.generateFileUrl(for:)`.
- Don't `grep`-then-Read for symbol discovery. Use `codegraph_explore "SymbolName"` first.
- **Don't keep a `.bak` copy of `transcriptions.json`.** Decided against on 2026-10-26 — the records file is the user's own file in their own folder, and a second copy inside that folder is a second thing that can go stale. A corrupted records file is already loud rather than silent: `save` refuses to write over a file it could not read (ADR-0007), so the damaged file is preserved for the user to recover by hand instead of being replaced with an empty library. Don't propose a backup copy, a restore UI, or a recovery prompt for this file.
- **Don't add a shared Keychain access group.** Decided against on 2026-10-26 — the bundle ID `info.karsa.app.ios.audionote` and the team `25FH23Q3GA` are settled, so no key has to cross a bundle-ID boundary. An access group's id carries the signing team's prefix, so it can only bridge bundle IDs *within* one team; it buys nothing here. If the bundle ID is ever changed this becomes a real decision again, and the order matters: migrate the existing items (the LLM API keys and the folder hint) into the shared group **first**, under the current bundle ID — the group's own id changes with the bundle ID, so a group added after the change would not see the old items.

## File layout

```
ios/AudioNote/
  App/           // entry point
  Models/        // TranscriptionRecord, RecognitionMode, RecognitionLanguage, NoteRelation, LLMProviderProfile
  Services/      // AudioRecorder, SpeechRecognizer, LLMService, TranscriptionStorage, StorageCoordinator, KeychainStore, ProviderProfileStore, RelatedNotesService/Storage, TagMerger, PendingRecognitionPolicy, AudioPlayerManager
  Utilities/     // NetworkMonitor, PermissionsManager, LanguageManager, Logger, TagIdentity, FlowLayout, GradientView, LanguageSelectorView
  ViewModels/    // TranscriptionViewModel, SettingsViewModel
  Views/         // ContentView, RecordingView, LibraryListView, TranscriptionDetailView, SettingsView, MergeTagsView, OnboardingView, ProfileDetailView, SharedComponents
```

## How to add a new feature

1. Read `docs/superpowers/specs/` for any earlier feature with the same shape.
2. Search `docs/decisions/` for ADRs that touch the area.
3. Write a new spec at `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`.
4. Write a plan at `docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md`.
5. Implement. Update `docs/GLOSSARY.md` if you added new public types.
6. If the change locks a new decision, write `docs/decisions/NNNN-<topic>.md`.
7. If the work will not be finished in this session, add a row to **Open work** above (one line, pointing at the doc that holds the detail).
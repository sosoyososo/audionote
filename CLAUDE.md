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
| `docs/decisions/` (new ADRs go here) | Touching any locked decision |
| `docs/ROADMAP.md` | List of deferred doc types + when to activate them (RISKS / state-machines / contracts / etc.) |
| `docs/superpowers/specs/<date>-<topic>-design.md` | Adding a new feature or behavior (read the design doc first) |

## Locked decisions (don't change without checking the doc)

- **RecordingViewModel** does not exist. The orchestrator is `TranscriptionViewModel` (`ios/AudioNote/ViewModels/TranscriptionViewModel.swift`). Don't create a parallel one.
- `assessAndEnhance` dispatch shape (3 cases by `RecognitionMode`) is locked. See ADR-0001.
- Any online call (LLM, online recognition) MUST be gated by `NetworkMonitor.shared.checkConnectivity()` first. No exceptions.
- `optimizedContent != content` (record was user-edited) ⇒ auto-enhance MUST skip.

## Don't do these

- Don't add a `RecordingViewModel` — it confuses readers.
- Don't introduce a new `RecognitionMode` case without extending the `assessAndEnhance` switch.
- Don't write to `TranscriptionStorage` JSON directly — go through the storage class.
- Don't store audio file URLs in `TranscriptionRecord` — store the UUID-based filename and reconstruct via `AudioRecorderService.generateFileUrl(for:)`.
- Don't `grep`-then-Read for symbol discovery. Use `codegraph_explore "SymbolName"` first.

## File layout

```
ios/AudioNote/
  App/           // entry point
  Models/        // TranscriptionRecord, RecognitionMode, RecognitionLanguage
  Services/      // AudioRecorder, SpeechRecognizer, LLMService, TranscriptionStorage, AIProcessingService
  Utilities/     // NetworkMonitor, PermissionsManager, LanguageManager, Logger
  ViewModels/    // TranscriptionViewModel, SettingsViewModel
  Views/         // ContentView, RecordingView, HistoryListView, TranscriptionDetailView, SettingsView, SharedComponents
```

## How to add a new feature

1. Read `docs/superpowers/specs/` for any earlier feature with the same shape.
2. Search `docs/decisions/` for ADRs that touch the area.
3. Write a new spec at `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`.
4. Write a plan at `docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md`.
5. Implement. Update `docs/GLOSSARY.md` if you added new public types.
6. If the change locks a new decision, write `docs/decisions/NNNN-<topic>.md`.
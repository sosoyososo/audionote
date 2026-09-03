# ADR-0001: Network-aware assess-enhance-LLM pipeline

| Field | Value |
|---|---|
| **Status** | ACCEPTED |
| **Date** | 2026-08-12 |
| **Supersedes** | — |
| **Superseded-by** | — |
| **Author** | — |

## Context (one paragraph)

Previously, after a recording stopped, the app blindly called the LLM to "optimize" the transcript. This had three problems:
1. When recognition fell back to on-device (offline), the LLM was still called over a possibly-dead network.
2. When recognition had failed entirely (`.failed`), we still tried to optimize empty / partial text.
3. The pipeline branched on ad-hoc `if` checks scattered across the VM.

## Decision

Introduce a single Phase-2 dispatcher `TranscriptionViewModel.assessAndEnhance` that branches on `TranscriptionRecord.recognitionMode` and explicitly checks `NetworkMonitor.checkConnectivity()` before any online call.

```
.online  → LLM (if optimize-on)
.onDevice → LLM (if optimize-on AND online)  || enhanceRecognition (if online)
.failed  → retryRecognitionFromFile (if online)
```

## What's locked (do not change without superseding this ADR)

- The three-case dispatch shape — **don't add branches per language or per LLM provider without a new entry.** New `RecognitionMode` cases MUST extend this switch.
- The network gate: any code path that reaches the LLM MUST call `NetworkMonitor.shared.checkConnectivity()` first. No exceptions.
- The check-then-call pattern in `assessAndEnhance` is single-shot, not retried inside — retries live in `AIProcessingService.processPendingRecords`.

## Free to change without new ADR

- The LLM prompt itself (`LLMService.optimize*` body)
- The choice of LLM provider (just rewire `LLMService.callAPI`)
- The set of languages (`RecognitionLanguage` enum)
- The UI rendering of each mode (`recognitionModeIcon` / `Label` / `Color` in `TranscriptionDetailView`)

## Touch this when

- A new `RecognitionMode` case is added (always rewrite — new switch arm required)
- LLM provider changes from cloud to on-device, or vice versa (then the connectivity gate may move)
- We add background retry that conflicts with the single-shot contract above

## Code anchors

| Symbol | Path:line |
|---|---|
| Dispatcher | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:233` |
| Switch on mode | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:236-261` |
| Connectivity check | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:246, 248, 255` |
| Enhance impl | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:265` |
| Retry impl | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:307` |
| RecognitionMode enum | `ios/AudioNote/Models/TranscriptionRecord.swift:3` |
| NetworkMonitor | `ios/AudioNote/Utilities/NetworkMonitor.swift:4` |

## Test coverage expected

Any PR that touches this file MUST keep or extend tests for:
- `.online + LLM on` → `processWithLLM` called once
- `.online + LLM off` → no LLM call
- `.onDevice + LLM on + online` → `processWithLLM` called once
- `.onDevice + LLM off + online` → `enhanceRecognition` called once
- `.failed + online` → `retryRecognitionFromFile` called once
- `.failed + offline` → no calls

(Tests not yet present — see RISKS, not yet written.)

## Related

- Spec: `docs/superpowers/specs/2026-05-18-network-aware-recognition-design.md`
- Commit: `05fb984 feat: rewrite recording orchestration with network-aware assess-enhance-LLM pipeline`
- Follows commit: `a691e09 fix: add offline connectivity guards before LLM processing`

## Format note (for future ADR authors)

This file is the template. New ADRs MUST follow the same field order:
Status / Date / Supersedes / Superseded-by / Context / Decision / What's locked / Free to change / Touch this when / Code anchors / Test coverage / Related.

`Status` values: `PROPOSED` → `ACCEPTED` → `SUPERSEDED`. Never `REJECTED`; if rejected, just don't write the file.
# ADR-0004: AI optimization by default — drop the `enableLLMOptimization` toggle

| Field | Value |
|---|---|
| **Status** | ACCEPTED |
| **Date** | 2026-09-24 |
| **Supersedes** | Partially — ADR-0001's `if optimizationEnabled` gate inside `assessAndEnhance`'s `.online` / `.onDevice` branches is removed. The 3-case dispatch shape and the connectivity gate are **preserved**. |
| **Superseded-by** | — |
| **Author** | karsa |

## Context

`audioNote:enableLLMOptimization` was a `UserDefaults` Boolean that gated
the LLM call inside `TranscriptionViewModel.assessAndEnhance`, sitting
beside the two other gates (`ProviderProfileStore.shared.active != nil`
and `NetworkMonitor.shared.checkConnectivity()`). The same key drove a
toggle in `SettingsView` (`SettingsView.swift:48-54`) labeled "启用录音内容优化",
guarded by `.disabled(!canEnableOptimization)` so it could only be
enabled when a Provider + API key were already present.

Three problems accumulated around it:

1. **Product-value mismatch.** The app's value is exactly "voice → structured note
   (title / summary / tags)". The LLM call is the differentiator, not an
   optional add-on. The toggle frames it as opt-in when it is in fact the
   default.
2. **Hidden consent anchor.** The user's actual consent to "my text leaves the
   device" happens when they configure a Provider (which `LLMProviderProfile`
   requires an explicit, deliberate save). The toggle sat between the
   consent moment and the LLM call without adding real control — the only
   group that could exercise it was a tiny subset of users who already had
   a Provider + API key + network and still wanted to suppress the call.
3. **State-sync bug.** `@State private var optimizeEnabled: Bool = false`
   in `SettingsView.swift:14` was never initialized from `UserDefaults`;
   the `onChange` handler only wrote. Result: a UI state that drifts from
   the real on/off state across re-entries into Settings.

## Decision

### 1. Remove the UserDefaults gate from `assessAndEnhance`

The LLM call is now decided solely by the two remaining gates:

| Gate | Where |
|---|---|
| Active Provider with API key present | `processWithLLM` reads `ProviderProfileStore.shared.active` + `apiKey(for:)` |
| Network connectivity | `processWithLLM` calls `NetworkMonitor.shared.checkConnectivity()` (gate #2 from ADR-0003) |

New `assessAndEnhance`:

```swift
private func assessAndEnhance(record: TranscriptionRecord, originalText: String) async {
    switch record.recognitionMode {
    case .online:
        await processWithLLM(recordId: record.id, originalText: originalText)

    case .onDevice:
        if NetworkMonitor.shared.checkConnectivity() {
            await processWithLLM(recordId: record.id, originalText: originalText)
        }
        // offline: do nothing; raw text already saved

    case .failed:
        if NetworkMonitor.shared.checkConnectivity() {
            await retryRecognitionFromFile(recordId: record.id)
        }

    default:
        break
    }
}
```

Same call destinations as before, but no more "if optimizationEnabled".
`.onDevice` loses its `enhanceRecognition` fallback because `processWithLLM`
already overwrites the content with the LLM-optimized version — running
both would be wasted work and risks the LLM overwriting a recognition
upgrade.

### 2. Remove the Settings UI toggle

Delete the entire "优化开关 + 测试连接" `Section` in `SettingsView`
(L40-64 of the file as of 2026-09-24), including the `@State` (L14),
the `Toggle` (L48), and the `onChange` handler (L51-53). The Test
Connection button moves into the Provider profiles section's footer as
a standalone button row.

### 3. Move consent disclosure to Provider creation

`ProfileDetailView.mode == .create` gains a top "数据流向说明" Section
that states, in plain language:

- Configuring a Provider causes transcribed text to be sent to it for
  optimization.
- Raw audio continues to flow only through Apple (on-device or Apple
  Cloud recognition) and is never sent to the AI Provider.
- The user can suppress AI text processing by simply not configuring a
  Provider; in that case recordings are saved with only local recognition
  applied.

The disclosure is intentionally placed **at the consent moment**, not on
every recording.

### 4. Migrate `runLegacyTokenMigration`

Remove the line that sets `audioNote:enableLLMOptimization = false` — the
key is being deleted.

## What's locked (do not change without superseding this ADR)

- **No** new per-recording opt-out toggle, hidden or visible. The consent
  anchor is "did the user configure a Provider?" — full stop.
- The simplified `assessAndEnhance` shape (3 cases, no LLM-on gate).
- The "data flow disclosure" is required copy in `ProfileDetailView` for
  the create mode. Wording can be polished; the three bullets above must
  remain.

## Free to change without new ADR

- The exact wording of the data-flow disclosure (as long as the three
  bullets above remain).
- The localization keys for that disclosure.
- Whether Test Connection is a footer button on the profiles section or
  its own thin section.
- The LLM prompt text itself (`LLMService.optimizeAndProcessPrompt`)
  remains dev-editable as before — ADR-0003 locks "not user-configurable",
  not "frozen".
- Removing the `audioNote:enableLLMOptimization` `UserDefaults` key
  itself (no current readers remain).

## Touch this when

- Someone proposes a per-recording "skip LLM" switch (the answer is no,
  re-anchor consent instead).
- A future feature needs to know whether the user has consented to text
  upload — they check `ProviderProfileStore.shared.active != nil`, not
  a separate flag.
- The 4-field JSON schema changes (already locked by ADR-0002; this ADR
  doesn't affect it).

## Code anchors

| Symbol | Path:line (post-change) |
|---|---|
| Simplified dispatcher | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:236` |
| Disclosure section | `ios/AudioNote/Views/ProfileDetailView.swift` (create mode top) |
| Legacy migration (cleanup) | `ios/AudioNote/Services/ProviderProfileStore.swift:140-152` |

## Test coverage expected

Manual verification checklist (spec §6) — see
`docs/superpowers/plans/2026-09-24-ai-optimization-by-default-plan.md`
Task 4 for the simulator scenarios.

Long-running automated coverage would need to mock `ProviderProfileStore`
+ `NetworkMonitor` + `LLMService`; out of scope for this ADR (consistent
with ADR-0001's "see RISKS, not yet written" note).

## Related

- Spec: `docs/superpowers/specs/2026-09-24-ai-optimization-by-default-design.md`
- Plan: `docs/superpowers/plans/2026-09-24-ai-optimization-by-default-plan.md`
- Sister ADRs: ADR-0001 (assess-and-enhance pipeline — partially
  superseded), ADR-0002 (merged LLM call — preserved), ADR-0003
  (multi-provider LLM — preserved)
- This ADR deprecates: `audioNote:enableLLMOptimization` UserDefaults key
  and the `Settings.LLM.Optimize.*` localization strings.
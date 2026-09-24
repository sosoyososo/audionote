# ADR-0003: Multi-provider LLM (user-managed profiles)

| Field | Value |
|---|---|
| **Status** | ACCEPTED |
| **Date** | 2026-09-24 |
| **Supersedes** | — (locks a new layer; does not supersede ADR-0001 or 0002 outright — see "Relationship to earlier ADRs" below) |
| **Superseded-by** | — |
| **Author** | — |

## Context

Through 2026-09 the LLM path went through `https://llm.karsa.info`, a
private proxy under the project's control. The Settings UI held a single
token in `UserDefaults` (`audioNote:llmToken`). This made the LLM
features unavailable to anyone who did not have access to that proxy
and tied token usage / billing to the project operator.

Goal: let the user point AudioNote at any OpenAI-compatible
`/chat/completions` endpoint (OpenAI / DeepSeek / Groq / Ollama /
LM Studio / …) by configuring an `LLMProviderProfile` in the app. API
keys live in the iOS Keychain, never in `UserDefaults`.

Spec: `docs/superpowers/specs/2026-09-24-multi-provider-llm-design.md`.

## Decision

### Data model

```swift
struct LLMProviderProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var baseURL: URL      // full /chat/completions URL
    var model: String
    var requiresAPIKey: Bool
    var createdAt: Date
}
```

Profiles are stored in `UserDefaults` under `audioNote:llmProfiles` as a
JSON-encoded `[LLMProviderProfile]`. The active profile's UUID lives at
`audioNote:activeLLMProfileId`.

API keys are stored in the Keychain (per profile) via `KeychainStore`:

| Field | Value |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `audioNote.llm` |
| `kSecAttrAccount` | `<profile.id.uuidString>` |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |

Exactly one profile may be `active` at a time. `LLMService` reads
`ProviderProfileStore.shared.active` + `apiKey(for:)` to make calls.

### `LLMService` API

```swift
func optimizeAndProcess(
    _ text: String,
    profile: LLMProviderProfile,
    apiKey: String?
) async throws -> LLMOptimizeAndProcessResult

func ping(profile: LLMProviderProfile, apiKey: String?) async throws
```

The 3 pre-call gates are unchanged from the previous implementation:

1. **Profile completeness** — `profile.isComplete` AND
   `(profile.requiresAPIKey → apiKey non-empty)`. Violations throw
   `LLMError.profileIncomplete` / `.apiKeyRequired`. **Not retried.**
2. **`NetworkMonitor.shared.checkConnectivity()`** — throws
   `.offline`. **Not retried.**
3. **HTTP 2xx** — non-2xx throws `.httpError(code)`. 5xx retried
   (3× exponential backoff, `baseDelay = 1.0s`); 4xx **not retried**.

`optimizeAndProcess` parses the 4-field schema (`optimizedText` /
`title` / `summary` / `tags: [TaggedItem]`), with `extractFirstJSONObject`
as the markdown-fence fallback. **Schema is unchanged** — see "Locked".

### Settings UI

Three-section layout:

1. **Provider profiles** — list of `LLMProviderProfile`, each row
   showing ✓ for active, the URL (truncated middle), and the model.
   Edit via `ProfileDetailView` (sheet). Delete via swipe.
2. **Optimization toggle + test connection** — `LLMService.ping` driven
   from the "Test connection" button.
3. **Status indicator** — shows the active profile name, or a warning
   when none is configured.

### Migration

On first launch after the upgrade, `ProviderProfileStore.runLegacyTokenMigration()`
runs once:

1. If `audioNote:llmToken` is present, remove it.
2. Set `audioNote:enableLLMOptimization = false`.
3. Set `audioNote:llmNeedsProviderSetup = true`.

`SettingsViewModel.init` reads `needsProviderSetup` and surfaces a one-shot
toast (`Settings.LLM.Migration.Toast` localized string), then calls
`acknowledgeNeedsSetup()` so the toast doesn't repeat on subsequent
launches.

## What's locked

- The `LLMProviderProfile` struct shape (renaming a field is a breaking
  change for `UserDefaults` JSON).
- The Keychain layout (`service = "audioNote.llm"`, `account =
  profile.id.uuidString`).
- `LLMService.optimizeAndProcess(text, profile:, apiKey:)` and
  `LLMService.ping(profile:, apiKey:)` public signatures.
- The 4-field JSON schema of `LLMOptimizeAndProcessResult` (per ADR-0002).
- The 3 pre-call gates (profile → network → HTTP).
- The retry policy (3× exponential backoff for 5xx + `.networkError`;
  everything else is not retried).
- The `extractFirstJSONObject` markdown-fence fallback for
  `optimizeAndProcess`.
- Prompt text — **not** user-configurable. Stays as private constants
  inside `LLMService` to keep the 4-field schema intact.
- Exactly one active profile at a time. Multi-profile **with auto
  fallback** is intentionally out of scope.

## Free to change

- The list of localized strings (and their wording).
- The Settings layout (sectioning, row ordering) — as long as profile
  CRUD, active selection, and the test-connection button remain
  reachable.
- Adding new `LLMError` cases without renaming existing ones.
- Adding new fields to `LLMProviderProfile` **only** with a Codable
  migration plan that handles older `UserDefaults` payloads.
- A future "import / export profile bundle" feature.

## Touch this when

- A new field is added to `LLMProviderProfile`.
- A new gate is inserted between profile-completeness and HTTP, or any
  existing gate is removed.
- The Keychain layout changes (service name, accessibility class, …).
- A second public entry point on `LLMService` is added that needs the
  same 3 gates / retry policy.
- Auto-fallback between profiles is being considered — that flips the
  active-profile invariant and needs a separate ADR.

## Relationship to earlier ADRs

- **ADR-0001 (assess-and-enhance pipeline)** — preserved. The 3-case
  dispatch in `TranscriptionViewModel.assessAndEnhance` still routes
  `.online` / `.onDevice` / `.failed` to the same destinations; only
  the `processWithLLM` body was changed (now reads from
  `ProviderProfileStore` instead of `UserDefaults`).
- **ADR-0002 (single merged LLM call)** — partially superseded.
  The endpoint URL assumption is dead (now user-supplied); the merged
  `LLMOptimizeAndProcessResult` 4-field schema and the merged-call
  preference remain **in force** under this ADR.

## Code anchors

| Symbol | Path:line |
|---|---|
| Profile model | `ios/AudioNote/Models/LLMProviderProfile.swift:1` |
| Keychain helper | `ios/AudioNote/Services/KeychainStore.swift:1` |
| Profile store | `ios/AudioNote/Services/ProviderProfileStore.swift:1` |
| `LLMService.optimizeAndProcess` | `ios/AudioNote/Services/LLMService.swift` (new entry point) |
| `LLMService.ping` | `ios/AudioNote/Services/LLMService.swift` |
| Migration call site | `ios/AudioNote/App/AudioNoteApp.swift:7` |
| Caller (auto-enhance) | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` (`processWithLLM`) |
| Caller (manual reprocess) | `ios/AudioNote/Views/TranscriptionDetailView.swift` (`reprocessRecord`) |
| Settings surface | `ios/AudioNote/Views/SettingsView.swift` |
| Edit sheet | `ios/AudioNote/Views/ProfileDetailView.swift` |

## Test coverage expected

Any PR that touches `LLMService` / `ProviderProfileStore` must keep or
extend tests for:

1. `optimizeAndProcess` happy path → returns all 4 fields populated.
2. `optimizeAndProcess` empty profile → throws `.profileIncomplete`.
3. `optimizeAndProcess` requires-APIKey + nil apiKey → throws
   `.apiKeyRequired`.
4. `optimizeAndProcess` offline → throws `.offline`, **no retry**.
5. `optimizeAndProcess` HTTP 5xx → 3 retries then throws `.httpError`.
6. `optimizeAndProcess` HTTP 4xx → 0 retries, throws `.httpError`.
7. `optimizeAndProcess` JSON parse fails → `extractFirstJSONObject`
   fallback; still failing → `.decodingError`.
8. `ping` HTTP 200 → success.
9. `ping` HTTP 401 → `.testConnectionFailed("HTTP 401")`.
10. `runLegacyTokenMigration` three states: no legacy token / legacy
    token present / already migrated.

## Related

- Spec: `docs/superpowers/specs/2026-09-24-multi-provider-llm-design.md`
- Sister ADRs: ADR-0001 (assess-and-enhance pipeline), ADR-0002
  (merged LLM call — schema part preserved)
- Supersedes (informally): any code/docs referencing
  `llm.karsa.info` / `karsa.info` / `audioNote:llmToken` for the LLM
  path. See spec §"过时文档清单" for the canonical list.

# ADR-0002: Single merged LLM call for optimize + process

| Field | Value |
|---|---|
| **Status** | ACCEPTED |
| **Date** | 2026-04-09 |
| **Supersedes** | — |
| **Superseded-by** | — |
| **Author** | — |

## Context

The LLM path had three entry points: `LLMService.process` (title/summary/tags only), `LLMService.optimize` (corrected text only), and `LLMService.optimizeAndProcess` (both, in one API call).

When both `enhanceEnabled` (text optimization) and `processEnabled` (title/summary/tags) are on, the legacy implementation called the API twice — once for `optimize`, once for `process`. Each call is ~1–3 s on a slow network. Halving the round trips mattered on flaky connections and on the user's data-bill.

## Decision

When both flags are on, use **one** `optimizeAndProcess` call. The merged response schema is:

```json
{
  "optimizedText": "...",
  "title": "...",
  "summary": "...",
  "tags": ["...", "...", "..."]
}
```

The single API endpoint stays `POST https://llm.karsa.info/v1/chat/completions`. The prompt is the combined one at `LLMService.swift:218-228` (Chinese-language prompt for optimize+organize).

The legacy two-call path (`callOptimizeAPI` + `callAPI`) is **kept as fallback only**, not the default. New callers MUST go through `optimizeAndProcess`.

## What's locked

- The 4-field JSON response schema. Renaming a field is a breaking change — see Contracts (ROADMAP).
- The endpoint URL. If the server moves, this ADR is superseded.
- The single-call preference when both are enabled. Don't re-introduce the two-call default without a new ADR.
- The merged `LLMOptimizeAndProcessResult` struct at `ios/AudioNote/Services/LLMService.swift:31` — don't split it back into two parallel decode paths.

## Free to change

- The model name (`"deepseek-chat"` in `APIRequest.model`)
- The prompt wording inside `optimizeAndProcess`
- Retry counts (`maxRetries = 3`) and backoff (`baseDelay = 1.0`)
- Adding new fields to `LLMResult` (the legacy single-purpose struct)

## Touch this when

- The LLM provider changes (new endpoint, new auth)
- A 5th field is added to the merged response (then the JSON contract changes)
- The fallback two-call path is needed by a real consumer — then write ADR-0003 to formalize that

## Code anchors

| Symbol | Path:line |
|---|---|
| Merged entry | `ios/AudioNote/Services/LLMService.swift:207` |
| Combined prompt | `ios/AudioNote/Services/LLMService.swift:218-228` |
| Result struct | `ios/AudioNote/Services/LLMService.swift:31` |
| Merged HTTP call | `ios/AudioNote/Services/LLMService.swift:271` |
| Caller (detail view) | `ios/AudioNote/Views/TranscriptionDetailView.swift` |
| Background caller | `ios/AudioNote/Services/AIProcessingService.swift:7` |

## Test coverage expected

Any PR that touches this file MUST keep or extend tests for:
- `optimizeAndProcess` happy path → returns all 4 fields populated
- `optimizeAndProcess` with empty token → throws `LLMError.tokenNotSet`
- `optimizeAndProcess` offline → throws `LLMError.offline`
- HTTP 5xx → retries up to `maxRetries`
- HTTP 4xx → no retry, surfaces error

(Tests not yet present — see RISKS, not yet written.)

## Related

- Spec: `docs/superpowers/specs/2026-04-09-merge-llm-calls-design.md`
- Sister ADRs: ADR-0001 (assess-enhance-LLM pipeline — the upstream dispatcher)
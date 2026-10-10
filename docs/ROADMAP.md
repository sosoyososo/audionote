# ROADMAP — deferred docs, activate when triggered

> This file lists doc types that are **not yet justified** for audionote but may become useful. Each entry has an activation trigger — a concrete signal that means "stop deferring, build it now."

> **Do not** activate any item speculatively. The signal must have happened at least once in real work.

---

## (Retired) "ADR-0003: Skip-empty-transcription" — historical placeholder

> Heading deliberately de-numbered: this placeholder's number collides with the
> real `docs/decisions/0003-multi-provider-llm.md`, which is one of the reasons
> it was retired. Kept as text, not as a heading, so it cannot collide again.

- **Status**: **RETIRED** — superseded in practice by ADR-0005. This was a
  placeholder, never filed as a decision, and its core assumption turned out to
  be false: "empty content means the user said nothing." A recognizer failure
  also produces empty content, and dropping those records is precisely what
  stranded the audio on disk with nothing referencing it. ADR-0005 replaced the
  content check with an explicit split — `PendingRecognitionPolicy.classify`
  discards silent recordings and saves failed ones as `.pending`. The empty-text
  guard that survived is `isLLMEligible`, owned by ADR-0005.
- The number was also already taken by `0003-multi-provider-llm.md`.
- **What it was going to say**: empty/blank transcripts MUST skip both the save
  and LLM paths.
- **Source**: `docs/superpowers/specs/2026-04-09-skip-empty-transcription-design.md`

---

## RISKS doc

- **What**: `docs/RISKS.md` listing known risk items in the format `RISK-NNN: title (severity, status, guardrail, test, search-tag)`.
- **Why deferred**: audionote has no documented "we got bitten by X again" pattern yet. Risks file with 0-2 entries is noise.
- **Activate when**: The same class of bug recurs a **second time** within a month. At that point the pattern is real, write the doc with the original incident + the guardrail that should have caught it.

---

## State machines doc

- **What**: `docs/state-machines/<feature>.md` with mermaid diagram + canonical source path + transition guards.
- **Candidates**:
  - Recording pipeline (already partially covered by ADR-0001)
  - LLM processing status (`llmProcessingStatus`: `nil` → `processing` → `completed` / `failed`)
  - Recognition + retry loop (covered by ADR-0001)
- **Why deferred**: ADR-0001 + code already constrain the main flow. Adding a diagram doc without a recurring bug is duplication.
- **Activate when**: An agent gets the **transition table wrong** — e.g., tries to transition `failed → processing` directly, or skips `processing` entirely. That's when the diagram earns its keep.

---

## Contracts doc

- **What**: `docs/contracts/` with schema/version files for cross-process contracts.
- **Candidates**:
  - `TranscriptionRecord` JSON schema (currently versioned implicitly — no `schemaVersion` field)
  - `LLMOptimizeAndProcessResult` JSON schema (4-field response shape)
  - `LLM API` request/response (server-side, but the iOS side pins the prompt format)
- **Why deferred**: No external consumer depends on these yet. Adding version fields speculatively is premature.
- **Activate when**: Either (a) we ship a Mac/web companion that reads the same JSON, or (b) we change the `LLMOptimizeAndProcessResult` schema and need a compat matrix to track who depends on which version.

---

## DOMAIN-MAPS

- **What**: Per-domain "enter here" file. E.g., `docs/domains/recording.md` listing the 3 files to read first + 3 to touch with care.
- **Why deferred**: audionote has 7 services + 2 VMs — small enough that `codegraph_explore "<term>"` plus CLAUDE.md already gives the entry point.
- **Activate when**: The project grows past ~15 services / VMs, OR an agent repeatedly starts from the wrong file (e.g., edits `RecordingView` when the bug is in `TranscriptionViewModel`).

---

## docs/README.md (meta-doc)

- **What**: A `docs/` root README that lists every doc + when to read it.
- **Status**: **DECIDED NO.** Replaced by the pointer list in `CLAUDE.md`. Agents don't browse directories; they read their entry file.
- **Re-open only if**: A new human collaborator joins who prefers browsing — then a 1-page map can be added at `docs/README.md` with a 5-line "what lives here".

---

## Format

When activating any item:
1. Write the doc following the **same locked-table format** as ADR-0001 (for ADRs) or the search-tag format proposed for RISKS.
2. Cross-link from `CLAUDE.md` under "Architecture docs".
3. Update this ROADMAP: move the entry to a "Activated" section at the bottom.

When an entry is "Activated", it stops being optional.
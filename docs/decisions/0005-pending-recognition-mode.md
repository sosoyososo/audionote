# ADR-0005: Pending recognition mode

| Field | Value |
|---|---|
| **Status** | ACCEPTED (2026-10-10; implementation at `759276a`) |
| **Date** | 2026-10-10 |
| **Supersedes** | — (retires the ROADMAP's *ADR-0003: Skip-empty-transcription* **placeholder**, which was never filed as a decision) |
| **Superseded-by** | — |
| **Author** | — |

## Context (one paragraph)

A recording whose recognizer failed used to leave its audio on disk with nothing
pointing at it: `stopRecording` dropped the record whenever the transcript was
empty, so a recognizer failure and genuine silence were indistinguishable and the
`.m4a` was stranded. Two further facts emerged while fixing this, both of which
the original plan predated:

1. **The recording could be refused up front.** Offline with a locale that has no
   downloaded on-device model — the common `zh-CN` case — the recognition request
   failed immediately, and the user heard about it only after talking, by which
   time the audio was on disk and about to be discarded. `SFSpeechRecognizer`
   exposes exactly this as `supportsOnDeviceRecognition`; the pre-existing code
   set `requiresOnDeviceRecognition = true` and never consulted it.

2. **A record's "hand-edited" marker did not exist, and its absence was a data
   loss.** `updateRecord` carried `optimizedContent` forward rather than writing
   it. A pending record has empty `content` and `nil optimizedContent`, so after
   the user typed into the detail page both were still empty-or-nil, the
   `optimizedContent != content` rule could not fire, and the next network
   recovery overwrote what they wrote. Worse, the LLM sweep resolved its input as
   `optimizedContent ?? content` — which, once the marker *did* start meaning
   "pre-edit text", sent the user's *pre-edit* text to the model and wrote the
   answer back over their work. That was a real HIGH, found during
   implementation, and it is why `optimizedContent` is now overloaded.

## Decision

Introduce `RecognitionMode.pending` — audio exists, transcript does not — plus a
`PendingRecognitionPolicy` namespace holding the pure decisions that decide a
finished recording's fate, gate the recovery queues, and derive the hand-edit
marker. `classify` splits "the user said nothing" from "the recognizer died":
empty text with no error is still discarded, empty text **with** an error is
saved as `.pending`.

```
.online   → LLM
.onDevice → LLM (if online)  || enhanceRecognition (if online)
.failed   → retryRecognitionFromFile (if online)
.pending  → retryRecognitionFromFile (if online)   [never the LLM]
```

There is no per-recording LLM toggle. ADR-0004 deleted `enableLLMOptimization`,
and `processWithLLM` now gates only on an active provider profile plus
connectivity. ADR-0001's table still shows "(if optimize-on)" and is stale on
that point; the switch above is the current behaviour.

`networkDidRecover` drains two filtered queues rather than raw record lists:
`llmQueue` (steps 1 and 4) and `recognitionRetryQueue` (step 3).

## What's locked (do not change without superseding this ADR)

- The four-arm dispatch shape in `assessAndEnhance`. Adding a fifth
  `RecognitionMode` case extends this switch — this is ADR-0001 §30 restated
  with the arm it required.
- **A `.pending` record MUST be excluded from every LLM path.** Its `content` is
  empty, and an empty string sent to a model comes back a confident invented
  title, summary and tags, which are written over the record.
- **`optimizedContent` is overloaded.** It now means *both* "the LLM wrote this"
  and "the user wrote this by hand". It cannot tell them apart, and
  `TranscriptionRecord` may not gain a field to distinguish them. Consequences
  that must survive:
  - The 优化后 badge is gated on `llmProcessingStatus == .completed` and **must
    not** be gated on `isHandEdited` — that predicate is true for essentially every
    LLM-processed record (all but the edge case where the model's output equalled
    its input), so it would hide the badge from exactly the records it exists for.
  - LLM input must resolve through `PendingRecognitionPolicy.llmInputText(for:)`,
    never a bare `optimizedContent ?? content`. That bare idiom is what sent the
    pre-edit text to the model.

  **Any change to what `optimizedContent` means MUST enumerate every site that
  reads it.** This feature shipped one data-loss bug exactly this way: the
  meaning widened underneath three call sites that were each individually correct
  under the old meaning.
- **A record the user has taken over is never touched by an automatic pass** —
  not recognition, not the LLM. Manual routes (`reRecognizeOnline`, `retryLLM`,
  `reprocessRecord`) may still run, on the user's own text, because the user
  asking for an overwrite is the case where an overwrite is what they want.
- **A hand-edited record may carry *any* `llmProcessingStatus`, including
  `.failed`.** `updateRecord` derives the marker independently of status and
  must keep doing so — a status is not evidence of who wrote the text. This is
  reachable in three taps today: a record whose LLM pass failed, the user opens
  it and taps the pencil (`saveEditing` passes `llmProcessingStatus` straight
  through, and the button is not gated on it), and the edit lands.

  **This is why `llmQueue`'s hand-edit filter is load-bearing, not
  belt-and-braces.** `networkDidRecover` step 4 retries every `.failed` record,
  sending its text to the LLM and letting `processWithLLM` write the answer over
  `content`. For a hand-edited record that is the exact HIGH this feature
  shipped: the user reconnects and their text is replaced. Excluding it is the
  locked decision doing real work, for a state that exists in the wild.

  The narrower claim that *is* true, and worth keeping: **no `processWithLLM`
  failure branch writes `optimizedContent`.** Its sole assignment in that
  function is in the success branch, which also sets `.completed`. So a failure
  never manufactures a marker; only a later hand edit does.

  **The trap is symmetric and worse than the mistake it replaces.** An agent who
  believes a `.failed` record never carries a diverged marker, and "enforces"
  that in `updateRecord` by stripping the marker when status is `.failed`,
  re-arms the original data loss — the edit looks protected at the moment it is
  being unprotected. This invariant is not a target to enforce. It is a
  consequence of *who writes the field*, and the writer is status-independent by
  design.
- **A hand-edited pending record keeps `recognitionMode == .pending`.** Advancing
  it would be a new `RecognitionMode` case, which ADR-0001 §30 makes locked. The
  visible cost is accepted: the detail page shows the 待识别 badge above text the
  user supplied. The list is unaffected — `rowTitle` / `rowSummary` return the
  user's text.
- `llmInputText(for:)` always returns `record.content`. This is provable, not
  incidental: `isHandEdited` true → `content`; false → either `optimizedContent
  == nil` (so `?? content` yields `content`) or `content == optimizedContent`
  (so it yields a string equal to `content`). No record makes it return
  anything else.

  It is kept anyway, deliberately. The idiom it replaces reads as the obviously
  correct thing to do, is correct only while `optimizedContent` holds nothing but
  a pre-LLM original, and fails silently. Five bare `record.content` reads would
  each be correct and would carry no statement of *why* the obvious idiom is
  wrong; the first reader to "fix" one reopens the HIGH. **If it is ever reduced
  to identity, delete it deliberately** — and say why in the commit — so the note
  is what survives, not just the function.

## Free to change without new ADR

- The UI wording of the 待识别 badge, its icon, and its colour
- Which locales `shouldRefuseToRecord` ends up refusing. It takes no language
  argument: it asks whether *the recognizer's current locale* has a downloaded
  on-device model. `zh-CN` is the case this was found on, not a hardcoded list,
  so adding a locale is a matter of the user downloading its model, not a code
  change.
- The order and count of the four `networkDidRecover` steps, provided each still
  draws from its filtered queue
- The `Outcome` type in `PendingRecognitionPolicy` (add cases freely; `classify`
  is the only writer)
- The prompt, provider, or response schema used by `LLMService` (ADR-0002 /
  ADR-0003 own those)

## Touch this when

- A new `RecognitionMode` case is added — it needs a fifth `assessAndEnhance` arm
  **and** a decision about which recovery queue admits it
- Someone proposes adding a field to `TranscriptionRecord` to distinguish LLM
  edits from hand edits. That is the clean fix for the overload above; it is a
  schema change and needs its own decision (see ROADMAP → Contracts).
- `optimizedContent` is added to, removed from, or re-purposed anywhere
- A new LLM call site is added. Two things are required at it: route input
  through `PendingRecognitionPolicy.llmInputText(for:)` and vet it with
  `isLLMEligible`. `TranscriptionDetailView.reprocessRecord` is the second route
  into `LLMService.optimizeAndProcess` and bypasses `processWithLLM` entirely —
  an audit of "where is empty text kept out of the LLM?" has to find both.
- A `processWithLLM` failure branch is added. Read *What's locked* first.

## Code anchors

All verified against the working tree as of this commit. The
`PendingRecognitionPolicy.swift` anchors account for the expanded `llmQueue`
doc comment landed in the same change that corrected the invariant below; the
code beneath it is unchanged since `759276a`.

| Symbol | Path:line |
|---|---|
| `RecognitionMode.pending` | `ios/AudioNote/Models/TranscriptionRecord.swift:19` |
| `optimizedContent` field | `ios/AudioNote/Models/TranscriptionRecord.swift:50` |
| Offline gate (refuse to record) | `ios/AudioNote/Services/PendingRecognitionPolicy.swift:330` |
| Gate call site | `ios/AudioNote/Services/SpeechRecognizer.swift:137` |
| `PendingRecognitionPolicy.Outcome` | `ios/AudioNote/Services/PendingRecognitionPolicy.swift:25` |
| `classify` (discard vs `.pending`) | `ios/AudioNote/Services/PendingRecognitionPolicy.swift:54` |
| `classify` call site | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:203` |
| LLM-queue filter (excludes `.pending`) | `ios/AudioNote/Services/PendingRecognitionPolicy.swift:136` |
| Recognition-retry-queue filter | `ios/AudioNote/Services/PendingRecognitionPolicy.swift:158` |
| Hand-edit predicate | `ios/AudioNote/Services/PendingRecognitionPolicy.swift:192` |
| LLM input resolution | `ios/AudioNote/Services/PendingRecognitionPolicy.swift:225` |
| Hand-edit marker derivation | `ios/AudioNote/Services/PendingRecognitionPolicy.swift:250` |
| Empty-text guard (pre-dates this ADR) | `ios/AudioNote/Services/PendingRecognitionPolicy.swift:300` |
| Dispatcher | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:261` |
| `.pending` switch arm | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:283` |
| `enhanceRecognition` hand-edit guard | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:313` |
| `retryRecognitionFromFile` | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:362` |
| `processWithLLM` (the LLM choke point) | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:416` |
| Success: writes `optimizedContent` + `.completed` | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:473`, `:478` |
| Failure branches: `.failed`, marker untouched | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:459`, `:516`, `:527`, `:535` |
| `networkDidRecover` | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:542` |
| LLM input resolved at steps 1 and 4 | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:550`, `:573` |
| `retryLLM` (manual route) | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:592` |
| Marker write on update | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:672` (`optimizedContent: marker` itself at `:689`) |
| `saveEditing` — passes `llmProcessingStatus` through, no marker | `ios/AudioNote/Views/TranscriptionDetailView.swift:540`, `:552` |
| `updateRecord` | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:649` |
| Manual LLM route (bypasses `processWithLLM`) | `ios/AudioNote/Views/TranscriptionDetailView.swift:444`, `:478` |
| `llmCandidateText` | `ios/AudioNote/Views/TranscriptionDetailView.swift:341` |
| 优化后 badge, gated on `.completed` | `ios/AudioNote/Views/TranscriptionDetailView.swift:188` |
| Retry button → `llmInputText` | `ios/AudioNote/Views/RecordingView.swift:284` |

The five sites that resolve LLM input through `llmInputText(for:)`:
`TranscriptionViewModel.swift:550`, `:573`, `:592`;
`TranscriptionDetailView.swift:448` (via `llmCandidateText`, `:341`);
`RecordingView.swift:284`.

## Test coverage

**37** tests in `ios/AudioNoteTests/PendingRecognitionTests.swift`, **106** in the
full suite. The policy functions are pure statics precisely so they are reachable
from a unit test — `TranscriptionViewModel` wires its collaborators as `private
let` singletons and `SpeechRecognizer` constructs `SFSpeechRecognizer` directly,
so neither can be instantiated with a controlled environment.

Covered: `classify`'s discard / `.pending` split; `shouldRefuseToRecord`'s truth
table; both queue filters; `isHandEdited`'s two halves; `handEditMarker`'s three
precedence terms; `llmInputText` on hand-edited, LLM-processed and untouched
records; `isLLMEligible`'s whitespace cases.

**One claim is documented but NOT tested:** that no `processWithLLM` failure
branch writes `optimizedContent`. There is no seam on `processWithLLM` — it
reaches `ProviderProfileStore`, `NetworkMonitor` and `LLMService` through
`private let` singletons — so its failure branches cannot be exercised from a
unit test today. It currently rests on reading the source. Do not infer coverage
that does not exist; if that seam is ever added, asserting this belongs with it.

Note what is **not** untested, because an earlier draft of this ADR got it
backwards: the reachability of "`.failed` and hand-edited at once" is not an
untested invariant to be maintained — it is a real state produced by
`handEditMarker` and `saveEditing`, both directly testable, and the queue
filter that excludes it is covered by the queue-filter tests above.

## Related

- Extends **ADR-0001** (`assess-enhance-llm-pipeline`), whose §30 required the new
  switch arm this ADR's dispatch shape is built around. **ADR-0001's own
  `file:line` anchors are stale** — they predate Tasks 1–6 and point at shifted
  line numbers (its dispatcher anchor, `:233`, is now the `TranscriptionRecord(`
  construction inside `stopRecording`). Its *rules* remain correct; its line numbers and its
  "(if optimize-on)" table do not. Use the anchors in this file.
- Sits alongside **ADR-0004** (`ai-optimization-by-default`) — distinct topics,
  do not merge them
- Supersedes in practice the ROADMAP's retired *"ADR-0003:
  Skip-empty-transcription"* **placeholder**, whose core assumption this feature
  falsified: empty content means the user said nothing. A recognizer failure also
  produces empty content, and dropping those records is precisely what stranded
  the audio. (The placeholder's number also collided with the real
  `0003-multi-provider-llm.md`.)
- Design spec: `docs/superpowers/specs/2026-10-03-pending-recognition-design.md`
  — written before this ADR was numbered, and it refers to this decision as
  "ADR-0004". That line is a point-in-time record and is deliberately left
  unchanged; this file is the authority on numbering.

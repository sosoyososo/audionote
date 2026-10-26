# ADR-0006: A launch-time recovery sweep, and what a background sweep may do to the UI

- **Status:** Accepted
- **Date:** 2026-10-22
- **Spec:** `docs/superpowers/specs/2026-10-22-launch-recovery-sweep-design.md`
- **Plan:** `docs/superpowers/plans/2026-10-22-launch-recovery-sweep-plan.md`
- **Supersedes:** nothing
- **Amends:** ADR-0005 (the recovery sweep now has a second trigger)

## Context

`networkDidRecover` is the app's only recovery trigger. It fires when the
network transitions from disconnected to connected, and it drains two
queues: `llmQueue` (records whose LLM pass never ran, or failed) and
`recognitionRetryQueue` (records with audio on disk and no transcript).

A trigger that only fires on a *network transition* has a hole in it. A
record stranded by a previous session — the user recorded with the
network off, the app was killed before the transcript landed — sits in
`recognitionRetryQueue` and stays there until the user happens to
toggle the network during a later session. Relaunching the app with a
working network did nothing at all. The data was on disk the whole
time and the app never looked at it.

The trigger is also the wrong *kind* of trigger. A recovery sweep is
housekeeping: nobody is waiting for it, and it should not need a network
transition to be allowed to run.

The launch sweep is the missing trigger. But a sweep that runs without
the user asking for it raises three questions the network sweep never
had to answer: how much may it spend, what must it not touch, and what
may it do to the interface while it runs.

## Decision

### 1. The launch sweep runs steps 1, 3 and 4 — not step 2

Step 2 upgrades on-device recognitions to online recognition. That is an
*improvement*, not a recovery: an on-device record already has a
transcript, and it is not stranded. Running step 2 at launch would put
an online recognition request on every launch, for records that are
fine.

Steps 1, 3 and 4 are the recovery work, and they are exactly the two
queues ADR-0005 already defines.

### 2. Both sweeps draw their candidates from one function

`PendingRecognitionPolicy.recoveryCandidates(from:llmLimit:)` is the
only place that decides what a recovery sweep acts on. The launch sweep
and the network-recovery sweep both call it.

Two sweeps that computed their own candidates would drift, and the
drift would be invisible: the network sweep would keep looking right
while the launch sweep quietly skipped (or double-processed) something.
The shared function is what makes "the two sweeps cannot drift" a
property of the code rather than a habit.

The LLM pool is `llmQueue` records whose status is `nil`, `.failed` or
`.processing`. `.pending` records are excluded by `llmQueue` itself, as
ADR-0005 requires.

### 3. `.processing` is a terminal status, so the sweep must take it

A record whose LLM call was interrupted — the app was killed between
writing `.processing` and writing the outcome — has a status that no
queue in the app will ever move again. Left out of the pool, that
record's title and summary would never be filled in.

Including it is safe: the `isHandEdited` exclusion already covers the
case where the LLM call actually succeeded and only the status write was
lost, because such a record has `optimizedContent` set.

### 4. The launch sweep's LLM work is capped; the network sweep's is not

`PendingRecognitionPolicy.launchLLMLimit` is **10 records per launch**,
counting steps 1 and 4 together. The cap is a budget for the sweep, not
a budget per bucket.

The launch sweep is unattended, so its cost has to be bounded — 10
records is 10 API calls that nobody is watching happen.

The network-recovery sweep stays uncapped. The user is present for it,
and a backlog they are waiting on should clear in one go. Capping it
would mean toggling the network once per batch, which is worse than the
problem it solves.

The cap sorts **oldest first**: the records that have been waiting
longest go first, and the ones the cap skips are the most recent — the
ones the user is most likely to still care about, and most likely to be
picked up by the next launch anyway.

The cap does **not** bound `recognitionRetry`. Re-recognition is
Apple's speech service, not a paid API, and ADR-0005 §4.6 requires
retries to be unlimited.

### 5. A sweep may not run against storage that is not ready

The sweep requires `StorageCoordinator.state == .ready`. A
`.unreachable` state can leave a stale `resolvedRoot` behind, and
recovering against a folder the user is no longer using is worse than
not recovering at all (ADR-0007).

### 6. Two sweeps may not overlap

The launch sweep can still be in flight when the network comes back and
the network sweep starts. The same record processed twice means two
LLM calls and two writes, so a sweep that is already running refuses
to start.

### 7. A background sweep must not take the UI's "you are waiting" signal

`processWithLLM` is the single LLM choke point, so a sweep sets
`isLLMProcessing` and `llmProcessingFailed`. Those are UI signals
meaning "you asked for this, here is the outcome" — but they are
**global, not per record**. A sweep processing record #37 would replace
the recording screen's transcript area with a spinner about somebody
else's record, and replace the detail view's LLM button with a
disabled one. The app would be reporting its own housekeeping as the
user's request.

The views therefore read `isAwaitingUserLLMResult` and
`hasUserFacingLLMFailure` rather than the raw flags. A background
sweep's failures are not swallowed — the flag is sticky, so they
surface once the sweep ends.

The detail view's button stays disabled while the view model is busy,
because that is a *correctness* gate and not a feedback signal: it
stops the user from firing a second LLM call for a record the sweep is
already working on.

### 8. The sweep is triggered by the storage becoming ready

Not by a timer, and not by the view appearing. "Ready" is the only
moment the records are actually loadable, and it covers the case a
timer would miss: the user reinstalls the app, picks the same folder,
and the records stranded in it recover right then.

`removeDuplicates()` on the state publisher matters: `bootstrap()` can
run twice (the view's `onAppear` and `loadHistory` both call it), and
two sweeps would process two batches of records per launch instead of
one.

## Consequences

- A record stranded by a previous session recovers on the next launch,
  with no user action.
- A launch can cost at most 10 LLM calls. Re-recognition is still
  unlimited.
- The network-recovery sweep behaves exactly as before: the same
  records, in the same order, with no cap.
- The recording screen no longer shows "正在处理…" while a recovery
  sweep runs. That is a behaviour change, and it is the intended one —
  see rule 7.
- **Known limitation.** The candidate list is a snapshot taken at the
  start of the sweep. If the user edits a record while the sweep is
  processing an earlier one, the sweep's write can land on the
  pre-edit text. This window is one LLM call wide and it is
  pre-existing: the network-recovery sweep has the same property.

## Alternatives rejected

- **Trigger the sweep on every `ContentView` appearance.** It would
  re-run the sweep on every tab switch and every language change.
- **Give the launch sweep its own candidate function.** Two functions
  means two definitions of "stranded", and they would drift.
- **Cap the network-recovery sweep too.** The user is waiting for it;
  making them toggle the network once per batch to clear a backlog is
  a worse failure than the unbounded burst.
- **Let the launch sweep run step 2 as well.** Every launch would then
  carry an online recognition request for records that are not stranded.
- **Write a separate background LLM path instead of reusing
  `processWithLLM`.** The duplication would have to re-implement the
  guards, the error handling and the status writes — and the
  duplication is exactly what let the last three bugs through.

## Verification

- `ios/AudioNoteTests/LaunchRecoverySweepTests.swift` — 12 tests
  covering the three-way split, the `.pending` exclusion, the
  hand-edit exclusion, the `.processing` recovery, the network-sweep
  regression guarantee (same records, same order), the cap (count,
  direction, and that it spans both buckets), and that the cap does not
  bound re-recognition.
- Full suite: 219 tests, 0 failures.
- Red-verified: breaking the sort direction, the cap, and the
  `.processing` inclusion fails 6 of the 12 new tests.

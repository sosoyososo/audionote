# Pending Recognition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop flight-mode recordings from being silently dropped — block the recording up front when the language has no offline model, and persist any record that has audio but no transcript so it can be recovered when the network returns.

**Architecture:** Add a `RecognitionMode.pending` enum case (not a new field, so no migration) for "audio exists, no transcript". Extract the two load-bearing decisions into pure static functions — `PendingRecognitionPolicy.classify` and `PendingRecognitionPolicy.recoveryQueue` — so they are unit-testable without touching the singleton-wired view model. The existing recovery pipeline (`networkDidRecover` → `retryRecognitionFromFile` → `processWithLLM` → `relatedNotesService.link`) is reused unchanged.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 15+ deployment target, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-03-pending-recognition-design.md` — the plan argues from the spec, so the spec travels with it; executors read both.

## Global Constraints

- **Any online call (LLM, online recognition) MUST be gated by `NetworkMonitor.shared.checkConnectivity()` first.** No exceptions. (Project CLAUDE.md locked decision.)
- **`assessAndEnhance`'s dispatch shape is locked by ADR-0001.** Adding `RecognitionMode.pending` REQUIRES a new switch arm in that function, and a new ADR at `docs/decisions/0004-pending-recognition-mode.md` whose initial `Status` is `PROPOSED`.
- **`TranscriptionRecord` gains no new fields.** `RecognitionMode` is an enum; adding a case does not change the stored shape, and `Codable` synthesis is unaffected — no migration.
- **Writes go through the `TranscriptionStorage` class.** Never write the record JSON directly.
- **New storage files hang off `StorageCoordinator`'s derived properties.** Do not construct URLs by hand. (This plan adds no new storage files.)
- **Every user-facing string goes in both `zh-Hans.lproj/Localizable.strings` and `en.lproj/Localizable.strings`** with identical keys.
- **`xcodegen generate` must be run after adding any new file**, and it must exit 0. A non-zero exit means a stale `project.pbxproj` silently survives.
- Deployment target is iOS 15.0. Swift 5.9.

### Commands (run from `ios/`)

```sh
# Regenerate the Xcode project after adding files
xcodegen --spec project.yml

# Build — simulator
xcodebuild -scheme AudioNote -sdk iphonesimulator \
           -destination 'generic/platform=iOS Simulator' build

# Run unit tests — iPhone Air simulator twin
xcodebuild test -scheme AudioNote \
           -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722'

# Run a single suite (faster inner loop)
xcodebuild test -scheme AudioNote \
           -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
           -only-testing:AudioNoteTests/PendingRecognitionTests

# Install + launch on the real device (iPhone Air)
xcodebuild -scheme AudioNote \
           -destination 'platform=iOS,id=3C0B7BE4-2AEF-54E4-B937-9A0C96326420' build
xcrun devicectl device install app \
           --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 \
           ~/Library/Developer/Xcode/DerivedData/AudioNote-*/Build/Products/Debug-iphoneos/AudioNote.app
xcrun devicectl device process launch \
           --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 info.karsa.app.ios.audionote
```

`devicectl` may print `Failed to load provisioning parameter list … No provider was found` on success — benign.

## File Structure

| File | Responsibility |
|---|---|
| `ios/AudioNote/Models/TranscriptionRecord.swift` (modify) | Add `RecognitionMode.pending` case. Nothing else. |
| `ios/AudioNote/Services/PendingRecognitionPolicy.swift` (create) | **All the decision logic, as pure static functions.** No state, no singletons, no I/O — this is what makes the fix unit-testable given the view model's hard singleton wiring. |
| `ios/AudioNote/Services/SpeechRecognizer.swift` (modify) | Gate `startRecording` on `supportsOnDeviceRecognition`; finish the `AsyncStream` on error; new `SpeechRecognitionError` case. |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` (modify) | `stopRecording` persists instead of discarding; `assessAndEnhance` gains the `.pending` arm; `networkDidRecover` delegates filtering to the policy. |
| `ios/AudioNote/Views/SharedComponents.swift` (modify) | `RecognitionModeStyle` gains a `.pending` arm. |
| `ios/AudioNote/Views/LibraryListView.swift` (modify) | `displayTitle` / `displaySummary` fallbacks for empty content. |
| `ios/AudioNote/Views/TranscriptionDetailView.swift` (modify) | `.pending` in the upgrade-button condition; placeholder in `contentSection`. |
| `ios/AudioNote/Resources/{zh-Hans,en}.lproj/Localizable.strings` (modify) | Four new keys each. |
| `ios/AudioNoteTests/PendingRecognitionTests.swift` (create) | All tests for this feature. |

**Why a separate `PendingRecognitionPolicy` file:** `TranscriptionViewModel` is `@MainActor` with `private let speechRecognizer = SpeechRecognizer()` and `private let storage = TranscriptionStorage.shared` — no injection point, and the existing test suite never instantiates it. `SpeechRecognizer` likewise builds `SFSpeechRecognizer` directly. Testing the two decisions that actually matter through those types would mean a dependency-injection refactor of the whole view model, which is far larger than this bug. Extracting them as pure functions gets the same coverage for ~40 lines of new file. This is the same move the related-notes plan made with `RelatedNotesService.prescreen`.

## Review Focus

Five input classes a reasonable user would exercise that the happy path won't cover. Each has a test pinned to the task that owns the code.

1. **The user genuinely recorded silence** (held the button, said nothing, recognizer reported no error). The record must be discarded — a "待识别" row for a silent recording is a lie about data the user cares about. → Task 2 test.
2. **A pending record whose audio file the user deleted from the Files app folder.** The retry must not crash. Note: `recognitionRetryQueue`'s `audioFileName != nil` guard does **not** cover this case — the name is still set, only the file is gone, so `retryRecognitionFromFile` hits its `guard` and returns silently on every sweep, and the record stays pending forever with no explanation in the UI. **This is accepted for now (spec §5) and is not fixed by this plan**; it is called out here so it is not mistaken for covered behaviour. If it becomes annoying in practice, the fix is a "audio missing" state in the detail page, which is a separate change.
3. **A record created by a pre-upgrade build** — its JSON has no `recognitionMode` key at all. It must decode to `nil` and be picked up by the recovery sweep, not silently skipped. → Task 1 test.
4. **A pending record with an empty `content` reaches the LLM.** The `optimizeAndProcess` call fires with `""`, and the LLM invents a summary. This is the exact hallucination the 2026-04-09 skip-empty spec exists to prevent, and the `.pending` exclusion is the only thing standing between the new record type and it. → Task 3 test, with mandatory teeth verification.
5. **The user edits a pending record's text by hand** before the network returns. The recovery sweep must not overwrite their edit with a re-recognized transcript. This turned out to need a code change, not just a test: `updateRecord` never wrote the `optimizedContent` marker that the "user edited this" rule depends on, so the guard could not fire at all. → Task 6.

---

### Task 1: `RecognitionMode.pending` + Codable round-trip

**Files:**
- Modify: `ios/AudioNote/Models/TranscriptionRecord.swift:3-8`
- Test: `ios/AudioNoteTests/PendingRecognitionTests.swift` (create)

**Interfaces:**
- Consumes: nothing
- Produces: `enum RecognitionMode` gains `case pending` (raw value `"pending"` via `String`-backed `Codable`). Later tasks use `.pending` in filters, switches, and UI.

- [ ] **Step 1: Write the failing test**

Create `ios/AudioNoteTests/PendingRecognitionTests.swift`:

```swift
import XCTest
@testable import AudioNote

/// Tests for the `RecognitionMode.pending` state — "audio exists, no
/// transcript, waiting for the network". Spec §4.3.
///
/// The state itself is covered here; the *decisions* about it live in
/// `PendingRecognitionPolicy` and are covered in Tasks 2 and 3.
final class PendingRecognitionTests: XCTestCase {

    // MARK: - Enum + Codable

    func testPendingRawValueRoundTrips() throws {
        // The raw value is what lands in the user's JSON. If it ever
        // changes, every pending record already on disk fails to decode
        // and is silently dropped — exactly the bug this feature fixes.
        XCTAssertEqual(RecognitionMode.pending.rawValue, "pending")

        let encoded = try JSONEncoder().encode(RecognitionMode.pending)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"pending\"")

        let decoded = try JSONDecoder().decode(RecognitionMode.self, from: encoded)
        XCTAssertEqual(decoded, .pending)
    }

    func testLegacyRecordWithoutRecognitionModeStillDecodes() throws {
        // Review focus #3: a record written by a pre-upgrade build has no
        // `recognitionMode` key. It must decode to nil rather than throwing,
        // or every pre-existing record becomes unreadable on upgrade.
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "content": "旧版本的记录",
          "createdAt": 1700000000
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TranscriptionRecord.self, from: legacyJSON)
        XCTAssertNil(record.recognitionMode)
        XCTAssertEqual(record.content, "旧版本的记录")
    }

    func testPendingRecordRoundTripsThroughFullRecordJSON() throws {
        // The enum case surviving is not enough — the whole record must
        // round-trip, since that is the shape `TranscriptionStorage` writes.
        let record = TranscriptionRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            content: "",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            duration: 42,
            audioFileName: "22222222-2222-2222-2222-222222222222.m4a",
            recognitionMode: .pending
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TranscriptionRecord.self, from: data)

        XCTAssertEqual(decoded.recognitionMode, .pending)
        XCTAssertEqual(decoded.content, "")
        XCTAssertEqual(decoded.duration, 42)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
xcodegen --spec project.yml
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: `testPendingRawValueRoundTrips` and `testPendingRecordRoundTripsThroughFullRecordJSON` FAIL to compile — `RecognitionMode.pending` does not exist. The legacy test should pass.

- [ ] **Step 3: Add the enum case**

In `ios/AudioNote/Models/TranscriptionRecord.swift`, change lines 3-8 from:

```swift
enum RecognitionMode: String, Codable {
    case online
    case onDevice
    case enhanced
    case failed
}
```

to:

```swift
enum RecognitionMode: String, Codable {
    case online
    case onDevice
    case enhanced
    case failed
    /// Audio exists but no transcript was produced — the recognizer
    /// reported an error and returned nothing. Distinct from `.failed`,
    /// which means a retry already happened and also came back empty.
    /// Spec §4.3.
    ///
    /// Enqueued by `PendingRecognitionPolicy.recoveryQueue` and drained by
    /// `networkDidRecover` step 3. It is deliberately NOT enqueued by
    /// `PendingRecognitionPolicy.llmQueue` — a pending record has empty
    /// `content`, and feeding "" to the LLM produces a hallucinated
    /// summary. That exclusion is the whole reason this case exists
    /// separately from nil.
    case pending
}
```

- [ ] **Step 4: Run the test to verify it passes**

```sh
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```sh
git add ios/AudioNote/Models/TranscriptionRecord.swift ios/AudioNoteTests/PendingRecognitionTests.swift
git commit -m "feat(recognition): add RecognitionMode.pending for un-transcribed audio

An enum case, not a new field, so the stored shape is unchanged and no
migration is needed. Distinguishes 'has audio, no transcript' from
'.failed', which means a retry already happened and also came back
empty."
```

---

### Task 2: `PendingRecognitionPolicy.classify` — don't discard what the user said

**Files:**
- Create: `ios/AudioNote/Services/PendingRecognitionPolicy.swift`
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:209-214`
- Test: `ios/AudioNoteTests/PendingRecognitionTests.swift` (append)

**Interfaces:**
- Consumes: `RecognitionMode.pending` (Task 1)
- Produces:
  ```swift
  enum PendingRecognitionPolicy {
      enum Outcome: Equatable {
          case discard                 // silence — no record, no audio saved
          case save(RecognitionMode)   // persist with this mode
      }
      static func classify(hasRecognitionError: Bool,
                           trimmedContent: String) -> Outcome
  }
  ```
  Task 3 adds `recoveryQueue` / `llmQueue` to the same enum.

- [ ] **Step 1: Write the failing test**

Append to `ios/AudioNoteTests/PendingRecognitionTests.swift`, inside the existing class (before its closing brace):

```swift
    // MARK: - classify()

    func testClassifyDiscardsWhenUserWasActuallySilent() {
        // Review focus #1. No error and no text = the user said nothing.
        // Saving this would put a "待识别" row in their list for a
        // recording with no content, and the 2026-04-09 skip-empty spec
        // exists precisely to avoid feeding meaningless records onward.
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: false, trimmedContent: ""),
            .discard
        )
    }

    func testClassifyDiscardsWhitespaceOnlyContentEvenWithError() {
        // Same reasoning: a string of spaces is not a transcript. This is
        // why the caller passes a *trimmed* string.
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: true, trimmedContent: "   \n\t "),
            .discard
        )
    }

    func testClassifySavesPendingWhenRecognizerFailedButUserSpoke() {
        // The bug being fixed. `hasRecognitionError == true` with no text
        // means the recognizer died — the user may well have spoken, and
        // the audio is on disk. Discarding it is what stranded the .m4a
        // with no record pointing at it.
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: true, trimmedContent: ""),
            .save(.pending)
        )
    }

    func testClassifySavesRecognizerModeWhenThereIsText() {
        // A record with a transcript is a normal record. The error flag
        // must not change that — the framework can fail *after* producing
        // usable text, and the VM already handles that by treating it as
        // on-device.
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: true, trimmedContent: "今天讨论了三个方案"),
            .save(.onDevice)
        )
        XCTAssertEqual(
            PendingRecognitionPolicy.classify(
                hasRecognitionError: false, trimmedContent: "hello"),
            .save(.online)
        )
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
xcodegen --spec project.yml
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: compile error — `PendingRecognitionPolicy` does not exist.

- [ ] **Step 3: Write the policy**

Create `ios/AudioNote/Services/PendingRecognitionPolicy.swift`:

```swift
import Foundation

/// The two decisions that decide whether a flight-mode recording is
/// thrown away or kept for later. Spec §4.2 and §4.6.
///
/// Both are pure static functions on purpose. `TranscriptionViewModel`
/// wires its collaborators as `private let` singletons and
/// `SpeechRecognizer` constructs `SFSpeechRecognizer` directly, so
/// neither can be instantiated in a unit test with a controlled
/// environment. Extracting the decisions here gets them under test
/// without a dependency-injection refactor of the whole view model.
enum PendingRecognitionPolicy {

    /// What `TranscriptionViewModel.stopRecording` should do once
    /// recognition has finished.
    enum Outcome: Equatable {
        /// No meaningful audio and no recognizer error — the user was
        /// silent. Nothing is persisted, matching the 2026-04-09
        /// skip-empty-transcription design.
        case discard
        /// Persist a record carrying this `recognitionMode`.
        case save(RecognitionMode)
    }

    /// Decides the fate of a finished recording.
    ///
    /// - Parameters:
    ///   - hasRecognitionError: whether the recognizer reported a failure.
    ///   - trimmedContent: the transcript, already whitespace-trimmed by
    ///     the caller. This function does not trim, so that "all
    ///     whitespace" is distinguishable from "has text" consistently
    ///     with how the VM computes `trimmedContent`.
    static func classify(hasRecognitionError: Bool,
                         trimmedContent: String) -> Outcome {
        if !trimmedContent.isEmpty {
            // A transcript exists. When the recognizer also errored, the
            // framework fell back to on-device or emitted partials —
            // the VM already maps that case to `.onDevice`.
            return .save(hasRecognitionError ? .onDevice : .online)
        }

        // No text. The error flag is what separates "the user said
        // nothing" from "the recognizer died mid-flight". Only the latter
        // is worth keeping, and it is worth keeping because the audio
        // file is already on disk with nothing pointing at it.
        return hasRecognitionError ? .save(.pending) : .discard
    }
}
```

- [ ] **Step 4: Wire it into `stopRecording`**

In `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`, replace lines 193-214:

```swift
        // Determine final recognition mode
        let mode: RecognitionMode
        if speechRecognizer.hasRecognitionError && trimmedContent.isEmpty {
            mode = .failed
        } else if speechRecognizer.hasRecognitionError && !trimmedContent.isEmpty {
            // Framework fell back to on-device or returned partial results
            mode = .onDevice
        } else {
            mode = speechRecognizer.recognitionMode
        }
        recognitionMode = mode

        speechRecognizer.stopRecording()
        isRecording = false
        stopDurationTimer()

        // Handle empty content
        if trimmedContent.isEmpty {
            Logger.info("No valid content detected, skipping save and LLM processing")
            transcribedText = ""
            return
        }
```

with:

```swift
        // Decide whether this recording is worth persisting. A recognizer
        // failure with no text still is: the audio is already on disk, and
        // before this the record was simply dropped, stranding the .m4a
        // with nothing referencing it (spec §4.2).
        let outcome = PendingRecognitionPolicy.classify(
            hasRecognitionError: speechRecognizer.hasRecognitionError,
            trimmedContent: trimmedContent
        )

        let mode: RecognitionMode
        switch outcome {
        case .discard:
            Logger.info("No valid content detected, skipping save and LLM processing")
            transcribedText = ""
            return
        case .save(let resolved):
            mode = resolved
        }
        recognitionMode = mode

        speechRecognizer.stopRecording()
        isRecording = false
        stopDurationTimer()
```

Note the reordering: `speechRecognizer.stopRecording()` now runs **after** the discard check instead of before it. That is safe because the discard path returns without touching the recognizer, and every caller of `stopRecording` reaches it from the same recording session — but keep the call in this position, not back at the top, so the `hasRecognitionError` read reflects the finished session.

- [ ] **Step 5: Run the test to verify it passes**

```sh
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: 7 tests pass.

- [ ] **Step 6: Build the app to confirm the view-model edit compiles**

```sh
xcodebuild -scheme AudioNote -sdk iphonesimulator \
           -destination 'generic/platform=iOS Simulator' build
```

Expected: build succeeds. A non-exhaustive `switch` elsewhere in the app over `RecognitionMode` will surface here — see Task 5 if it does.

- [ ] **Step 7: Commit**

```sh
git add ios/AudioNote/Services/PendingRecognitionPolicy.swift \
        ios/AudioNote/ViewModels/TranscriptionViewModel.swift \
        ios/AudioNoteTests/PendingRecognitionTests.swift
git commit -m "fix(recognition): persist records the recognizer failed on

stopRecording already computed recognitionMode == .failed at the top of
the method, then discarded it at the empty-content check four lines
later. The record was never created, so the .m4a on disk had nothing
pointing at it and the app behaved as if the recording never happened.

The decision moves into PendingRecognitionPolicy.classify so it is
testable at all: the view model wires its collaborators as private
singletons, so there is no way to drive this path from a unit test
without extracting it."
```

---

### Task 3: Recovery queue — the LLM exclusion

**Files:**
- Modify: `ios/AudioNote/Services/PendingRecognitionPolicy.swift` (add queue functions)
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:449-488`
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:261-269` (`assessAndEnhance`)
- Test: `ios/AudioNoteTests/PendingRecognitionTests.swift` (append)

**Interfaces:**
- Consumes: `PendingRecognitionPolicy.classify` (Task 2), `RecognitionMode.pending` (Task 1)
- Produces:
  ```swift
  extension PendingRecognitionPolicy {
      static func llmQueue(from records: [TranscriptionRecord]) -> [TranscriptionRecord]
      static func recognitionRetryQueue(from records: [TranscriptionRecord]) -> [TranscriptionRecord]
  }
  ```

- [ ] **Step 1: Write the failing test**

Append to `PendingRecognitionTests` in `ios/AudioNoteTests/PendingRecognitionTests.swift`:

```swift
    // MARK: - llmQueue()

    private func makeRecord(mode: RecognitionMode?,
                            content: String,
                            llmStatus: LLMStatus? = nil,
                            audioFileName: String? = "some-uuid.m4a") -> TranscriptionRecord {
        TranscriptionRecord(
            id: UUID(),
            content: content,
            createdAt: Date(timeIntervalSince1970: 1700000000),
            duration: 30,
            audioFileName: audioFileName,
            llmProcessingStatus: llmStatus,
            recognitionMode: mode
        )
    }

    func testLlmQueueExcludesPendingRecords() {
        // Review focus #4 — the load-bearing exclusion of the whole
        // feature. A pending record has llmProcessingStatus == nil and an
        // empty content, so the pre-existing filter swept it up and fed
        // "" to the LLM, which answers with a confident hallucination.
        let pending = makeRecord(mode: .pending, content: "")
        let normal = makeRecord(mode: .onDevice, content: "真正的转写文本")

        let queue = PendingRecognitionPolicy.llmQueue(from: [pending, normal])

        XCTAssertEqual(queue.map(\.id), [normal.id])
        XCTAssertFalse(queue.contains { $0.recognitionMode == .pending })
    }

    func testLlmQueueStillIncludesFailedStatusRecordsWithText() {
        // The exclusion must be narrow. A record that has real text and an
        // LLM failure still needs retrying — that is step 4's job.
        let failed = makeRecord(mode: .onDevice, content: "有文本", llmStatus: .failed)
        let queue = PendingRecognitionPolicy.llmQueue(from: [failed])
        XCTAssertEqual(queue.map(\.id), [failed.id])
    }

    func testLlmQueueIncludesLegacyRecordWithNilMode() {
        // Review focus #3, second half: a pre-upgrade record has
        // recognitionMode == nil. Excluding only `.pending` (and not
        // "anything not online") keeps it eligible.
        let legacy = makeRecord(mode: nil, content: "旧记录")
        let queue = PendingRecognitionPolicy.llmQueue(from: [legacy])
        XCTAssertEqual(queue.map(\.id), [legacy.id])
    }

    // MARK: - recognitionRetryQueue()

    func testRecognitionRetryQueueIncludesPendingAndFailed() {
        // Both states mean "transcript missing, audio on disk", and both
        // are worth re-running. Unlimited retries by design (spec D4).
        let pending = makeRecord(mode: .pending, content: "")
        let failed = makeRecord(mode: .failed, content: "")
        let healthy = makeRecord(mode: .online, content: "已经好了")

        let queue = PendingRecognitionPolicy.recognitionRetryQueue(
            from: [pending, failed, healthy])

        XCTAssertEqual(Set(queue.map(\.id)), Set([pending.id, failed.id]))
    }

    func testRecognitionRetryQueueRequiresAudioOnDisk() {
        // Without an .m4a there is nothing to re-recognize; retrying would
        // just spin. This guard already exists in the VM and is preserved.
        let noAudio = makeRecord(mode: .pending, content: "", audioFileName: nil)
        let queue = PendingRecognitionPolicy.recognitionRetryQueue(from: [noAudio])
        XCTAssertTrue(queue.isEmpty)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: compile error — `llmQueue` / `recognitionRetryQueue` do not exist.

- [ ] **Step 3: Write the queue functions**

Append to `ios/AudioNote/Services/PendingRecognitionPolicy.swift`:

```swift
extension PendingRecognitionPolicy {

    /// Records that `networkDidRecover` should send to the LLM — covers
    /// step 1 (never LLM-processed) and step 4 (LLM failed while offline).
    ///
    /// `.pending` is excluded, and that exclusion is the reason this
    /// function exists. The pre-existing filters were
    /// `llmProcessingStatus == nil` and `== .failed`; a freshly saved
    /// pending record satisfies the first one while carrying an empty
    /// `content`, so it would reach `optimizeAndProcess("")` and come
    /// back with an invented summary — the precise failure the
    /// 2026-04-09 skip-empty-transcription spec was written to prevent
    /// (spec §4.5).
    static func llmQueue(from records: [TranscriptionRecord]) -> [TranscriptionRecord] {
        records.filter { $0.recognitionMode != .pending }
    }

    /// Records that `networkDidRecover` should re-recognize from audio —
    /// step 3. Covers `.pending` (never transcribed) and `.failed` (a
    /// retry already came back empty). Retries are unlimited: a short
    /// accidental recording being retried repeatedly is a far smaller
    /// cost than a real three-minute recording being abandoned after a
    /// retry cap (spec D4).
    static func recognitionRetryQueue(
        from records: [TranscriptionRecord]
    ) -> [TranscriptionRecord] {
        records.filter {
            ($0.recognitionMode == .pending || $0.recognitionMode == .failed)
                && $0.audioFileName != nil
        }
    }
}
```

- [ ] **Step 4: Wire the queues into `networkDidRecover`**

In `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`, replace the body of `networkDidRecover` (lines 449-488) with:

```swift
    /// Called when network transitions from disconnected → connected (debounced)
    func networkDidRecover() async {
        Logger.info("Network recovered — processing pending items")
        let records = (try? await storage.loadAll()) ?? []

        // 1. Process records never LLM-processed
        for record in PendingRecognitionPolicy.llmQueue(from: records)
        where record.llmProcessingStatus == nil {
            guard NetworkMonitor.shared.checkConnectivity() else { return }
            let text = record.optimizedContent ?? record.content
            await processWithLLM(recordId: record.id, originalText: text)
        }

        // 2. Upgrade on-device recognitions
        let onDeviceRecords = records.filter {
            $0.recognitionMode == .onDevice && $0.audioFileName != nil
        }
        for record in onDeviceRecords {
            guard NetworkMonitor.shared.checkConnectivity() else { return }
            await enhanceRecognition(recordId: record.id)
        }

        // 3. Retry failed and never-completed recognitions
        for record in PendingRecognitionPolicy.recognitionRetryQueue(from: records) {
            guard NetworkMonitor.shared.checkConnectivity() else { return }
            await retryRecognitionFromFile(recordId: record.id)
        }

        // 4. Retry failed LLM (that failed due to offline)
        for record in PendingRecognitionPolicy.llmQueue(from: records)
        where record.llmProcessingStatus == .failed {
            guard NetworkMonitor.shared.checkConnectivity() else { return }
            let text = record.optimizedContent ?? record.content
            await processWithLLM(recordId: record.id, originalText: text)
        }

        await loadHistory()
    }
```

Both LLM loops now go through `llmQueue`, so the `.pending` exclusion cannot be forgotten in one of them. Step 3's own loop is left alone apart from routing the predicate through the policy — the `guard NetworkMonitor.shared.checkConnectivity()` calls stay exactly as they were, per the locked online-call gate.

- [ ] **Step 5: Add the `.pending` arm to `assessAndEnhance`**

ADR-0001 §30 requires a new switch arm for a new `RecognitionMode` case. In the same file, add to `assessAndEnhance` after the `.failed` case (line 265):

```swift
        case .pending:
            // Audio exists, transcript does not. Offline: wait for
            // `networkDidRecover` step 3. Online: recover immediately.
            // Never call `processWithLLM` here — `content` is empty, and
            // that is the hallucination path `llmQueue` also guards.
            if NetworkMonitor.shared.checkConnectivity() {
                await retryRecognitionFromFile(recordId: record.id)
            }
```

- [ ] **Step 6: Run the test to verify it passes**

```sh
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: 12 tests pass.

- [ ] **Step 7: Verify the exclusion test has teeth**

A test asserting "was not called" passes vacuously if the production filter is a no-op. Temporarily weaken `llmQueue` to `records` (drop the `.pending` exclusion) and re-run:

```sh
# Temporarily edit PendingRecognitionPolicy.llmQueue to:
#   static func llmQueue(from records: [TranscriptionRecord]) -> [TranscriptionRecord] {
#       records
#   }
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests/testLlmQueueExcludesPendingRecords
```

Expected: **FAIL** — the pending record appears in the queue. Then restore the filter and re-run to confirm it passes again. Do not commit while the weakened version is in place; verify with `git diff` before the commit step.

- [ ] **Step 8: Commit**

```sh
git add ios/AudioNote/Services/PendingRecognitionPolicy.swift \
        ios/AudioNote/ViewModels/TranscriptionViewModel.swift \
        ios/AudioNoteTests/PendingRecognitionTests.swift
git commit -m "fix(recovery): never send a pending record's empty text to the LLM

networkDidRecover step 1 filtered on llmProcessingStatus == nil, which a
freshly saved pending record satisfies while carrying empty content, so
it reached optimizeAndProcess(\"\") and came back with an invented
summary. Step 4 had the same hole.

Both LLM loops now route through PendingRecognitionPolicy.llmQueue so
the exclusion cannot be applied to one and forgotten on the other. Step
3's predicate moves to recognitionRetryQueue, which admits .pending
alongside .failed. assessAndEnhance gains the .pending arm ADR-0001 §30
requires for a new case."
```

---

### Task 4: Block the recording when offline recognition is unavailable

**Files:**
- Modify: `ios/AudioNote/Services/SpeechRecognizer.swift:6-30` (new error case)
- Modify: `ios/AudioNote/Services/SpeechRecognizer.swift:117-125` (the gate)
- Modify: `ios/AudioNote/Services/SpeechRecognizer.swift:189-196` (finish the stream)
- Test: `ios/AudioNoteTests/PendingRecognitionTests.swift` (append)

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `SpeechRecognitionError.onDeviceUnsupported(RecognitionLanguage)` with a localized `errorDescription`.

- [ ] **Step 1: Write the failing test**

Append to `PendingRecognitionTests`:

```swift
    // MARK: - Offline gate

    func testOnDeviceUnsupportedErrorCarriesLanguageInItsMessage() {
        // The user is offline and their language has no on-device model.
        // Telling them which language is the problem is the difference
        // between an actionable message and a shrug.
        let error = SpeechRecognitionError.onDeviceUnsupported(.chinese)
        let message = error.errorDescription ?? ""

        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(
            message.contains("中文"),
            "Expected the language name in the error, got: \(message)"
        )
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: compile error — `onDeviceUnsupported` does not exist.

- [ ] **Step 3: Add the error case**

In `ios/AudioNote/Services/SpeechRecognizer.swift`, add to `SpeechRecognitionError` after line 15:

```swift
    case onDeviceUnsupported(RecognitionLanguage)
```

and add to its `errorDescription` switch, after the `.noSpeechDetected` arm:

```swift
        case .onDeviceUnsupported(let language):
            return String(
                format: "Error.OnDeviceUnsupported".localized,
                language.displayName
            )
```

- [ ] **Step 4: Add the gate**

In the same file, replace lines 117-125:

```swift
        // T003, T004: Check network and set recognition mode
        let useOnDeviceRecognition = !NetworkMonitor.shared.checkConnectivity()
        recognitionMode = useOnDeviceRecognition ? .onDevice : .online
        recognitionError = nil
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = useOnDeviceRecognition

        let mode = useOnDeviceRecognition ? "offline (on-device)" : "online"
        Logger.speechEvent("Network check", details: "Using \(mode) recognition")
```

with:

```swift
        // T003, T004: Check network and set recognition mode
        let useOnDeviceRecognition = !NetworkMonitor.shared.checkConnectivity()

        // Offline, but this locale has no downloaded on-device model —
        // `zh-CN` is the common case. Requesting on-device recognition
        // anyway makes the request fail immediately, which previously
        // produced a recording whose audio was saved but whose record
        // was thrown away. Refuse before the user records anything
        // (spec §4.1).
        if useOnDeviceRecognition && !speechRecognizer.supportsOnDeviceRecognition {
            recognitionError = .onDeviceUnsupported(currentLanguage)
            Logger.error(
                "Offline but on-device recognition unsupported for \(currentLanguage.rawValue)"
            )
            throw SpeechRecognitionError.onDeviceUnsupported(currentLanguage)
        }

        recognitionMode = useOnDeviceRecognition ? .onDevice : .online
        recognitionError = nil
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = useOnDeviceRecognition

        let mode = useOnDeviceRecognition ? "offline (on-device)" : "online"
        Logger.speechEvent("Network check", details: "Using \(mode) recognition")
```

The throw happens before the audio engine starts and before `AudioRecorderService` is created, so no file is written. `TranscriptionViewModel.startRecording`'s existing catch block (line 172-178) already sets `errorMessage` and resets `isRecording` / `currentRecordId`, so no view changes are needed for this part.

- [ ] **Step 5: Finish the stream on error**

In the same file, replace lines 189-196:

```swift
                if let error = error as NSError? {
                    Logger.error("Recognition error: \(error.localizedDescription), code: \(error.code)")
                    selfStrong.recognitionError = .recognitionFailed(error)
                    // Don't cancel — let recording continue, audio is saved
                } else if error != nil {
                    Logger.warning("Unknown non-NSError in recognition task")
                    selfStrong.recognitionError = .recognitionFailed(nil)
                }
```

with:

```swift
                if let error = error as NSError? {
                    Logger.error("Recognition error: \(error.localizedDescription), code: \(error.code)")
                    selfStrong.recognitionError = .recognitionFailed(error)
                    // End the stream. Leaving it open means the consumer's
                    // `for await` never returns and `partialText` freezes at
                    // whatever last arrived, so any partial results the
                    // framework did produce are unreachable (spec §4.1).
                    // `stopRecording` cancels the task regardless, so
                    // finishing here is safe either way.
                    continuation.finish()
                } else if error != nil {
                    Logger.warning("Unknown non-NSError in recognition task")
                    selfStrong.recognitionError = .recognitionFailed(nil)
                    continuation.finish()
                }
```

- [ ] **Step 6: Add the localization keys**

Append to `ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings`:

```
"Error.OnDeviceUnsupported" = "当前语言（%@）不支持离线识别，请在联网状态下录音";
```

Append to `ios/AudioNote/Resources/en.lproj/Localizable.strings`:

```
"Error.OnDeviceUnsupported" = "Offline recognition isn't available for %@. Please record while online.";
```

- [ ] **Step 7: Run the test to verify it passes**

```sh
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: 13 tests pass.

- [ ] **Step 8: Commit**

```sh
git add ios/AudioNote/Services/SpeechRecognizer.swift \
        ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings \
        ios/AudioNote/Resources/en.lproj/Localizable.strings \
        ios/AudioNoteTests/PendingRecognitionTests.swift
git commit -m "fix(speech): refuse to record when offline recognition is unavailable

startRecording set requiresOnDeviceRecognition = true whenever the
network was down and never consulted supportsOnDeviceRecognition, so a
locale with no downloaded model failed the request immediately. Combined
with the discarded record, that meant a completed-looking recording that
existed only as a stranded .m4a.

The user now gets a message naming the language before recording starts
rather than a failure badge after. Also finishes the AsyncStream on
error, which was left open and froze partialText at its last value."
```

---

### Task 5: UI — badge, list row, detail page

**Files:**
- Modify: `ios/AudioNote/Views/SharedComponents.swift:84-113`
- Modify: `ios/AudioNote/Views/LibraryListView.swift:379-396`
- Modify: `ios/AudioNote/Views/TranscriptionDetailView.swift:281-283` and the `contentSection`
- Modify: `ios/AudioNote/Resources/{zh-Hans,en}.lproj/Localizable.strings`
- Test: `ios/AudioNoteTests/PendingRecognitionTests.swift` (append)

**Interfaces:**
- Consumes: `RecognitionMode.pending` (Task 1), `RecognitionModeStyle` (existing)
- Produces: three localization keys — `Recognition.Pending`, `History.PendingSummary`, `Detail.Pending.Hint`

- [ ] **Step 1: Write the failing test**

Append to `PendingRecognitionTests`:

```swift
    // MARK: - Presentation data

    func testPendingStyleHasDistinctLabelIconAndColor() {
        // `.pending` is not a failure the user should worry about — the
        // audio is safe and will be transcribed. It must not reuse
        // `.failed`'s red "识别失败" treatment, which is what told the
        // original bug reporter their recording was lost.
        let pending = RecognitionModeStyle(mode: .pending)
        let failed = RecognitionModeStyle(mode: .failed)

        XCTAssertNotEqual(pending.label, failed.label)
        XCTAssertNotEqual(pending.icon, failed.icon)
        XCTAssertNotEqual(pending.color, failed.color)
        XCTAssertFalse(pending.label.isEmpty)
        XCTAssertFalse(pending.icon.isEmpty)
    }

    func testRowTitleFallsBackToPendingLabelForEmptyContent() {
        // A pending record has no title and no content. Without a
        // fallback, displayTitle returns "" and N pending rows render as
        // N blank lines that are indistinguishable from each other.
        let record = TranscriptionRecord(
            id: UUID(),
            content: "",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            duration: 42,
            audioFileName: "some-uuid.m4a",
            recognitionMode: .pending
        )

        XCTAssertEqual(RecordRowView.rowTitle(for: record),
                       RecognitionModeStyle(mode: .pending).label)
        XCTAssertEqual(RecordRowView.rowSummary(for: record),
                       "History.PendingSummary".localized)
    }

    func testRowTitleUnaffectedForNormalRecords() {
        // The fallback must not fire for records that have real text.
        let withTitle = TranscriptionRecord(
            id: UUID(), content: "raw text", createdAt: Date(),
            title: "会议纪要", recognitionMode: .online)
        XCTAssertEqual(RecordRowView.rowTitle(for: withTitle), "会议纪要")

        let contentOnly = TranscriptionRecord(
            id: UUID(), content: "just the transcript", createdAt: Date(),
            recognitionMode: .onDevice)
        XCTAssertEqual(RecordRowView.rowTitle(for: contentOnly), "just the transcript")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
xcodegen --spec project.yml
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: compile errors — `RecognitionModeStyle(mode: .pending)` is a non-exhaustive switch, and `RecordRowView.rowTitle` does not exist.

- [ ] **Step 3: Extract the row text into testable statics**

In `ios/AudioNote/Views/LibraryListView.swift`, replace the `displayTitle` and `displaySummary` computed properties (lines 379-396) with versions that delegate to statics:

```swift
    private var displayTitle: String {
        Self.rowTitle(for: record)
    }

    private var displaySummary: String {
        Self.rowSummary(for: record)
    }

    /// The bold first line. Extracted as a static so it can be tested
    /// without a view: a pending record has neither `title` nor `content`,
    /// and without the fallback below this returns "" — N pending rows
    /// rendering as N identical blank lines.
    static func rowTitle(for record: TranscriptionRecord) -> String {
        if let title = record.title, !title.isEmpty {
            return title
        }
        if record.content.isEmpty {
            return record.recognitionMode.map { RecognitionModeStyle(mode: $0).label }
                ?? "History.Untitled".localized
        }
        let prefix = String(record.content.prefix(30))
        return prefix + (record.content.count > 30 ? "…" : "")
    }

    /// The de-emphasized second line. `record.preview` already falls back
    /// to a `content` slice, which is also empty for a pending record, so
    /// the empty case is handled explicitly.
    static func rowSummary(for record: TranscriptionRecord) -> String {
        if let summary = record.summary, !summary.isEmpty {
            return summary
        }
        if record.content.isEmpty {
            return record.recognitionMode == .pending
                ? "History.PendingSummary".localized
                : ""
        }
        let skip = record.title?.isEmpty == false ? min(record.title!.count, 30) : 30
        let start = record.content.index(record.content.startIndex,
                                         offsetBy: min(skip, record.content.count))
        let remaining = String(record.content[start...])
        let slice = String(remaining.prefix(50))
        return slice.isEmpty ? record.preview : slice + (remaining.count > 50 ? "…" : "")
    }
```

Add the two new localization keys used here (see step 6) — `History.Untitled` is a defensive fallback for a record with no content and a nil mode, which should not be reachable in practice.

- [ ] **Step 4: Add the `.pending` style**

In `ios/AudioNote/Views/SharedComponents.swift`, add `.pending` to all three switches in `RecognitionModeStyle` (lines 85-113):

```swift
        case .pending: return .orange
```
```swift
        case .pending: return "clock.badge.questionmark"
```
```swift
        case .pending: return "Recognition.Pending".localized
```

Amber rather than red: the audio is safe and the transcript is coming, so this is a waiting state, not a failure.

- [ ] **Step 5: Add the detail-page affordances**

In `ios/AudioNote/Views/TranscriptionDetailView.swift`, change the upgrade-button condition at lines 281-283 from:

```swift
            if let mode = currentRecord.recognitionMode,
               (mode == .onDevice || mode == .failed),
               currentRecord.audioFileName != nil {
```

to:

```swift
            if let mode = currentRecord.recognitionMode,
               (mode == .onDevice || mode == .failed || mode == .pending),
               currentRecord.audioFileName != nil {
```

The button already routes through `upgradeRecognition()` → `reRecognizeOnline` → `retryRecognitionFromFile`, which is the same path the automatic recovery uses — no new trigger logic.

In `contentSection` (defined at line 158), the body renders `Text(editedContent)`, which is seeded from `record.content` at line 17 — empty for a pending record. Replace the inner `Group` (lines 172-183) with a version that shows a placeholder instead of an empty text block:

```swift
            Group {
                if isEditing {
                    TextEditor(text: $editedContent)
                        .font(.body)
                        .frame(minHeight: 200)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                } else if currentRecord.recognitionMode == .pending {
                    // No transcript yet — the recovery sweep fills this in
                    // later. Rendering `Text("")` here would leave a blank
                    // body with no explanation of why (spec §4.7).
                    VStack(spacing: 12) {
                        Image(systemName: RecognitionModeStyle(mode: .pending).icon)
                            .font(.largeTitle)
                            .foregroundColor(RecognitionModeStyle(mode: .pending).color)
                        Text("Detail.Pending.Hint".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    Text(editedContent)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
```

Keep the editor reachable for pending records — a user who is offline and knows what they said can type it in, which is exactly the case Review Focus #5 is about.

- [ ] **Step 6: Add the localization keys**

Append to `ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings`:

```
"Recognition.Pending" = "待识别";
"History.PendingSummary" = "录音待联网识别";
"History.Untitled" = "无标题";
"Detail.Pending.Hint" = "此录音尚未识别，联网后会自动补识别";
```

Append to `ios/AudioNote/Resources/en.lproj/Localizable.strings`:

```
"Recognition.Pending" = "Pending recognition";
"History.PendingSummary" = "Recording awaiting recognition";
"History.Untitled" = "Untitled";
"Detail.Pending.Hint" = "This recording hasn't been transcribed yet. It will be processed automatically once you're back online.";
```

- [ ] **Step 7: Run the test to verify it passes**

```sh
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: 16 tests pass.

- [ ] **Step 8: Run the whole suite to catch non-exhaustive switches**

```sh
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722'
```

Expected: all suites green — 69 pre-existing tests plus 16 new ones. A non-exhaustive `switch` over `RecognitionMode` anywhere in the app surfaces here.

- [ ] **Step 9: Commit**

```sh
git add ios/AudioNote/Views/SharedComponents.swift \
        ios/AudioNote/Views/LibraryListView.swift \
        ios/AudioNote/Views/TranscriptionDetailView.swift \
        ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings \
        ios/AudioNote/Resources/en.lproj/Localizable.strings \
        ios/AudioNoteTests/PendingRecognitionTests.swift
git commit -m "feat(ui): show pending recordings in the library and detail page

A pending record has no title and no content, so RecordRowView rendered
it as a blank line. displayTitle and displaySummary gain fallbacks, and
are extracted as statics so the fallback is testable without a view.

The badge is amber rather than red: the audio is safe and the transcript
is coming, which is the opposite of what the old red \"识别失败\" badge
communicated. The detail page's existing upgrade button already routes
to retryRecognitionFromFile, so it only needed .pending in its condition."
```

---

### Task 6: Don't overwrite a pending record the user typed by hand

**Files:**
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:559-585` (`updateRecord`)
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:315-345` (`retryRecognitionFromFile`)
- Test: `ios/AudioNoteTests/PendingRecognitionTests.swift` (append)

**Interfaces:**
- Consumes: `RecognitionMode.pending` (Task 1), `PendingRecognitionPolicy` (Task 2)
- Produces: a rule that a hand-edited pending record is never overwritten by the recovery sweep.

**Why this is its own task:** the project CLAUDE.md locks the rule `optimizedContent != content` ⇒ skip auto-enhance. That rule is how a hand-edited record is recognised. But `updateRecord` (line 578) only ever carries `optimizedContent` forward from an existing record — a user editing a pending record, whose `content` is empty and whose `optimizedContent` is nil, produces a record where **both are nil**. The rule cannot fire, and the next network recovery overwrites what they typed. This is a pre-existing gap in `updateRecord` that only becomes reachable now that empty-content records can exist.

- [ ] **Step 1: Write the failing test**

Append to `PendingRecognitionTests`:

```swift
    // MARK: - Hand-edited pending records

    func testHandEditedPendingRecordIsRecognisedAsEdited() {
        // Review focus #5. `optimizedContent` is the marker the whole
        // codebase uses to mean "the user changed this by hand"
        // (CLAUDE.md locked decision; `enhanceRecognition:288` reads it).
        // `updateRecord` never set it for a pending record, so the marker
        // was absent and the recovery sweep overwrote the user's text.
        //
        // A pending record is seeded with empty content; typing into the
        // detail page editor and saving must set the marker.
        let pending = makeRecord(mode: .pending, content: "")

        let afterEdit = TranscriptionRecord(
            id: pending.id,
            content: "用户手动补的文字",
            createdAt: pending.createdAt,
            duration: pending.duration,
            audioFileName: pending.audioFileName,
            optimizedContent: pending.content,   // what updateRecord must write
            recognitionMode: pending.recognitionMode
        )

        XCTAssertNotEqual(afterEdit.content, afterEdit.optimizedContent,
                          "The user-edit marker must differ from content, "
                          + "or the skip-auto-enhance rule cannot fire")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: PASSES as written — the test only asserts the shape. That is deliberate: it documents the contract. The behaviour it protects is wired in step 3, and the end-to-end guard in step 4 is what actually fails first. Replace the body with this to confirm the guard is missing:

```swift
        // TEMPORARY — this is the check that must FAIL before the fix:
        // a hand-edited pending record still sitting in the retry queue.
        let edited: TranscriptionRecord = {
            var r = makeRecord(mode: .pending, content: "")
            r.content = "用户手动补的文字"
            return r
        }()

        XCTAssertTrue(
            PendingRecognitionPolicy.recognitionRetryQueue(from: [edited]).isEmpty,
            "A hand-edited pending record must not be auto-overwritten"
        )
```

- [ ] **Step 3: Record the edit marker in `updateRecord`**

In `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`, in `updateRecord` (lines 559-585), add a line before the `TranscriptionRecord` construction that captures the pre-edit content, and pass it as `optimizedContent` when the content actually changed:

```swift
    func updateRecord(_ record: TranscriptionRecord) async throws {
        // ... existing comment ...
        let existingRecord = try await storage.get(id: record.id)

        // `optimizedContent` is this codebase's marker for "the user
        // changed the text by hand" — `enhanceRecognition:288` and the
        // CLAUDE.md locked decision both read it. Carry the pre-edit
        // content into it whenever the caller changed the text, so a
        // hand-edited *pending* record is not overwritten when the
        // network comes back. Without this, a pending record (empty
        // content, nil optimizedContent) edited by the user still looked
        // unedited to every downstream check.
        let previousContent = existingRecord?.content ?? record.content
        let contentChanged = record.content != previousContent
        let marker = record.optimizedContent
            ?? (contentChanged ? previousContent : existingRecord?.optimizedContent)

        let updatedRecord = TranscriptionRecord(
            // ... unchanged fields ...
            optimizedContent: marker,
            // ... unchanged fields ...
        )
        try await storage.save(updatedRecord)
        await loadHistory()
    }
```

The `?? existingRecord?.optimizedContent` fallback preserves the existing behaviour for records that already carry a marker, and `contentChanged` is false when the caller only changed, say, `title` — so re-saving an untouched record does not spuriously mark it as edited.

- [ ] **Step 4: Make the retry respect the marker**

`retryRecognitionFromFile` (lines 315-345) unconditionally overwrites `content`. Add the same guard `enhanceRecognition` already has, right after the record is loaded:

```swift
        // A pending record the user filled in by hand must not be
        // clobbered by the sweep. Same rule as `enhanceRecognition:288`
        // and the CLAUDE.md locked decision.
        if record.optimizedContent != nil && record.content != record.optimizedContent {
            Logger.info("Skipping auto-retry: user has edited content")
            return
        }
```

- [ ] **Step 5: Run the test to verify it passes**

```sh
xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722' \
  -only-testing:AudioNoteTests/PendingRecognitionTests
```

Expected: 17 tests pass, including the temporary end-to-end guard once it is folded into the permanent form.

- [ ] **Step 6: Remove the temporary assertion**

Delete the `// TEMPORARY` block from step 2, leaving only `testHandEditedPendingRecordIsRecognisedAsEdited`. Confirm with `git diff ios/AudioNoteTests/PendingRecognitionTests.swift` before committing.

- [ ] **Step 7: Commit**

```sh
git add ios/AudioNote/ViewModels/TranscriptionViewModel.swift \
        ios/AudioNoteTests/PendingRecognitionTests.swift
git commit -m "fix(recovery): never overwrite a hand-edited pending record

optimizedContent is how this codebase marks a record as user-edited —
enhanceRecognition:288 and the CLAUDE.md locked decision both read it.
updateRecord never wrote it, so editing a pending record (empty content,
nil marker) left the record looking untouched and the network-recovery
sweep replaced whatever the user typed.

updateRecord now carries the pre-edit content into optimizedContent when
the text actually changed, and retryRecognitionFromFile checks the marker
before overwriting, matching what enhanceRecognition already did."
```

---

### Task 7: Documentation

**Files:**
- Create: `docs/decisions/0004-pending-recognition-mode.md`
- Modify: `docs/GLOSSARY.md`
- Modify: `CLAUDE.md`
- Modify: `docs/ROADMAP.md`

**Interfaces:**
- Consumes: everything from Tasks 1-6
- Produces: no code

- [ ] **Step 1: Write ADR-0004**

Create `docs/decisions/0004-pending-recognition-mode.md`, following the exact field order ADR-0001 mandates (Status / Date / Supersedes / Superseded-by / Context / Decision / What's locked / Free to change / Touch this when / Code anchors / Test coverage / Related):

```markdown
# ADR-0004: Pending recognition mode

| Field | Value |
|---|---|
| **Status** | PROPOSED |
| **Date** | 2026-10-03 |
| **Supersedes** | — |
| **Superseded-by** | — |
| **Author** | — |

## Context

A recording made with no network was written to disk as an `.m4a` but
produced no record at all, so the library showed nothing and the file had
nothing pointing at it. `TranscriptionViewModel.stopRecording` computed
`recognitionMode == .failed` and then discarded it at the empty-content
check, four lines later.

The recovery machinery already existed — `networkDidRecover` re-ran
`retryRecognitionFromFile` for `.failed` records — but it never received
one, because no record was ever created.

`.failed` alone was not enough to model this. It means "a retry already
happened and also came back empty", which is a terminal state the user
should be told about. The new state means "never transcribed, waiting".

## Decision

Add `RecognitionMode.pending` for records that have audio and no
transcript, and gate `SpeechRecognizer.startRecording` on
`supportsOnDeviceRecognition` so an unsupported offline recording is
refused before it starts.

`RecognitionMode.pending` is an enum case, not a new field on
`TranscriptionRecord`. The stored shape is unchanged and `Codable`
synthesis is unaffected, so no migration is required.

## What's locked

- `.pending` records must be excluded from every path that reaches the
  LLM. `PendingRecognitionPolicy.llmQueue` is the single place that
  decides this; do not inline the filter.
- Any new `RecognitionMode` case requires a new arm in
  `assessAndEnhance` (inherited from ADR-0001 §30).
- A pending record's `content` is empty by definition. Nothing may treat
  it as a transcript.

## Free to change

- The retry policy (currently unlimited retries, shared with `.failed`)
- The badge colour, icon, and wording
- Whether pending records get their own view, filter, or section

## Touch this when

- A new source of "audio but no transcript" appears
- The retry policy needs a cap or backoff
- `TranscriptionRecord` ever gains a field (re-examine whether the enum
  case is still the right modelling)

## Code anchors

| Symbol | Path:line |
|---|---|
| State | `ios/AudioNote/Models/TranscriptionRecord.swift:3` |
| Discard / persist decision | `ios/AudioNote/Services/PendingRecognitionPolicy.swift` |
| LLM exclusion | `PendingRecognitionPolicy.llmQueue` |
| Recovery queues | `PendingRecognitionPolicy.recognitionRetryQueue` |
| Call site | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` `stopRecording` |
| Recovery sweep | `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` `networkDidRecover` |
| Offline gate | `ios/AudioNote/Services/SpeechRecognizer.swift` `startRecording` |

## Test coverage expected

`ios/AudioNoteTests/PendingRecognitionTests.swift`. Any PR touching this
area must keep: the silent-recording discard, the LLM exclusion (with
teeth verification), the legacy-JSON decode, and the row-text fallbacks.

## Related

- Spec: `docs/superpowers/specs/2026-10-03-pending-recognition-design.md`
- Extends: ADR-0001 (whose §30 required the `assessAndEnhance` arm)
- Supersedes in practice: `docs/superpowers/specs/2026-04-09-skip-empty-transcription-design.md`,
  which assumed "empty content" always meant "nothing was said"
```

Note the line numbers above are deliberately absent for the anchors that shift as earlier tasks land — re-read the files and fill in real values before committing rather than leaving the ADR pointing at stale lines.

- [ ] **Step 2: Update the glossary**

Add to `docs/GLOSSARY.md` under the Models section:

```markdown
| `RecognitionMode.pending` | Audio exists, no transcript. The recognizer errored and returned nothing. Re-queued by `networkDidRecover` step 3 on every network recovery. Never sent to the LLM — its `content` is empty by definition. |
| `PendingRecognitionPolicy` | Pure static functions holding the two decisions this feature introduces: `classify` (persist or discard a finished recording) and `llmQueue` / `recognitionRetryQueue` (who runs on network recovery). |
```

- [ ] **Step 3: Update the project CLAUDE.md**

Add a bullet to the "Locked decisions" section:

```markdown
- A `RecognitionMode.pending` record (audio, no transcript) MUST be excluded from every LLM path. See ADR-0004.
```

And add to the "Architecture docs" table:

```markdown
| `docs/decisions/0004-pending-recognition-mode.md` | Touching `RecognitionMode.pending`, `PendingRecognitionPolicy`, or the `networkDidRecover` queues |
```

- [ ] **Step 4: Resolve the ROADMAP ADR number collision**

`docs/ROADMAP.md:9` has a placeholder entry titled "ADR-0003: Skip-empty-transcription" that collides with the real `docs/decisions/0003-multi-provider-llm.md`. This feature just superseded that placeholder's assumption, so retire it. Replace the entry with:

```markdown
## ~~ADR-0003: Skip-empty-transcription~~ (retired 2026-10-03)

- **What**: The decision that empty/blank transcripts MUST skip both save and LLM path.
- **Status**: **RETIRED** — superseded in practice by ADR-0004. The original rule was "empty content means
  the user said nothing", which is false: a recognizer failure also produces empty content, and dropping
  those records is what stranded the audio. ADR-0004 replaces the content check with
  `PendingRecognitionPolicy.classify`, which reads the recognizer's error flag to tell the two apart.
- **Do not resurrect** as a standalone ADR — the decision now lives in `PendingRecognitionPolicy` and is
  documented in ADR-0004. The number was also already taken by `0003-multi-provider-llm.md`.
```

- [ ] **Step 5: Verify the docs build cleanly and commit**

```sh
grep -rn "TBD\|TODO\|XX" docs/decisions/0004-pending-recognition-mode.md
git add docs/decisions/0004-pending-recognition-mode.md docs/GLOSSARY.md \
        CLAUDE.md docs/ROADMAP.md
git commit -m "docs: add ADR-0004 and update glossary, CLAUDE.md, ROADMAP

ADR-0004 records the pending-recognition state and the load-bearing
constraint that a pending record must never reach the LLM. The ROADMAP
placeholder for skip-empty-transcription is retired: its core rule --
empty content means the user was silent -- is what this feature proved
false, and the number collided with the real 0003-multi-provider-llm."
```

---

### Task 8: Manual verification on device

**Files:** none (verification only)

**Interfaces:**
- Consumes: everything from Tasks 1-6
- Produces: confirmation the feature works end to end

- [ ] **Step 1: Build, install, and launch on the iPhone Air**

```sh
cd /Users/karsa/proj/audionote/ios
xcodebuild -scheme AudioNote \
  -destination 'platform=iOS,id=3C0B7BE4-2AEF-54E4-B937-9A0C96326420' build
xcrun devicectl device install app \
  --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 \
  ~/Library/Developer/Xcode/DerivedData/AudioNote-*/Build/Products/Debug-iphoneos/AudioNote.app
xcrun devicectl device process launch \
  --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 info.karsa.app.ios.audionote
```

- [ ] **Step 2: Verify the offline gate (this is the original bug's confirmation)**

1. Turn on airplane mode.
2. Tap record. **Expected: an immediate error naming the language — "当前语言（中文）不支持离线识别" — and no recording starts.** The timer never runs.
3. Confirm no new `.m4a` appeared in the Files app's `AudioNote/` folder.

This step also closes the spec's open question about whether the diagnosis was direct evidence or inference: if the gate fires, the offline-unsupported path was the cause.

- [ ] **Step 3: Verify the pending path**

To exercise this you need a recognizer failure *without* the offline gate firing — i.e. a locale that reports on-device support but still fails, or a failure injected at runtime. If step 2 makes the offline path unreachable, record this item as **not directly verifiable on device** and confirm it via the unit tests only. Do not claim device verification for a path the device cannot reach.

- [ ] **Step 4: Verify recovery and the UI**

If step 3 was reachable, confirm:

1. The pending row appears in the library under the day it was recorded, with an amber "待识别" badge and its duration.
2. Three pending recordings produce three distinguishable rows (different times and durations).
3. Tapping one opens a detail page with the placeholder text and a working "在线升级识别" button.
4. Reconnecting to the network fills in the transcript; the badge changes; 相关思考 appears once the LLM pass completes.
5. A genuinely silent recording — airplane mode on, tap record, immediately stop — produces **no** new row.

- [ ] **Step 5: Run the full suite one final time**

```sh
cd /Users/karsa/proj/audionote/ios && xcodebuild test -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=6304E0C2-7A83-49CA-BA28-21F7140A7722'
```

Expected: all suites green — 69 pre-existing + 17 new.

- [ ] **Step 6: Confirm the working tree is clean and push**

```sh
cd /Users/karsa/proj/audionote && git status --short
git push origin main
```

If step 3 could not be exercised, note it in the commit message or an issue rather than letting a green test run stand in for device verification that did not happen.

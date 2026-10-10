import Foundation

/// The decisions that stand between a recording and its transcript, each
/// extracted as a pure static so it can be unit-tested. Four of them:
///
/// - `classify` — whether a finished recording is discarded, saved as
///   `.pending`, or saved with the recognizer's own mode (spec §4.2).
/// - `llmQueue` / `recognitionRetryQueue` — the two recovery queues
///   `networkDidRecover` drains (spec §4.6).
/// - `shouldRefuseToRecord` — whether a recording may start at all when
///   the device is offline (spec §4.1).
/// - `isLLMEligible` — the empty-text guard; pre-dates this work, see the
///   2026-04-09 skip-empty-transcription design.
///
/// Every one of them is a pure static on purpose.
/// `TranscriptionViewModel` wires its collaborators as `private let`
/// singletons and `SpeechRecognizer` constructs `SFSpeechRecognizer`
/// directly, so neither can be instantiated in a unit test with a
/// controlled environment. Extracting the decisions here gets them under
/// test without a dependency-injection refactor of the whole view model.
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
    ///     the caller. It is re-checked here so that whitespace-only input
    ///     is treated as silence rather than as a transcript: the caller
    ///     guarantees the trim, but a record that consists of nothing but
    ///     spaces must never reach `TranscriptionStorage` as content, and
    ///     the same rule is what keeps the 2026-04-09 skip-empty design
    ///     honest if a future caller forgets to trim.
    ///   - recognizerMode: the mode the recognizer actually ran in, i.e.
    ///     `SpeechRecognizer.recognitionMode`. This is what the code
    ///     `classify` replaced assigned to the record, and it is passed in
    ///     rather than read from a collaborator so this stays a pure
    ///     static. It is the honest label for a transcript produced without
    ///     an error: an offline recording recognised on-device is
    ///     `.onDevice`, and that label is what keeps the connectivity gate
    ///     in `assessAndEnhance` and the onDevice→online upgrade filter in
    ///     `networkDidRecover` matching the record.
    static func classify(hasRecognitionError: Bool,
                         trimmedContent: String,
                         recognizerMode: RecognitionMode) -> Outcome {
        let hasText = !trimmedContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        if hasText {
            // A transcript exists. When the recognizer also errored, the
            // framework fell back to on-device or emitted partials —
            // the VM already maps that case to `.onDevice`. Without an
            // error, the recognizer's own mode is the truthful label.
            return .save(hasRecognitionError ? .onDevice : recognizerMode)
        }

        // No text. The error flag is what separates "the user said
        // nothing" from "the recognizer died mid-flight". Only the latter
        // is worth keeping, and it is worth keeping because the audio
        // file is already on disk with nothing pointing at it.
        return hasRecognitionError ? .save(.pending) : .discard
    }
}

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
    /// 2026-04-09 skip-empty-transcription spec names as its second
    /// problem, verbatim: "大模型收到空文本，可能返回幻觉信息"
    /// (that spec's `问题` section; the doc is written in Chinese and
    /// has no numbered subsections).
    ///
    /// Records that are hand-edited are excluded too, so both automatic
    /// sweeps — this one and `recognitionRetryQueue` — leave text the user
    /// owns alone. This is the step that makes the HIGH hole closed: with
    /// the `.pending` filter alone, an `.onDevice` record the user had
    /// edited was still swept into steps 1 and 4, and `processWithLLM`
    /// writes its result straight over `content`.
    ///
    /// Filtering in the queue rather than inside `processWithLLM` is what
    /// keeps the manual routes working. `retryLLM` and the "重试" button in
    /// `RecordingView` reach `processWithLLM` directly, and for those the
    /// user is explicitly asking for their text to be replaced.
    static func llmQueue(from records: [TranscriptionRecord]) -> [TranscriptionRecord] {
        records.filter {
            $0.recognitionMode != .pending && !isHandEdited($0)
        }
    }

    /// Records that `networkDidRecover` should re-recognize from audio —
    /// step 3. Covers `.pending` (never transcribed) and `.failed` (a
    /// retry already came back empty). Retries are unlimited: a short
    /// accidental recording being retried repeatedly is a far smaller
    /// cost than a real three-minute recording being abandoned after a
    /// retry cap (spec D4).
    ///
    /// Records that `isHandEdited` reports are excluded. A queued record
    /// re-recognizes from audio and writes the result over `content`, so
    /// one that has already diverged from its source text is a record that
    /// an automatic sweep would keep overwriting, on every reconnect,
    /// without ever asking. Excluding it here rather than inside
    /// `retryRecognitionFromFile` keeps the manual route —
    /// `reRecognizeOnline`, the "在线重新识别" button in
    /// `TranscriptionDetailView` — working: the user asking for an
    /// overwrite is exactly the case where an overwrite is what they want.
    static func recognitionRetryQueue(
        from records: [TranscriptionRecord]
    ) -> [TranscriptionRecord] {
        records.filter {
            ($0.recognitionMode == .pending || $0.recognitionMode == .failed)
                && $0.audioFileName != nil
                && !isHandEdited($0)
        }
    }

    /// Whether `record.content` has diverged from the text it was derived
    /// from.
    ///
    /// This is the locked project decision in predicate form (see
    /// CLAUDE.md): `optimizedContent != content` ⇒ skip. The two halves are
    /// both load-bearing. `optimizedContent != nil` rules out a record that
    /// has never been marked; `content != optimizedContent` rules out the
    /// case where the two are equal and nothing has diverged.
    ///
    /// It does **not** mean "a human typed this". `processWithLLM` has
    /// always set `optimizedContent = originalText` alongside
    /// `content = optimizedText`, so every LLM-processed record already
    /// satisfies this predicate with no human keystroke anywhere. The
    /// marker field is overloaded: it holds the pre-LLM original *and* the
    /// pre-edit text, and the record cannot tell them apart. Distinguishing
    /// them would need a field on `TranscriptionRecord`, which is locked
    /// out of scope. So the honest description is what is written above —
    /// content has diverged from its source — and that is what the
    /// consumers of this predicate actually act on.
    ///
    /// It lives here, as one definition shared by `enhanceRecognition`,
    /// `llmQueue`, `recognitionRetryQueue` and `llmInputText`, so those
    /// guards cannot drift apart. If they did, a record could be protected
    /// from one path and clobbered by another.
    static func isHandEdited(_ record: TranscriptionRecord) -> Bool {
        record.optimizedContent != nil && record.content != record.optimizedContent
    }

    /// The text an LLM call should be given for `record`.
    ///
    /// The historical resolution was `record.optimizedContent ?? record.content`,
    /// which was correct for as long as `optimizedContent` only ever held a
    /// pre-LLM original: the original was the right input to re-optimize.
    /// It is no longer safe on its own, because the same field now also
    /// holds *the text from before the user's last edit*. Resolving it
    /// naively on a hand-edited record sends the pre-edit text to the LLM
    /// and `processWithLLM` writes the answer back over the user's own.
    ///
    /// So the hand-edited case resolves to `content` — the current text is
    /// what the user wants processed — and every other record keeps the
    /// historical answer exactly. Routes that resolve this themselves have
    /// to call here; the idiom is wrong on its own now.
    static func llmInputText(for record: TranscriptionRecord) -> String {
        isHandEdited(record) ? record.content : (record.optimizedContent ?? record.content)
    }

    /// The `optimizedContent` a record should carry after `updateRecord`.
    ///
    /// Extracted as a pure static for the same reason as `classify`:
    /// `updateRecord` reaches `TranscriptionStorage` and `loadHistory`
    /// through the view model's collaborators, so the view model cannot be
    /// constructed in a unit test. The *decision* is what matters, so the
    /// decision is what gets tested.
    ///
    /// Three terms, in precedence order:
    ///
    /// 1. `incoming.optimizedContent` — a caller that states the value
    ///    outright is believed. `reprocessRecord` does this.
    /// 2. `existing?.content`, but only when `incoming.content` differs
    ///    from it — the user changed the text, so the text they changed
    ///    *from* is the pre-edit original. The conditional matters:
    ///    `updateRecord` is also reached from `reprocessRecord` and from
    ///    saves that touch only `title`, and without it a re-save of an
    ///    untouched record would mark itself hand-edited and freeze it out
    ///    of every automatic route, forever.
    /// 3. `existing?.optimizedContent` — nothing changed, so carry the
    ///    existing marker forward. `nil` falls out of this for free.
    static func handEditMarker(
        incoming: TranscriptionRecord,
        existing: TranscriptionRecord?
    ) -> String? {
        if let explicit = incoming.optimizedContent { return explicit }

        let previousContent = existing?.content ?? incoming.content
        if incoming.content != previousContent { return previousContent }

        return existing?.optimizedContent
    }
}

extension PendingRecognitionPolicy {

    /// Whether `text` is worth sending to the LLM at all.
    ///
    /// Extracted as a pure static for the same reason as `classify`:
    /// `TranscriptionViewModel.processWithLLM` reaches `ProviderProfileStore`,
    /// `NetworkMonitor` and `LLMService` through `private let` singletons, so
    /// that function cannot be constructed in a unit test. The *decision* is
    /// what matters, so the decision is what gets tested.
    ///
    /// `llmQueue` filters records, not text, and cannot cover
    /// `processWithLLM`: that is the choke point for the view model's own LLM
    /// routes — `assessAndEnhance`, `retryRecognitionFromFile`,
    /// `networkDidRecover` steps 1 and 4, `retryLLM`, and the retry button in
    /// `RecordingView` — not all of which route through a queue.
    /// `assessAndEnhance` calls it directly, `retryRecognitionFromFile` calls
    /// it directly *after* re-stamping the record `.enhanced` — a mode
    /// `llmQueue` deliberately admits — and `retryLLM` calls it directly with
    /// no mode filter at all. An empty string sent to the LLM does not come
    /// back empty: it comes back a confident invented title, summary and
    /// tags, which are written over the record.
    ///
    /// It is not, however, the choke point for the whole app:
    /// `TranscriptionDetailView.reprocessRecord` is a second route into
    /// `LLMService.optimizeAndProcess` that bypasses `processWithLLM` entirely
    /// and therefore has to call this predicate itself. Two call sites, two
    /// copies of the guard — an audit of "where is empty text kept out of the
    /// LLM?" has to find both, not just the view model.
    ///
    /// The same predicate is also what decides whether a *re-recognition*
    /// produced anything worth keeping. A recognizer can return a final result
    /// with an empty transcription — silence, noise, a truncated .m4a — without
    /// throwing, so "did not throw" is not "succeeded". Both call sites that
    /// re-recognize from a file use this one check:
    /// `retryRecognitionFromFile`, where an empty result would drop the record
    /// out of the retry queue, and `enhanceRecognition`, where it would
    /// overwrite a transcript the record already has.
    static func isLLMEligible(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension PendingRecognitionPolicy {

    /// Whether `SpeechRecognizer.startRecording` should refuse to start.
    /// Spec §4.1, Task 4.
    ///
    /// Extracted as a pure static for the same reason as `classify`:
    /// the check reads `SFSpeechRecognizer.supportsOnDeviceRecognition`,
    /// a property of a framework object built from the device's currently
    /// installed models, and `startRecording` is reached through
    /// `TranscriptionViewModel`'s `private let` singleton. There is no
    /// way to hand the test a recognizer that reports "offline, zh-CN has
    /// no model", so the decision itself is what gets tested.
    ///
    /// The pre-existing code set
    /// `recognitionRequest.requiresOnDeviceRecognition = true` whenever
    /// the network was down and never consulted this property. For a
    /// locale with no downloaded model — `zh-CN` being the common case —
    /// the request then failed immediately, and the user was told about it
    /// only after three minutes of talking, by which time the audio was on
    /// disk with nothing referencing it.
    ///
    /// Online recognition never consults `supportsOnDeviceRecognition`, so
    /// that property being false must not block a recording when there is a
    /// network. It is a property of the *on-device* path, not a global
    /// "recognition is broken" flag.
    static func shouldRefuseToRecord(isOffline: Bool,
                                     supportsOnDeviceRecognition: Bool) -> Bool {
        isOffline && !supportsOnDeviceRecognition
    }
}

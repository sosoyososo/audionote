import Foundation

/// The decision that governs whether a flight-mode recording is
/// thrown away or kept for later. Spec §4.2 and §4.6.
///
/// `classify` is a pure static function on purpose.
/// `TranscriptionViewModel` wires its collaborators as `private let`
/// singletons and `SpeechRecognizer` constructs `SFSpeechRecognizer`
/// directly, so neither can be instantiated in a unit test with a
/// controlled environment. Extracting the decision here gets it under
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

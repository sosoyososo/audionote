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

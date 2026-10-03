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
    ///     the caller. It is re-checked here so that whitespace-only input
    ///     is treated as silence rather than as a transcript: the caller
    ///     guarantees the trim, but a record that consists of nothing but
    ///     spaces must never reach `TranscriptionStorage` as content, and
    ///     the same rule is what keeps the 2026-04-09 skip-empty design
    ///     honest if a future caller forgets to trim.
    static func classify(hasRecognitionError: Bool,
                         trimmedContent: String) -> Outcome {
        let hasText = !trimmedContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        if hasText {
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

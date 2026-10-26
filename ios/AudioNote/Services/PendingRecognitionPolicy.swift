import Foundation

/// The decisions that stand between a recording and its transcript, each
/// extracted as a pure static so it can be unit-tested. The ones that matter
/// most:
///
/// - `classify` — whether a finished recording is discarded, saved as
///   `.pending`, or saved with the recognizer's own mode (spec §4.2).
/// - `llmQueue` / `recognitionRetryQueue` — the two recovery queues
///   `networkDidRecover` drains (spec §4.6).
/// - `shouldRefuseToRecord` — whether a recording may start at all when
///   the device is offline (spec §4.1).
/// - `isLLMEligible` — the empty-text guard; pre-dates this work, see the
///   2026-04-09 skip-empty-transcription design.
/// - `mergedRecord` — the record `updateRecord` writes, which carries
///   forward every field the caller did not restate.
///
/// The hand-edit family — `isHandEdited`, `llmInputText`, `handEditMarker` —
/// is the other half of the same namespace; see ADR-0005.
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
    /// Records that `isHandEdited` reports are excluded too. That is what
    /// closes the HIGH: with the `.pending` filter alone, an `.onDevice`
    /// record the user had edited was still swept into steps 1 and 4, and
    /// `processWithLLM` writes its result straight over `content`.
    ///
    /// Read the filter as "content has diverged from its source", NOT as
    /// "the user wrote this". Because `processWithLLM` has always set
    /// `optimizedContent = originalText` alongside
    /// `content = optimizedText`, **this also excludes essentially every
    /// LLM-processed record** — those whose optimized text differs from
    /// their input — with no human keystroke anywhere.
    ///
    /// **Do not "tidy" that extra reach away, and do not enforce an
    /// invariant that says a `.failed` record never carries a diverged
    /// marker. That invariant is false.** A record whose LLM pass failed
    /// can be hand-edited: `saveEditing` passes `llmProcessingStatus`
    /// straight through, the pencil button is not gated on it, and
    /// `updateRecord` derives the marker independently of status. So the
    /// state is reachable in three taps, today.
    ///
    /// Which makes this filter **load-bearing rather than
    /// belt-and-braces**. Step 4 retries every `.failed` record, sending
    /// its text to the LLM, and `processWithLLM` writes the result over
    /// `content`. For a hand-edited record that is the exact data loss
    /// this feature shipped: the user reconnects and their text is
    /// replaced. Excluding it is the locked decision doing real work
    /// (ADR-0005).
    ///
    /// The narrower claim that IS true: no `processWithLLM` failure branch
    /// writes `optimizedContent` — its only assignment there is in the
    /// success branch, which also sets `.completed`. A failure never
    /// manufactures a marker; only a later hand edit does.
    ///
    /// The trap is symmetric. An agent who believes the false invariant and
    /// enforces it in `updateRecord` by stripping the marker when status
    /// is `.failed` re-arms the original bug — the edit looks protected
    /// at the moment it is being unprotected. The invariant is a
    /// consequence of who writes the field, not a target to enforce.
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

    // MARK: - Recovery candidates

    /// The records a recovery sweep should act on, split by the step that
    /// acts on them.
    ///
    /// One source for both sweeps — the launch sweep and the
    /// network-recovery sweep. Two sweeps that computed their own
    /// candidates would drift, and the drift would be invisible: the
    /// network sweep would keep looking right while the launch sweep
    /// quietly skipped (or double-processed) something.
    struct RecoveryCandidates: Equatable {
        /// Records whose LLM pass was never attempted.
        let neverProcessed: [TranscriptionRecord]
        /// Records whose LLM pass did not finish: it failed, or it was
        /// interrupted — the app was killed mid-call, leaving the status
        /// at `.processing` with nothing in flight to finish it.
        let unfinishedLLM: [TranscriptionRecord]
        /// Records whose transcript is missing or failed, and whose audio
        /// is still on disk.
        let recognitionRetry: [TranscriptionRecord]

        /// Every record that wants an LLM pass, in the order the sweep
        /// should visit them.
        var llmWork: [TranscriptionRecord] { neverProcessed + unfinishedLLM }
    }

    /// How many records the launch-time recovery sweep sends to the LLM in
    /// one launch.
    ///
    /// The launch sweep is unattended, so its cost has to be bounded. A
    /// network recovery happens while the user is sitting there waiting
    /// for the result, and an unbounded sweep there is a surprise they
    /// can see coming; at launch there is nobody to see it.
    static let launchLLMLimit = 10

    /// The candidates for one recovery sweep.
    ///
    /// - Parameter llmLimit: cap on the number of records sent to the LLM
    ///   in this sweep. `nil` means no cap. The cap does **not** apply to
    ///   `recognitionRetry`: re-recognition is Apple's speech service, not
    ///   a paid API, and ADR-0005 §4.6 requires retries to be unlimited.
    static func recoveryCandidates(
        from records: [TranscriptionRecord],
        llmLimit: Int? = nil
    ) -> RecoveryCandidates {
        let pool = llmPool(from: records, limit: llmLimit)
        return RecoveryCandidates(
            neverProcessed: pool.filter { $0.llmProcessingStatus == nil },
            unfinishedLLM: pool.filter {
                $0.llmProcessingStatus == .failed || $0.llmProcessingStatus == .processing
            },
            recognitionRetry: recognitionRetryQueue(from: records)
        )
    }

    /// The records waiting for an LLM pass: never attempted, failed, or
    /// interrupted.
    ///
    /// All three are the same kind of work — "this record still needs its
    /// LLM pass" — so a cap treats them as one pool.
    ///
    /// `.processing` is in the pool because it is a status nothing will
    /// ever move again: the app was killed between writing `.processing`
    /// and writing the outcome, and no queue in the app looks at it. Left
    /// out, that record's title and summary would never be filled in.
    /// The `isHandEdited` exclusion covers the case where the LLM call
    /// actually *did* succeed and only the status write was lost — such a
    /// record has `optimizedContent` set, so it is excluded anyway.
    ///
    /// `limit == nil` returns the pool in input order. That is the
    /// network-recovery sweep's existing behaviour and it must not shift.
    /// A limit sorts oldest-first: the records that have been waiting
    /// longest go first, and the ones the cap skips are the most recent —
    /// the ones the user is most likely to still care about, and most
    /// likely to be picked up by the next launch anyway.
    static func llmPool(
        from records: [TranscriptionRecord],
        limit: Int?
    ) -> [TranscriptionRecord] {
        let pending = llmQueue(from: records).filter {
            $0.llmProcessingStatus == nil
                || $0.llmProcessingStatus == .failed
                || $0.llmProcessingStatus == .processing
        }
        guard let limit else { return pending }
        return Array(pending.sorted { $0.createdAt < $1.createdAt }.prefix(limit))
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
    /// **This returns `record.content`, always.** That is provable, not
    /// incidental: `isHandEdited` true → `content`; false → either
    /// `optimizedContent == nil` (so `?? content` yields `content`) or
    /// `content == optimizedContent` (so it yields a string equal to
    /// `content`). There is no record for which the expression below
    /// returns anything other than `content`.
    ///
    /// It is kept anyway, deliberately. The idiom it replaces,
    /// `record.optimizedContent ?? record.content`, reads as the obvious
    /// correct thing to do and is what five call sites used. It was correct
    /// only while `optimizedContent` held nothing but a pre-LLM original.
    /// Now it also holds *the text from before the user's last edit*, and
    /// the naive resolution sends that pre-edit text to the LLM —
    /// `processWithLLM` then writes the answer over the user's own text.
    /// That was the HIGH finding, and it is silent: nothing about the
    /// expression looks wrong.
    ///
    /// So the helper exists to make `optimizedContent ?? content`
    /// **unreintroducible** at the five sites that resolve LLM input. Five
    /// bare `record.content` reads would each be correct and would carry no
    /// statement of why the obvious idiom is wrong; the first reader to
    /// "fix" one of them reopens the HIGH.
    ///
    /// **Delete this helper** if it is ever reduced to identity *and* all
    /// five call sites are replaced by a comment that records why the
    /// idiom must not come back. Identity alone is not a reason to keep
    /// it; the note is the reason.
    static func llmInputText(for record: TranscriptionRecord) -> String {
        isHandEdited(record) ? record.content : (record.optimizedContent ?? record.content)
    }

    /// The `optimizedContent` a record should carry after `updateRecord`.
    ///
    /// A record the user has hand-typed into has to stay that way. This
    /// derivation is the only thing that makes the `optimizedContent !=
    /// content` rule fire for a hand edit, and it used to carry
    /// `optimizedContent` forward only — a pending record has empty
    /// `content` and `nil optimizedContent`, so after the user typed into
    /// the detail page both were still nil, the rule could not fire, and
    /// the next network recovery overwrote what they wrote. Stashing the
    /// *pre-edit* content as the marker is what makes the rule fire.
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

    /// The record `updateRecord` should write for `incoming`.
    ///
    /// Extracted as a pure static for the same reason as `classify` and
    /// `handEditMarker`: `updateRecord` reaches `TranscriptionStorage`
    /// through the view model's private singleton, so the *decision* has to
    /// be separated from the write to be testable at all. Everything the
    /// derivation decides lives here; the view model only performs the write.
    ///
    /// Two rules, and they apply per field:
    ///
    /// - **Believe the caller** for the fields it states. `content` is
    ///   always taken from `incoming` — the caller is describing the text,
    ///   and the text is the point of the update. `duration` and `language`
    ///   are taken from `incoming` too, for the same reason; neither is
    ///   carried forward, because no caller states a duration it does not
    ///   mean.
    /// - **Carry forward** what the caller does not state. Every optional
    ///   field is `incoming ?? existing`: `createdAt`, `audioFileName`,
    ///   `recognitionMode`, `archivedAt`, and the LLM fields. These are
    ///   facts about the *record*, not about the edit, and a caller that
    ///   only knows about the text does not carry them. Dropping
    ///   `createdAt` reorders the library; dropping `audioFileName` breaks
    ///   playback; dropping `archivedAt` un-dates the archive.
    ///
    /// `archived` is the one exception to the `??` shape, because a `Bool`
    /// cannot be "unstated": `false` is a value, and treating it as one
    /// would make it impossible to un-archive through this path. It is
    /// `incoming.archived || existing.archived` instead — either side may
    /// archive, and un-archiving is `unarchiveRecord`, which writes
    /// straight to storage rather than through here.
    ///
    /// The LLM fields — `title`, `summary`, `tags`, `llmProcessingStatus` —
    /// are what this function exists for. A caller that re-sends the text
    /// without re-sending the metadata is not asking for the metadata to be
    /// deleted; it simply does not know about it.
    ///
    /// Why this matters more than it looks: `handEditMarker` puts the
    /// pre-edit text into `optimizedContent`, so an edited record satisfies
    /// `isHandEdited` and is **permanently excluded from `llmQueue`**. No
    /// automatic sweep will ever restore a title or a tag that was dropped
    /// at write time. The loss is therefore not cosmetic and not
    /// self-healing — the only way back is the user tapping 重试 by hand.
    static func mergedRecord(incoming: TranscriptionRecord,
                             existing: TranscriptionRecord?) -> TranscriptionRecord {
        let marker = handEditMarker(incoming: incoming, existing: existing)

        return TranscriptionRecord(
            id: incoming.id,
            content: incoming.content,
            createdAt: existing?.createdAt ?? incoming.createdAt,
            duration: incoming.duration,
            language: incoming.language,
            audioFileName: incoming.audioFileName ?? existing?.audioFileName,
            title: incoming.title ?? existing?.title,
            summary: incoming.summary ?? existing?.summary,
            tags: incoming.tags ?? existing?.tags,
            llmProcessingStatus: incoming.llmProcessingStatus ?? existing?.llmProcessingStatus,
            optimizedContent: marker,
            recognitionMode: incoming.recognitionMode ?? existing?.recognitionMode,
            archived: incoming.archived || (existing?.archived ?? false),
            archivedAt: incoming.archivedAt ?? existing?.archivedAt
        )
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

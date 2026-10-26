import Foundation
import Combine
import SwiftUI

/// Why the library has no records to show, when the reason is not
/// "the library is empty".
///
/// A library that has never been written is a normal state and renders
/// as the ordinary empty state. Every other reason for an empty list
/// must be rendered differently, because they say completely different
/// things: "your data is gone" and "your audio is still here" cannot
/// share a screen.
enum RecordsAbsentReason: Equatable {
    /// `transcriptions.json` is there but could not be decoded.
    case corrupted
    /// The file could not be read at all (permissions, I/O, a provider
    /// that isn't answering).
    case unreadable(String)
    /// The records file is gone, but `count` audio files are still in
    /// `Recordings/`. The library was removed from outside the app; the
    /// recordings it pointed at are not lost.
    case orphanedAudio(count: Int)
}

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var partialText = ""
    @Published var recordingDuration: TimeInterval = 0
    @Published var historyRecords: [TranscriptionRecord] = []
    @Published var currentRecordId: UUID?
    @Published var authorizationStatus: PermissionStatus = .notDetermined
    @Published var errorMessage: String?
    /// Set when the library has no records for a reason other than
    /// "there are none". `nil` means "read fine" — including the case of
    /// a library that is simply empty.
    @Published var recordsAbsentReason: RecordsAbsentReason?
    @Published var selectedLanguage: RecognitionLanguage = .chinese
    @Published var isOptimizing: Bool = false
    @Published var isLLMProcessing: Bool = false
    @Published var llmProcessingFailed: Bool = false
    @Published var isTextOptimized: Bool = false
    @Published var recognitionMode: RecognitionMode = .online
    @Published var isEnhancing: Bool = false

    /// True while a recovery sweep is running.
    ///
    /// The launch sweep and the network-recovery sweep can overlap — the
    /// app launches offline, the network comes back mid-sweep — and the
    /// same record processed twice means two LLM calls and two writes.
    private var isRecovering = false

    /// True while a **background** recovery sweep is running.
    ///
    /// `processWithLLM` is the single LLM choke point, so a sweep sets
    /// `isLLMProcessing` and `llmProcessingFailed`. Those are UI signals
    /// meaning "you asked for this, here is the outcome" — but they are
    /// global, not per record. A sweep processing record #37 would
    /// replace the recording screen's transcript area with a spinner about
    /// somebody else's record, and replace the detail view's LLM button
    /// with a disabled one. The app would be reporting its own
    /// housekeeping as the user's request.
    @Published private(set) var isBackgroundRecovery: Bool = false

    /// Whether the user is waiting on an LLM result they asked for.
    ///
    /// The views read this instead of `isLLMProcessing`, so a background
    /// sweep does not take the UI hostage.
    var isAwaitingUserLLMResult: Bool {
        isLLMProcessing && !isBackgroundRecovery
    }

    /// Whether an LLM failure the user should hear about has happened.
    ///
    /// The flag itself is sticky, so a failure raised during a sweep
    /// surfaces once the sweep ends — it is not swallowed, only delayed.
    var hasUserFacingLLMFailure: Bool {
        llmProcessingFailed && !isBackgroundRecovery
    }

    // MARK: - Library filter state (思录)
    @Published var searchQuery: String = ""
    @Published var selectedTags: Set<String> = []

    /// Which side of the archive split the library list is showing. `false`
    /// (the default) is the live list; `true` shows archived records only,
    /// filtered and sorted exactly the way the live list is. Toggling leaves
    /// `searchQuery` and `selectedTags` untouched — see `availableTags` for how
    /// a filter that matches nothing on the far side stays visible.
    @Published var isArchiveMode: Bool = false

    private let speechRecognizer = SpeechRecognizer()
    private let storage = TranscriptionStorage.shared
    private let permissionsManager = PermissionsManager.shared
    private let llmService = LLMService()
    private let relatedNotesService = RelatedNotesService()
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private var textStreamTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var networkRecoveryTask: Task<Void, Never>?
    private let networkRecoveryDebounce: UInt64 = 2_000_000_000  // 2 seconds

    init() {
        Logger.info("TranscriptionViewModel initialized")

        // Combine sinks only fire on changes, not on the current value at
        // subscription time. If the user has already granted both
        // permissions in a previous session, `permissionsManager.*Status`
        // is already `.authorized` at VM construction — but no event will
        // fire to push that into our `authorizationStatus`. Poll once
        // synchronously to seed the right value.
        updateAuthorizationStatus()

        // Observe permission changes
        permissionsManager.$speechAuthorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAuthorizationStatus()
            }
            .store(in: &cancellables)

        permissionsManager.$microphoneAuthorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAuthorizationStatus()
            }
            .store(in: &cancellables)

        Task { @MainActor in
            await loadHistory()
            loadSavedLanguage()
        }
        setupNetworkMonitor()
        observeStorageReadiness()
    }

    /// Run the launch recovery sweep as soon as the data folder is
    /// reachable.
    ///
    /// The sweep is triggered by the storage becoming ready rather than by
    /// a timer or by the view appearing, because "ready" is the only
    /// moment the records are actually loadable — and it covers the case
    /// a timer would miss: the user reinstalls the app, picks the same
    /// folder, and the records stranded in it should recover right then,
    /// not at some future launch.
    ///
    /// `removeDuplicates()` matters: `bootstrap()` can run twice (the
    /// view's `onAppear` and `loadHistory` both call it), and two sweeps
    /// would process two batches of records per launch instead of one.
    private func observeStorageReadiness() {
        StorageCoordinator.shared.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard state == .ready else { return }
                Task { @MainActor in
                    // The profiles first: the sweep's LLM calls need an
                    // active profile, and the load is what migrates a
                    // pre-move install's profiles into the folder.
                    await ProviderProfileStore.shared.ensureLoaded()
                    await self?.recoverStrandedRecords()
                }
            }
            .store(in: &cancellables)
    }

    private func setupNetworkMonitor() {
        NetworkMonitor.shared.onStatusChange = { [weak self] isConnected in
            guard let self = self, isConnected else { return }
            // Debounce: cancel previous pending task
            self.networkRecoveryTask?.cancel()
            self.networkRecoveryTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: self.networkRecoveryDebounce)
                guard !Task.isCancelled else { return }
                await self.networkDidRecover()
            }
        }
    }

    private func loadSavedLanguage() {
        if let savedLanguage = UserDefaults.standard.string(forKey: "audioNote:lastUsedLanguage"),
           let language = RecognitionLanguage(rawValue: savedLanguage) {
            selectedLanguage = language
            Logger.info("Loaded saved language: \(language.displayName)")
        }
    }

    private func saveLanguage() {
        UserDefaults.standard.set(selectedLanguage.rawValue, forKey: "audioNote:lastUsedLanguage")
        Logger.debug("Saved language: \(selectedLanguage.displayName)")
    }

    func updateAuthorizationStatus() {
        let newStatus = permissionsManager.isAllAuthorized ? .authorized : permissionsManager.speechAuthorizationStatus
        guard newStatus != authorizationStatus else { return }
        authorizationStatus = newStatus
        Logger.info("Authorization status updated: \(newStatus)")
    }

    func requestPermissions() async {
        Logger.info("Requesting permissions")
        let granted = await PermissionsManager.shared.requestAllPermissions()
        await MainActor.run {
            updateAuthorizationStatus()
        }
        Logger.info("Permissions granted: \(granted)")
    }

    func setLanguage(_ language: RecognitionLanguage) {
        guard !isRecording else {
            Logger.warning("Cannot change language while recording")
            return
        }
        selectedLanguage = language
        saveLanguage()
        speechRecognizer.setRecognitionLanguage(language)
        Logger.info("Language set to: \(language.displayName)")
    }

    func startRecording() async {
        updateAuthorizationStatus()

        // Request permissions if not determined
        if authorizationStatus != .authorized {
            Logger.info("Not authorized, requesting permissions")
            await requestPermissions()

            // Check again after permission request
            updateAuthorizationStatus()
            guard authorizationStatus == .authorized else {
                Logger.info("Permissions still not granted after request")
                return
            }
        }

        do {
            // Generate a new record ID at the start of recording
            currentRecordId = UUID()
            Logger.info("Starting new recording with ID: \(currentRecordId!.uuidString)")

            // Set language before starting
            speechRecognizer.setRecognitionLanguage(selectedLanguage)
            Logger.info("Starting recording with language: \(selectedLanguage.displayName)")

            isRecording = true
            recordingStartTime = Date()
            recordingDuration = 0
            transcribedText = ""
            partialText = ""
            isTextOptimized = false

            startDurationTimer()

            let textStream = try await speechRecognizer.startRecording()

            Logger.info("Speech recognition stream started")

            textStreamTask = Task { @MainActor in
                for await text in textStream {
                    Logger.debug("Received text: \(text)")
                    partialText = text
                }
            }

            recognitionMode = speechRecognizer.recognitionMode
            Logger.info("Recognition mode: \(speechRecognizer.recognitionMode)")
        } catch {
            Logger.error("Failed to start recording: \(error.localizedDescription)")
            isRecording = false
            currentRecordId = nil
            errorMessage = error.localizedDescription
            stopDurationTimer()
        }
    }

    func stopRecording() async {
        Logger.info("Stopping recording")

        textStreamTask?.cancel()
        textStreamTask = nil

        let finalText = speechRecognizer.getFinalText()
        Logger.info("Final text from recognizer: \(finalText)")

        let contentToSave = finalText.isEmpty ? partialText : finalText
        let trimmedContent = contentToSave.trimmingCharacters(in: .whitespacesAndNewlines)

        // Decide whether this recording is worth persisting. A recognizer
        // failure with no text still is: the audio is already on disk, and
        // before this the record was simply dropped, stranding the .m4a
        // with nothing referencing it (spec §4.2).
        //
        // Both reads happen before the teardown below on purpose:
        // `SpeechRecognizer.stopRecording()` rewrites `recognitionMode` to
        // `.failed` when it ends on an error with no text — the one branch
        // where `classify` ignores `recognizerMode` and returns `.pending`,
        // so the pre-teardown value is the one that is used.
        let outcome = PendingRecognitionPolicy.classify(
            hasRecognitionError: speechRecognizer.hasRecognitionError,
            trimmedContent: trimmedContent,
            recognizerMode: speechRecognizer.recognitionMode
        )

        // Teardown runs on *every* path out of this method, discard
        // included: `isRecording` is only cleared here and in `startRecording`,
        // so returning early without it leaves the UI calling `stopRecording`
        // on every subsequent tap and the user unable to record again.
        speechRecognizer.stopRecording()
        isRecording = false
        stopDurationTimer()

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

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? recordingDuration
        let audioFileName = speechRecognizer.getAudioFileName()

        let record = TranscriptionRecord(
            id: currentRecordId ?? UUID(),
            // `trimmedContent`, not `contentToSave`: on the `.pending` path
            // `contentToSave` is whitespace-only, and spec §4.2 persists
            // `content = ""`. Downstream emptiness checks must not have to
            // trim first. `assessAndEnhance` still gets `contentToSave`.
            content: trimmedContent,
            createdAt: recordingStartTime ?? Date(),
            duration: duration,
            language: selectedLanguage.rawValue,
            audioFileName: audioFileName,
            recognitionMode: mode
        )

        transcribedText = contentToSave

        do {
            try await storage.save(record)
            Logger.info("Record saved with ID: \(record.id.uuidString), mode: \(mode)")
            await loadHistory()

            // Phase 2: Assess and potentially enhance
            await assessAndEnhance(record: record, originalText: contentToSave)
        } catch {
            Logger.error("Failed to save record: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Phase 2: After saving, assess recognition quality and enhance if possible
    private func assessAndEnhance(record: TranscriptionRecord, originalText: String) async {
        switch record.recognitionMode {
        case .online:
            // Online recognition succeeded — go straight to LLM.
            // Provider / network gating happens inside processWithLLM.
            await processWithLLM(recordId: record.id, originalText: originalText)

        case .onDevice:
            // On-device succeeded. LLM will improve the text once we have
            // a Provider and network; skip separate enhanceRecognition since
            // processWithLLM overwrites content anyway.
            if NetworkMonitor.shared.checkConnectivity() {
                await processWithLLM(recordId: record.id, originalText: originalText)
            }
            // Offline: do nothing; raw text already saved.

        case .failed:
            // Recognition failed — try online re-recognition if available
            if NetworkMonitor.shared.checkConnectivity() {
                await retryRecognitionFromFile(recordId: record.id)
            }

        case .pending:
            // Audio exists, transcript does not. Offline: wait for
            // `networkDidRecover` step 3. Online: recover immediately.
            // Never call `processWithLLM` here — `content` is empty, and
            // that is the hallucination path `llmQueue` also guards.
            if NetworkMonitor.shared.checkConnectivity() {
                await retryRecognitionFromFile(recordId: record.id)
            }

        default:
            break
        }
    }

    /// Re-recognize a record's audio using online recognition for better quality
    func enhanceRecognition(recordId: UUID) async {
        guard let record = try? await storage.get(id: recordId),
              let audioFileName = record.audioFileName else {
            Logger.warning("Cannot enhance: record or audio file not found")
            return
        }

        let audioFileId = audioFileName.replacingOccurrences(of: ".m4a", with: "")
        guard let uuid = UUID(uuidString: audioFileId) else {
            Logger.warning("Cannot enhance: invalid audio file name format")
            return
        }
        let audioURL = AudioRecorderService.generateFileUrl(for: uuid)

        // Check if user has edited the text — if so, don't overwrite
        if PendingRecognitionPolicy.isHandEdited(record) {
            Logger.info("Skipping auto-enhance: user has edited content")
            return
        }

        isEnhancing = true
        defer { isEnhancing = false }

        do {
            let enhancedText = try await speechRecognizer.recognizeFromFile(url: audioURL)

            // `recognizeFromFile` resumes on any *final* result, and a final
            // result can be empty — silence, noise, a truncated .m4a — without
            // throwing, so the `catch` below (whose comment is right about
            // keeping the original text) never runs for that case.
            //
            // This is worse than the same hole in `retryRecognitionFromFile`:
            // that record has nothing to lose, but this one already holds a
            // real on-device transcript. Writing `""` over it destroys text the
            // user had, and stamping `.enhanced` makes the loss look like a
            // success. Returning here leaves both `record.content` and
            // `record.recognitionMode` untouched; the record simply stays
            // `.onDevice` and the next network recovery tries again.
            // `defer` above clears `isEnhancing` on this path.
            guard PendingRecognitionPolicy.isLLMEligible(text: enhancedText) else {
                Logger.warning(
                    "Enhance recognition returned empty text for \(recordId); "
                    + "keeping the original transcript"
                )
                return
            }

            Logger.info("Enhanced recognition succeeded for record \(recordId)")
            recognitionMode = .enhanced

            var updated = record
            updated.content = enhancedText
            updated.recognitionMode = .enhanced
            try await storage.save(updated)

            transcribedText = enhancedText
            await loadHistory()
        } catch {
            Logger.error("Enhance recognition failed: \(error.localizedDescription)")
            // Keep original on-device text, don't change mode
        }
    }

    /// Retry recognition from saved audio file after a failure
    func retryRecognitionFromFile(recordId: UUID) async {
        guard let record = try? await storage.get(id: recordId),
              let audioFileName = record.audioFileName else {
            Logger.warning("Cannot retry: record or audio file not found")
            return
        }

        let audioFileId = audioFileName.replacingOccurrences(of: ".m4a", with: "")
        guard let uuid = UUID(uuidString: audioFileId) else {
            Logger.warning("Cannot retry: invalid audio file name format")
            return
        }
        let audioURL = AudioRecorderService.generateFileUrl(for: uuid)

        do {
            let rawText = try await speechRecognizer.recognizeFromFile(url: audioURL)

            // `recognizeFromFile` resumes on any *final* result, and SFSpeech
            // happily produces a final result with an empty transcription for
            // silence, noise, or a truncated .m4a — without throwing. So a
            // non-throwing call is not a successful retry.
            //
            // Returning here without touching the record is the load-bearing
            // part: the mode stays `.pending` (or `.failed`), so the record
            // stays in `recognitionRetryQueue` and the next network recovery
            // tries again — the unlimited-retry behaviour spec D4 specifies.
            // Advancing the mode to `.enhanced` on an empty transcript would
            // both hand `""` to the LLM and drop the record out of the retry
            // queue for good, leaving a genuinely recoverable recording stuck
            // with no way back.
            guard PendingRecognitionPolicy.isLLMEligible(text: rawText) else {
                Logger.warning(
                    "Retry recognition returned empty text for \(record.id); "
                    + "leaving mode as-is for a later retry"
                )
                return
            }

            var updated = record
            updated.content = rawText
            updated.recognitionMode = .enhanced
            try await storage.save(updated)

            transcribedText = rawText
            recognitionMode = .enhanced
            await loadHistory()

            // Now try LLM since we have text
            await processWithLLM(recordId: record.id, originalText: rawText)
        } catch {
            Logger.error("Retry recognition failed: \(error.localizedDescription)")
        }
    }

    func processWithLLM(recordId: UUID, originalText: String) async {
        // The choke point for the view model's own LLM routes, which are:
        // `assessAndEnhance` (.online and .onDevice arms),
        // `retryRecognitionFromFile`, `networkDidRecover` steps 1 and 4,
        // `retryLLM`, and the retry button at `RecordingView.swift:282`.
        //
        // It is NOT the choke point for the whole app.
        // `TranscriptionDetailView.reprocessRecord` is a separate route that
        // calls `LLMService.optimizeAndProcess` directly and carries its own
        // copy of this guard — a new call site must add one too. The durable
        // fix, a guard inside `optimizeAndProcess` itself, is tracked as a
        // follow-up; it is deliberately not done here.
        //
        // This guard is deliberately independent of the `.pending` exclusion
        // in `llmQueue`, which is a record-level filter and cannot see text —
        // nor can it help `retryLLM`, which has no mode filter at all.
        //
        // Empty in, hallucination out: the model does not answer `""`, it
        // answers a confident title, summary and tag list, which are then
        // written over the record.
        guard PendingRecognitionPolicy.isLLMEligible(text: originalText) else {
            Logger.warning("Skipping LLM: empty text for record \(recordId)")
            return
        }

        isLLMProcessing = true
        llmProcessingFailed = false

        // Pull the active profile + its API key from the store. The
        // profiles live in the data folder now, so the read is
        // asynchronous — without awaiting it, the first LLM call of a
        // session would find an empty list and skip itself.
        await ProviderProfileStore.shared.ensureLoaded()
        // If the user hasn't configured one yet, skip silently — the LLM
        // path is opt-in.
        guard let profile = ProviderProfileStore.shared.active else {
            Logger.warning("LLM processWithLLM skipped: no active profile")
            isLLMProcessing = false
            return
        }
        let apiKey = ProviderProfileStore.shared.apiKey(for: profile.id)

        // If offline, mark as failed immediately and wait for recovery
        guard NetworkMonitor.shared.checkConnectivity() else {
            Logger.warning("LLM processWithLLM skipped: offline")
            isLLMProcessing = false
            llmProcessingFailed = true
            if var record = try? await storage.get(id: recordId) {
                record.llmProcessingStatus = .failed
                try? await storage.save(record)
            }
            return
        }

        // LLMService owns the retry loop now (3x exponential backoff for
        // 5xx + network errors). This view-model layer only handles the
        // success/fail outcome and the offline edge case.
        do {
            let result = try await llmService.optimizeAndProcess(
                originalText,
                profile: profile,
                apiKey: apiKey,
                existingTags: existingTagVocabulary
            )
            Logger.info("LLM processWithLLM succeeded")

            if var record = try? await storage.get(id: recordId) {
                record.optimizedContent = originalText
                record.content = result.optimizedText
                record.title = result.title
                record.summary = result.summary
                record.tags = result.tags
                record.llmProcessingStatus = .completed
                try await storage.save(record)

                transcribedText = result.optimizedText
                isTextOptimized = true
                await loadHistory()
            }

            isLLMProcessing = false
            llmProcessingFailed = false

            // Relations are best-effort: `link(for:)` never throws and never
            // surfaces an error.
            //
            // Deliberately last, after the UI updates. While `isLLMProcessing`
            // is true `RecordingView` replaces the whole transcript card with
            // a `ProgressView` and the detail view disables its re-process
            // button, so awaiting any earlier would hide call 1's
            // already-produced text for the length of a second LLM round trip
            // (1–3s, with retries) — on exactly the screen this feature exists
            // to serve, and against spec §8's promise that the user never sees
            // the second request. By here the note is saved and its text is
            // on screen; the 相关思考 section re-reads the file on every
            // appear, so the only cost of a slow link is a briefly-empty
            // section, which is self-healing on the next look.
            //
            // Still inside the `do`, so a call-1 failure takes the `catch` and
            // skips this — correct, since without an optimized title and
            // summary there is nothing to compare against.
            await relatedNotesService.link(for: recordId)
        } catch let error as LLMError {
            Logger.warning("LLM processWithLLM failed: \(error.errorDescription ?? "unknown")")

            if case .offline = error {
                // Don't retry on offline — mark failed, wait for network recovery
                isLLMProcessing = false
                llmProcessingFailed = true
                if var record = try? await storage.get(id: recordId) {
                    record.llmProcessingStatus = .failed
                    try? await storage.save(record)
                }
                return
            }

            Logger.error("LLM processWithLLM failed after retries")
            isLLMProcessing = false
            llmProcessingFailed = true

            if var record = try? await storage.get(id: recordId) {
                record.llmProcessingStatus = .failed
                try? await storage.save(record)
            }
        } catch {
            Logger.warning("LLM processWithLLM failed (non-LLMError): \(error.localizedDescription)")
            isLLMProcessing = false
            llmProcessingFailed = true
            if var record = try? await storage.get(id: recordId) {
                record.llmProcessingStatus = .failed
                try? await storage.save(record)
            }
        }
    }

    /// Called when network transitions from disconnected → connected (debounced)
    func networkDidRecover() async {
        Logger.info("Network recovered — processing pending items")
        // No LLM cap here. The user is present for this one, and a
        // backlog they are waiting on should clear in one go; capping it
        // would mean toggling the network once per batch. The launch
        // sweep, which nobody is waiting for, is the one that is capped.
        await runRecoverySweep(includeOnDeviceUpgrade: true, llmLimit: nil)
    }

    /// Recover what the previous session left unfinished.
    ///
    /// A `.pending` record (audio on disk, no transcript) or a record
    /// whose LLM pass failed while the app was offline used to wait
    /// indefinitely: the only trigger for recovery was a
    /// disconnected→connected transition, so a record stranded yesterday
    /// was still stranded today unless the user happened to toggle the
    /// network during this session. Relaunching with a working network
    /// did nothing at all.
    ///
    /// This is the missing trigger. It runs the same steps as the
    /// network sweep — from the same candidate function, so the two
    /// cannot drift — minus the on-device upgrade (step 2), which is an
    /// improvement rather than a recovery.
    func recoverStrandedRecords() async {
        Logger.info("Launch recovery — sweeping for stranded records")
        await runRecoverySweep(
            includeOnDeviceUpgrade: false,
            llmLimit: PendingRecognitionPolicy.launchLLMLimit
        )
    }

    /// The shared body of the two recovery sweeps.
    ///
    /// - Parameters:
    ///   - includeOnDeviceUpgrade: step 2, which re-recognizes on-device
    ///     records online. The network sweep does it; the launch sweep
    ///     does not — an on-device record already has a transcript, so
    ///     upgrading it is an improvement rather than a recovery, and it
    ///     would put an online recognition request on every launch.
    ///   - llmLimit: cap on the records sent to the LLM in this sweep.
    ///     `nil` means no cap.
    private func runRecoverySweep(
        includeOnDeviceUpgrade: Bool,
        llmLimit: Int?
    ) async {
        // Two sweeps must never run at once. The launch sweep can still
        // be in flight when the network comes back and the network sweep
        // starts, and the same record processed twice means two LLM calls
        // and two writes.
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }

        // The data directory has to be reachable. A `.unreachable` state
        // can leave a stale `resolvedRoot` behind, and recovering against
        // a folder the user is no longer using is worse than not
        // recovering at all (ADR-0007).
        guard StorageCoordinator.shared.state == .ready else {
            Logger.warning("Recovery sweep skipped: storage is not ready")
            return
        }
        // Every step below needs the network.
        guard NetworkMonitor.shared.checkConnectivity() else { return }

        isBackgroundRecovery = true
        defer { isBackgroundRecovery = false }

        let records = (try? await storage.loadAll()) ?? []
        let candidates = PendingRecognitionPolicy.recoveryCandidates(
            from: records,
            llmLimit: llmLimit
        )

        // 1. Process records never LLM-processed
        for record in candidates.neverProcessed {
            guard NetworkMonitor.shared.checkConnectivity() else { return }
            let text = PendingRecognitionPolicy.llmInputText(for: record)
            await processWithLLM(recordId: record.id, originalText: text)
        }

        // 2. Upgrade on-device recognitions (network sweep only)
        if includeOnDeviceUpgrade {
            let onDeviceRecords = records.filter {
                $0.recognitionMode == .onDevice && $0.audioFileName != nil
            }
            for record in onDeviceRecords {
                guard NetworkMonitor.shared.checkConnectivity() else { return }
                await enhanceRecognition(recordId: record.id)
            }
        }

        // 3. Retry failed and never-completed recognitions
        for record in candidates.recognitionRetry {
            guard NetworkMonitor.shared.checkConnectivity() else { return }
            await retryRecognitionFromFile(recordId: record.id)
        }

        // 4. Retry LLM passes that failed (offline) or never finished
        //    (the app was killed mid-call, leaving the status at
        //    `.processing`)
        for record in candidates.unfinishedLLM {
            guard NetworkMonitor.shared.checkConnectivity() else { return }
            let text = PendingRecognitionPolicy.llmInputText(for: record)
            await processWithLLM(recordId: record.id, originalText: text)
        }

        await loadHistory()
    }

    /// Manually trigger online re-recognition for a record (from UI)
    func reRecognizeOnline(recordId: UUID) async {
        guard let record = try? await storage.get(id: recordId) else { return }

        if record.audioFileName != nil {
            await retryRecognitionFromFile(recordId: recordId)
        }
    }

    /// Manually retry LLM processing for a record (from UI)
    func retryLLM(recordId: UUID) async {
        guard let record = try? await storage.get(id: recordId) else { return }
        let text = PendingRecognitionPolicy.llmInputText(for: record)
        await processWithLLM(recordId: recordId, originalText: text)
    }

    func loadHistory() async {
        if !StorageCoordinator.shared.isReady {
            await StorageCoordinator.shared.bootstrap()
        }
        // If bootstrap didn't resolve a bookmark (first launch, no folder picked yet),
        // `StorageCoordinator.rootURL` would trap. Bail until the user picks a
        // folder via OnboardingView. The gate in ContentView keeps OnboardingView
        // visible until `isReady` flips, and any subsequent loadHistory call after
        // a successful re-pick will reach the body below.
        guard StorageCoordinator.shared.isReady else { return }
        Logger.debug("Loading history")
        switch await storage.loadOutcome() {
        case .noFile:
            // Nothing has ever been written. A genuinely empty library —
            // the empty state in the list is the honest rendering.
            historyRecords = []
            recordsAbsentReason = nil
        case .noFileButAudioRemains(let count):
            // The records file is gone but the audio is not. Saying
            // "you haven't recorded anything" here would be the single
            // most misleading thing the app could say.
            historyRecords = []
            recordsAbsentReason = .orphanedAudio(count: count)
            Logger.warning("Records file is missing but \(count) audio file(s) remain")
        case .records(let records):
            historyRecords = records
            recordsAbsentReason = nil
            Logger.info("Loaded \(records.count) records")
        case .corrupted(let error):
            // The file is there but unreadable. This is NOT an empty
            // library, and rendering it as one is how the user ends up
            // believing their data is gone. Say so instead.
            historyRecords = []
            recordsAbsentReason = .corrupted
            Logger.error("Records file is corrupted: \(error.localizedDescription)")
        }
    }

    func deleteRecord(id: UUID) {
        Logger.info("Deleting record: \(id.uuidString)")
        historyRecords.removeAll { $0.id == id }
        Task {
            do {
                try await storage.delete(id: id)
                // Related edges go with the note. Inside the `do`, not after
                // it: a delete that failed leaves the note in place, and
                // dropping its edges then would lose relations spec §4.4 says
                // are never recomputed. `unlink` never throws and never
                // surfaces, so a failure inside it only leaves edges the render
                // path filters out.
                //
                // It runs on the service (not a direct
                // `RelatedNotesStorage.shared` call) so it shares the service's
                // gate with `link(for:)` and a delete concurrent with a link
                // cannot lose an edge permanently.
                //
                // Archive deliberately does NOT do this — an archived note
                // keeps its edges and is filtered at render time, so
                // unarchiving restores its relations for free (spec §5.8).
                await relatedNotesService.unlink(recordId: id)
            } catch {
                Logger.error("Failed to delete record: \(error.localizedDescription)")
            }
        }
    }

    func getRecord(id: UUID) async -> TranscriptionRecord? {
        try? await storage.get(id: id)
    }

    func updateRecord(_ record: TranscriptionRecord) async throws {
        // The derivation — which fields are carried forward, which are
        // believed, and how the hand-edit marker is derived — lives in
        // `PendingRecognitionPolicy.mergedRecord`, next to the other
        // decisions this class cannot be tested around. This method only
        // reads the stored record and performs the write.
        let existingRecord = try await storage.get(id: record.id)
        let updatedRecord = PendingRecognitionPolicy.mergedRecord(
            incoming: record,
            existing: existingRecord
        )
        try await storage.save(updatedRecord)
        await loadHistory()
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        let tenths = Int((recordingDuration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    // MARK: - Library filtering (思录)

    /// Records on the current side of the archive split. Archive mode is not a
    /// special case with its own rules — it is the same query against the other
    /// half of the library, so both halves share this one scope and every
    /// filter below stays identical across the toggle.
    private var recordsInScope: [TranscriptionRecord] {
        historyRecords.filter { $0.archived == isArchiveMode }
    }

    /// Records in scope that match the current search query and selected tags.
    /// Sort: tag-match-count desc → createdAt desc when tags are selected; otherwise createdAt desc.
    var displayedRecords: [TranscriptionRecord] {
        let selected = TagIdentity.matchingKeys(selectedTags)
        let matching = recordsInScope
            .filter { Self.matchesSearch($0, query: searchQuery) }
            .filter { record in
                selected.isEmpty
                    || TagIdentity.matchCount(ofNames: record.tagNames, in: selected) > 0
            }

        if selected.isEmpty {
            return matching.sorted { $0.createdAt > $1.createdAt }
        }
        return matching.sorted { lhs, rhs in
            let lhsCount = TagIdentity.matchCount(ofNames: lhs.tagNames, in: selected)
            let rhsCount = TagIdentity.matchCount(ofNames: rhs.tagNames, in: selected)
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// One chip per tag identity, from the records in scope.
    ///
    /// Records spell the same tag however the LLM felt like that day, so chips
    /// are grouped by `TagIdentity.key`: `Work` and `work` collapse into one
    /// chip instead of two that each find only their own spelling. The chip's
    /// displayed form is the spelling carried by the most records; ties go to
    /// the higher-scored one, then alphabetically, so the choice is
    /// deterministic rather than whatever happened to be iterated first.
    ///
    /// Order across chips is by the maximum relevance score across all records
    /// carrying the tag (descending), so the most "important" tags surface
    /// first; ties break alphabetically.
    var availableTags: [String] {
        struct ScoredTag { let name: String; let maxScore: Double; let count: Int }

        // Identity key -> spelling -> (best score on it, records carrying it).
        // Two dictionaries rather than one so a chip can be assembled from all
        // its spellings; both are keyed the same way and kept in step.
        var maxScores: [String: [String: Double]] = [:]
        var recordCounts: [String: [String: Int]] = [:]
        // Records per identity — the number the chip's badge shows, so the
        // order and the badge are the same number and cannot disagree.
        var identityCounts: [String: Int] = [:]

        // The search query narrows the chips, exactly as it already narrows
        // their badges. A chip that no matching record carries is a chip at
        // count 0; showing it next to a chip at count 12 and ordering them
        // by something else is how a row of chips stops meaning anything.
        for record in recordsInScope where Self.matchesSearch(record, query: searchQuery) {
            // Counted per record, so a record carrying both `Work` and `work`
            // contributes to each spelling's count without being counted twice
            // within one of them.
            var spellingsThisRecord: [String: Set<String>] = [:]
            for tag in record.tags ?? [] {
                // A tag that is nothing but whitespace normalizes to empty, and
                // an empty chip is an invisible pill the user cannot tap off.
                // Dropped here rather than rendered.
                let spelling = TagIdentity.normalized(tag.name)
                guard !spelling.isEmpty else { continue }
                let identity = TagIdentity.key(spelling)
                spellingsThisRecord[identity, default: []].insert(spelling)
                var group = maxScores[identity] ?? [:]
                group[spelling] = max(group[spelling] ?? -.infinity, tag.score)
                maxScores[identity] = group
            }
            for (identity, spellings) in spellingsThisRecord {
                // Once per record, not once per spelling: a record carrying
                // both `Work` and `work` is one record.
                identityCounts[identity, default: 0] += 1
                for spelling in spellings {
                    recordCounts[identity, default: [:]][spelling, default: 0] += 1
                }
            }
        }

        var chips: [ScoredTag] = []
        for (identity, spellings) in recordCounts {
            // `min(by:)` with a "preferred first" comparator picks the display
            // form; the guard is unreachable in practice but keeps the
            // optional non-fatal.
            guard let winner = spellings.keys.min(by: { lhs, rhs in
                let lhsCount = spellings[lhs] ?? 0
                let rhsCount = spellings[rhs] ?? 0
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                let lhsScore = maxScores[identity]?[lhs] ?? -.infinity
                let rhsScore = maxScores[identity]?[rhs] ?? -.infinity
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                // Last resort. Case-insensitive compare returns "same" for
                // `Work` vs `work` — exactly the pair this whole decision is
                // about — so ordering those would be left to `min(by:)`'s
                // iteration order, which is dictionary order and not stable
                // across runs. Raw `<` is arbitrary but deterministic.
                if lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame {
                    return lhs < rhs
                }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }) else { continue }
            chips.append(ScoredTag(
                name: winner,
                maxScore: maxScores[identity]?[winner] ?? -.infinity,
                count: identityCounts[identity] ?? 0
            ))
        }

        // Archive mode can be entered with tags selected against the live list
        // that no archived record carries. Rendering those at count 0 is what
        // makes an empty archive list explicable — without them the filter is
        // silently applied with nothing on screen to switch off. Matched by
        // identity so a selected `Work` is not re-added alongside a chip the
        // archive's own records already contributed as `work`.
        if isArchiveMode {
            for name in selectedTags {
                let identity = TagIdentity.key(name)
                guard !chips.contains(where: { TagIdentity.key($0.name) == identity }) else { continue }
                chips.append(ScoredTag(name: name, maxScore: -.infinity, count: 0))
            }
        }

        // Order by how many records carry the tag, descending. The score is
        // a tiebreak, not the primary key: a tag on one record with score
        // 0.95 is not more important than a tag on two hundred records with
        // score 0.3, and legacy string tags carry *pseudo* scores (1.0,
        // 0.75, 0.5, …) whose first tag is always 1.0 — so a score-first
        // order puts one legacy record's first tag above every tag the user
        // actually uses often.
        //
        // The count also makes the row *stable*: it moves only when records
        // are added or removed, where a max-score order moved whenever any
        // record's score changed — shifting chips out from under a finger
        // that was on its way to tap one.
        return chips
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if lhs.maxScore != rhs.maxScore { return lhs.maxScore > rhs.maxScore }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(\.name)
    }

    /// The tag names already in the library, most-used first, capped at
    /// `LLMService.maxTagVocabulary`. Handed to the LLM so a new record reuses
    /// an existing spelling instead of inventing a near-synonym — the only
    /// defence against `工作` / `工作项` / `工作会议` drifting apart, which
    /// chip merging cannot address because those are genuinely different
    /// strings.
    ///
    /// Whole library, not the live half: an archived record's tags are just as
    /// worth reusing. Casing is **not** unified here — the prompt asks for one
    /// spelling, and folding case would hide from the model the very drift it
    /// is being asked to avoid.
    var existingTagVocabulary: [String] {
        var counts: [String: Int] = [:]
        for record in historyRecords {
            for name in record.tagNames {
                let spelling = TagIdentity.normalized(name)
                guard !spelling.isEmpty else { continue }
                counts[spelling, default: 0] += 1
            }
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map(\.key)
            .prefix(LLMService.maxTagVocabulary)
            .map { $0 }
    }

    /// Per-tag-identity count of in-scope records that also match the current
    /// search query. Keyed by `TagIdentity.key`, so all spellings of one tag
    /// are summed into the single chip that represents them — a merged chip
    /// reading 2 beside two spellings reading 1 each would contradict itself.
    ///
    /// Read through `tagCount(for:)`, which takes the chip's display form.
    var tagCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for record in recordsInScope {
            guard Self.matchesSearch(record, query: searchQuery) else { continue }
            for identity in Set(record.tagNames.map(TagIdentity.key)) {
                counts[identity, default: 0] += 1
            }
        }
        return counts
    }

    /// Hits for a chip, given the chip's displayed name. 0 for a chip no
    /// in-scope record carries — which is the point of rendering those at all.
    func tagCount(for tag: String) -> Int {
        tagCounts[TagIdentity.key(tag)] ?? 0
    }

    /// Whether the current side of the archive split holds any record at all,
    /// ignoring filters. Distinguishes "this side is empty" from "your filters
    /// matched nothing" — including the case of archiving your last live
    /// record, which leaves the live list genuinely empty rather than filtered.
    var hasRecordsInScope: Bool {
        historyRecords.contains { $0.archived == isArchiveMode }
    }

    /// Every archived record, unfiltered. Drives the archive toggle's badge and
    /// the archive-mode title. Deliberately ignores `searchQuery` and
    /// `selectedTags`: "you have 12 archived" must not read as 0 just because
    /// the user typed something into the search box.
    var archivedRecordCount: Int {
        historyRecords.reduce(into: 0) { total, record in
            if record.archived { total += 1 }
        }
    }

    /// Whether the archive toggle accepts taps. It goes dead only when there
    /// is nothing to go to AND you are not already there: gating it on
    /// `archivedRecordCount == 0` alone strands the user, because deleting
    /// the last archived record while inside archive mode kills the one
    /// control that could leave it.
    var canToggleArchiveMode: Bool {
        isArchiveMode || archivedRecordCount > 0
    }

    func setSearchQuery(_ query: String) {
        searchQuery = query
    }

    /// Adds or removes a tag from the filter. Compared by identity, so
    /// re-selecting the same tag under a different spelling removes it
    /// instead of stacking a second, redundant entry.
    func toggleTag(_ tag: String) {
        if let existing = selectedTags.first(where: { TagIdentity.key($0) == TagIdentity.key(tag) }) {
            selectedTags.remove(existing)
        } else {
            selectedTags.insert(tag)
        }
    }

    /// Fold `sources` into `target` across the whole library, archived
    /// records included — "these are the same thing" is a fact, not a view.
    ///
    /// The `selectedTags` line below is **load-bearing and looks deletable**.
    /// Remove it and this breaks: filter by `工作项`, merge `工作项` into
    /// `工作`, and `selectedTags` still names a tag no record carries
    /// anymore. `displayedRecords` then matches nothing and the library
    /// renders **empty** — with no error, because the filter is behaving
    /// exactly as written against a name that no longer exists.
    ///
    /// After the remap the visible list may legitimately show *more*
    /// records than before: the target's own records now belong to the same
    /// filter, since they are the same tag. The guarantee is a superset —
    /// nothing on screen disappears and the list is never empty — not an
    /// unchanged count.
    func mergeTag(_ target: String, from sources: [String]) async {
        guard !sources.isEmpty else { return }

        // A merge that changes nothing should not rewrite the file. Cheap to
        // check against what is already loaded, and it is the difference
        // between "the user picked a tag and nothing happened" and "the app
        // rewrote 400 records to produce an identical file".
        let sourceKeys = TagIdentity.matchingKeys(Set(sources))
        let touchesSomething = historyRecords.contains { record in
            record.tags?.contains { sourceKeys.contains(TagIdentity.key($0.name)) } == true
        }
        guard touchesSomething else { return }

        do {
            try await storage.mergeTags(into: target, from: sources)
            selectedTags = TagMerger.remappedSelection(
                selectedTags, into: target, from: sources
            )
            await loadHistory()
        } catch {
            Logger.error("Tag merge failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func clearFilters() {
        searchQuery = ""
        selectedTags = []
    }

    /// Clear the tag selection but keep the search query. The tag picker
    /// clears tags and nothing else — clearing the search box out from
    /// under someone who opened it to pick a tag would be rude.
    func clearTagSelection() {
        selectedTags = []
    }

    /// Mark a record as archived and persist the change. The record leaves the live
    /// list and enters archive mode's list; `archivedRecordCount` updates.
    func archiveRecord(id: UUID) async {
        Logger.info("Archiving record: \(id.uuidString)")
        guard var record = try? await storage.get(id: id) else {
            Logger.warning("Cannot archive: record \(id.uuidString) not found")
            return
        }
        record.archived = true
        record.archivedAt = Date()
        do {
            try await storage.save(record)
            await loadHistory()
        } catch {
            Logger.error("Failed to save archived record: \(error.localizedDescription)")
        }
    }

    /// Restore an archived record to active state. The record reappears in
    /// `displayedRecords` if it matches current filters.
    func unarchiveRecord(id: UUID) async {
        Logger.info("Unarchiving record: \(id.uuidString)")
        guard var record = try? await storage.get(id: id) else {
            Logger.warning("Cannot unarchive: record \(id.uuidString) not found")
            return
        }
        record.archived = false
        record.archivedAt = nil
        do {
            try await storage.save(record)
            await loadHistory()
        } catch {
            Logger.error("Failed to save unarchived record: \(error.localizedDescription)")
        }
    }

    /// Case-insensitive substring match across title, summary, tags (joined), and content.
    /// Returns true when the query is empty (no filter active).
    private static func matchesSearch(_ record: TranscriptionRecord, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let haystack = [
            record.title ?? "",
            record.summary ?? "",
            record.tagNames.joined(separator: " "),
            record.content
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }
}

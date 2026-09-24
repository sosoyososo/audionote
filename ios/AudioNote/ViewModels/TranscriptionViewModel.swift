import Foundation
import Combine
import SwiftUI

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
    @Published var selectedLanguage: RecognitionLanguage = .chinese
    @Published var isOptimizing: Bool = false
    @Published var isLLMProcessing: Bool = false
    @Published var llmProcessingFailed: Bool = false
    @Published var isTextOptimized: Bool = false
    @Published var recognitionMode: RecognitionMode = .online
    @Published var isEnhancing: Bool = false

    // MARK: - Library filter state (思录)
    @Published var searchQuery: String = ""
    @Published var selectedTags: Set<String> = []

    private let speechRecognizer = SpeechRecognizer()
    private let storage = TranscriptionStorage.shared
    private let permissionsManager = PermissionsManager.shared
    private let llmService = LLMService()
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

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? recordingDuration
        let audioFileName = speechRecognizer.getAudioFileName()

        let record = TranscriptionRecord(
            id: currentRecordId ?? UUID(),
            content: contentToSave,
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
        if record.optimizedContent != nil && record.content != record.optimizedContent {
            Logger.info("Skipping auto-enhance: user has edited content")
            return
        }

        isEnhancing = true
        defer { isEnhancing = false }

        do {
            let enhancedText = try await speechRecognizer.recognizeFromFile(url: audioURL)
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
            let text = try await speechRecognizer.recognizeFromFile(url: audioURL)
            var updated = record
            updated.content = text
            updated.recognitionMode = .enhanced
            try await storage.save(updated)

            transcribedText = text
            recognitionMode = .enhanced
            await loadHistory()

            // Now try LLM since we have text
            await processWithLLM(recordId: record.id, originalText: text)
        } catch {
            Logger.error("Retry recognition failed: \(error.localizedDescription)")
        }
    }

    func processWithLLM(recordId: UUID, originalText: String) async {
        isLLMProcessing = true
        llmProcessingFailed = false

        // Pull the active profile + its API key from the store. If the user
        // hasn't configured one yet, skip silently — the LLM path is opt-in.
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
            let result = try await llmService.optimizeAndProcess(originalText, profile: profile, apiKey: apiKey)
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
        let records = (try? await storage.loadAll()) ?? []

        // 1. Process records never LLM-processed
        let pendingLLM = records.filter { $0.llmProcessingStatus == nil }
        for record in pendingLLM {
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

        // 3. Retry failed recognitions
        let failedRecords = records.filter {
            $0.recognitionMode == .failed && $0.audioFileName != nil
        }
        for record in failedRecords {
            guard NetworkMonitor.shared.checkConnectivity() else { return }
            await retryRecognitionFromFile(recordId: record.id)
        }

        // 4. Retry failed LLM (that failed due to offline)
        let failedLLM = records.filter { $0.llmProcessingStatus == .failed }
        for record in failedLLM {
            guard NetworkMonitor.shared.checkConnectivity() else { return }
            let text = record.optimizedContent ?? record.content
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
        let text = record.optimizedContent ?? record.content
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
        do {
            let records = try await storage.loadAll()
            historyRecords = records
            Logger.info("Loaded \(records.count) records")
        } catch {
            Logger.error("Failed to load history: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func deleteRecord(id: UUID) {
        Logger.info("Deleting record: \(id.uuidString)")
        historyRecords.removeAll { $0.id == id }
        Task {
            do {
                try await storage.delete(id: id)
            } catch {
                Logger.error("Failed to delete record: \(error.localizedDescription)")
            }
        }
    }

    func getRecord(id: UUID) async -> TranscriptionRecord? {
        try? await storage.get(id: id)
    }

    func updateRecord(_ record: TranscriptionRecord) async throws {
        // Preserve the original createdAt timestamp + audioFileName + optimizedContent +
        // archived state when updating. The caller's input may not carry these fields
        // (e.g. TranscriptionDetailView.reprocessRecord / saveEditing only set a subset),
        // and dropping them was causing playback + archive state to silently disappear
        // after the user clicked Analyze or Save in the detail view.
        let existingRecord = try await storage.get(id: record.id)
        let updatedRecord = TranscriptionRecord(
            id: record.id,
            content: record.content,
            createdAt: existingRecord?.createdAt ?? record.createdAt,
            duration: record.duration,
            language: record.language,
            audioFileName: record.audioFileName ?? existingRecord?.audioFileName,
            // Preserve LLM fields
            title: record.title,
            summary: record.summary,
            tags: record.tags,
            llmProcessingStatus: record.llmProcessingStatus,
            optimizedContent: record.optimizedContent ?? existingRecord?.optimizedContent,
            recognitionMode: record.recognitionMode ?? existingRecord?.recognitionMode,
            archived: record.archived || (existingRecord?.archived ?? false),
            archivedAt: record.archivedAt ?? existingRecord?.archivedAt
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

    /// Active records (non-archived) that match the current search query and selected tags.
    /// Sort: tag-match-count desc → createdAt desc when tags are selected; otherwise createdAt desc.
    var displayedRecords: [TranscriptionRecord] {
        let activeMatching = historyRecords
            .filter { !$0.archived }
            .filter { Self.matchesSearch($0, query: searchQuery) }
            .filter { record in
                selectedTags.isEmpty
                    || record.tagNames.contains(where: selectedTags.contains)
            }

        if selectedTags.isEmpty {
            return activeMatching.sorted { $0.createdAt > $1.createdAt }
        }
        return activeMatching.sorted { lhs, rhs in
            let lhsCount = lhs.tagNames.filter(selectedTags.contains).count
            let rhsCount = rhs.tagNames.filter(selectedTags.contains).count
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// All unique tag names from active records. Order is by the maximum relevance
    /// score across all records that carry the tag (descending), so the most
    /// "important" tags surface first; ties break alphabetically. Legacy records
    /// without scores still surface, ordered alphabetically among themselves.
    var availableTags: [String] {
        struct ScoredTag { let name: String; let maxScore: Double; let hasScore: Bool }
        var byName: [String: ScoredTag] = [:]
        for record in historyRecords where !record.archived {
            for tag in record.tags ?? [] {
                let prev = byName[tag.name]
                let prevScore = prev?.maxScore ?? -.infinity
                let newScore = max(prevScore, tag.score)
                byName[tag.name] = ScoredTag(
                    name: tag.name,
                    maxScore: newScore,
                    hasScore: (prev?.hasScore ?? false) || true
                )
            }
        }
        return byName.values
            .sorted { lhs, rhs in
                if lhs.maxScore != rhs.maxScore { return lhs.maxScore > rhs.maxScore }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(\.name)
    }

    /// Per-tag count of active records that also match the current search query.
    var tagCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for record in historyRecords where !record.archived {
            guard Self.matchesSearch(record, query: searchQuery) else { continue }
            for name in record.tagNames {
                counts[name, default: 0] += 1
            }
        }
        return counts
    }

    /// IDs of archived records that match the current search query and selected tags.
    var archivedHitIDs: [UUID] {
        historyRecords
            .filter { $0.archived }
            .filter { Self.matchesSearch($0, query: searchQuery) }
            .filter { record in
                selectedTags.isEmpty
                    || record.tagNames.contains(where: selectedTags.contains)
            }
            .map { $0.id }
    }

    /// Count of archived records that match the current search query and selected tags.
    var archivedHitCount: Int {
        archivedHitIDs.count
    }

    func setSearchQuery(_ query: String) {
        searchQuery = query
    }

    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    func clearFilters() {
        searchQuery = ""
        selectedTags = []
    }

    /// Mark a record as archived and persist the change. The record disappears from
    /// `displayedRecords`; archived-hit counters update automatically.
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

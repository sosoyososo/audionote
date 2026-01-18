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

    private let speechRecognizer = SpeechRecognizer()
    private let storage = TranscriptionStorage.shared
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private var textStreamTask: Task<Void, Never>?

    init() {
        Logger.info("TranscriptionViewModel initialized")
        Task { @MainActor in
            await loadHistory()
            updateAuthorizationStatus()
            loadSavedLanguage()
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
        let permissionsManager = PermissionsManager.shared
        authorizationStatus = permissionsManager.isAllAuthorized ? .authorized : permissionsManager.speechAuthorizationStatus
        Logger.info("Authorization status updated: \(String(describing: authorizationStatus))")
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

        guard authorizationStatus == .authorized else {
            Logger.info("Not authorized, requesting permissions")
            await requestPermissions()
            return
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

            startDurationTimer()

            let textStream = try await speechRecognizer.startRecording()

            Logger.info("Speech recognition stream started")

            textStreamTask = Task { @MainActor in
                for await text in textStream {
                    Logger.debug("Received text: \(text)")
                    partialText = text
                }
                Logger.info("Text stream completed")
            }
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

        // Get the final accumulated text
        let finalText = speechRecognizer.getFinalText()
        Logger.info("Final text from recognizer: \(finalText)")

        // Use partialText if finalText is empty but partialText has content
        let contentToSave = finalText.isEmpty ? partialText : finalText

        speechRecognizer.stopRecording()
        isRecording = false
        stopDurationTimer()

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? recordingDuration

        Logger.info("Saving record - content length: \(contentToSave.count), duration: \(duration)")

        // Always use the currentRecordId (generated at startRecording)
        let record = TranscriptionRecord(
            id: currentRecordId ?? UUID(),
            content: contentToSave,
            createdAt: recordingStartTime ?? Date(),
            duration: duration,
            language: selectedLanguage.rawValue
        )

        // Save the transcribed text for display
        transcribedText = contentToSave

        do {
            try await storage.save(record)
            Logger.info("Record saved successfully with ID: \(record.id.uuidString)")
            await loadHistory()
        } catch {
            Logger.error("Failed to save record: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        // Keep currentRecordId for potential editing - only clear when starting new recording
    }

    func loadHistory() async {
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

    func deleteRecord(id: UUID) async {
        Logger.info("Deleting record: \(id.uuidString)")
        do {
            try await storage.delete(id: id)
            await loadHistory()
        } catch {
            Logger.error("Failed to delete record: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func getRecord(id: UUID) async -> TranscriptionRecord? {
        try? await storage.get(id: id)
    }

    func updateRecord(_ record: TranscriptionRecord) async throws {
        // Preserve the original createdAt timestamp when updating
        let existingRecord = try await storage.get(id: record.id)
        let updatedRecord = TranscriptionRecord(
            id: record.id,
            content: record.content,
            createdAt: existingRecord?.createdAt ?? record.createdAt,
            duration: record.duration,
            language: record.language
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
}

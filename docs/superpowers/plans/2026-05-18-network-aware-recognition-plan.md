# Network-Aware Speech Recognition & LLM Processing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make speech recognition and LLM processing robust against network changes, with visible recognition mode indicators and post-hoc online upgrade capability.

**Architecture:** NetworkMonitor becomes the foundational layer with synchronous init and status-change callbacks. SpeechRecognizer gains file-based re-recognition and a `recognitionMode` property. TranscriptionViewModel orchestrates the full recording→save→assess→enhance→LLM pipeline, listening for network recovery to auto-process pending items. UI layers show recognition mode in real-time and provide manual retry buttons.

**Tech Stack:** Swift 5.9, SwiftUI, Speech Framework (SFSpeechRecognizer, SFSpeechURLRecognitionRequest), Network (NWPathMonitor), AVFoundation

**Pre-existing changes (already in working tree, not covered in tasks):**
- `LLMService.swift`: `.offline` case added to `LLMError`, guard checks in `process()`, `optimize()`, `optimizeAndProcess()`, `.offline` excluded from retry
- `AIProcessingService.swift`: `processPendingRecords()` guards on `NetworkMonitor.shared.checkConnectivity()`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `NetworkMonitor.swift` | Synchronous init state, onStatusChange callback |
| `TranscriptionRecord.swift` | RecognitionMode enum + new field |
| `SpeechRecognizer.swift` | Mode tracking, file-based re-recognition, error resilience |
| `TranscriptionViewModel.swift` | Orchestration: stopRecording pipeline, network recovery, manual retry |
| `RecordingView.swift` | Real-time recognition mode indicator |
| `TranscriptionDetailView.swift` | Mode label, online upgrade button, LLM retry button |
| `LLMService.swift` | Pre-existing changes (review only) |
| `AIProcessingService.swift` | Pre-existing changes (review only) |

---

### Task 1: Fix NetworkMonitor Initial Value Race & Add Status Change Callback

**Files:**
- Modify: `ios/AudioNote/Utilities/NetworkMonitor.swift`

- [ ] **Step 1: Rewrite NetworkMonitor with synchronous init and onStatusChange**

Replace the entire file:

```swift
import Foundation
import Network

final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "info.karsa.app.ios.audionote.networkmonitor")

    private(set) var isConnected: Bool = true
    private(set) var connectionType: ConnectionType = .unknown

    /// Called on .main actor when connectivity transitions from disconnected → connected
    var onStatusChange: (@MainActor (_ isConnected: Bool) -> Void)?

    enum ConnectionType {
        case wifi
        case cellular
        case ethernet
        case unknown
    }

    private init() {
        monitor = NWPathMonitor()
        // Sync-init from current path to avoid race
        let currentPath = monitor.currentPath
        isConnected = currentPath.status == .satisfied
        updateConnectionType(from: currentPath)
    }

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let wasConnected = self.isConnected
            self.isConnected = path.status == .satisfied
            self.updateConnectionType(from: path)

            Logger.info("Network status: \(self.isConnected), type: \(self.connectionType)")

            // Fire callback on transition: disconnected → connected
            if !wasConnected && self.isConnected {
                Task { @MainActor in
                    self.onStatusChange?(true)
                }
            }
        }

        monitor.start(queue: queue)
    }

    func stopMonitoring() {
        monitor.cancel()
    }

    func checkConnectivity() -> Bool {
        isConnected
    }

    private func updateConnectionType(from path: NWPath) {
        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .ethernet
        } else {
            connectionType = .unknown
        }
    }
}
```

- [ ] **Step 2: Move startMonitoring() to app launch**

In `ios/AudioNote/App/AudioNoteApp.swift`, add `init()` to `AudioNoteApp`:

```swift
@main
struct AudioNoteApp: App {
    @StateObject private var languageManager = LanguageManager.shared

    init() {
        NetworkMonitor.shared.startMonitoring()
    }
    // ... rest unchanged
}
```

Also remove `NetworkMonitor.shared.startMonitoring()` from `SpeechRecognizer.init()` (line 53 of current SpeechRecognizer.swift), since NetworkMonitor now starts at app launch.

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/Utilities/NetworkMonitor.swift
git commit -m "fix: sync-init NetworkMonitor to prevent race, add onStatusChange callback"
```

---

### Task 2: Add RecognitionMode to TranscriptionRecord

**Files:**
- Modify: `ios/AudioNote/Models/TranscriptionRecord.swift`

- [ ] **Step 1: Add RecognitionMode enum and field**

Add the enum above `LLMStatus`:

```swift
enum RecognitionMode: String, Codable {
    case online
    case onDevice
    case enhanced
    case failed
}
```

Add the field to `TranscriptionRecord`:

```swift
var recognitionMode: RecognitionMode?
```

Update `init` to include the new parameter:

```swift
init(
    id: UUID = UUID(),
    content: String,
    createdAt: Date = Date(),
    duration: TimeInterval? = nil,
    language: String? = nil,
    audioFileName: String? = nil,
    title: String? = nil,
    summary: String? = nil,
    tags: [String]? = nil,
    llmProcessingStatus: LLMStatus? = nil,
    optimizedContent: String? = nil,
    recognitionMode: RecognitionMode? = nil
) {
    self.id = id
    self.content = content
    self.createdAt = createdAt
    self.duration = duration
    self.language = language
    self.audioFileName = audioFileName
    self.title = title
    self.summary = summary
    self.tags = tags
    self.llmProcessingStatus = llmProcessingStatus
    self.optimizedContent = optimizedContent
    self.recognitionMode = recognitionMode
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/AudioNote/Models/TranscriptionRecord.swift
git commit -m "feat: add RecognitionMode enum and field to TranscriptionRecord"
```

---

### Task 3: Enhance SpeechRecognizer with Mode Tracking and File-Based Re-Recognition

**Files:**
- Modify: `ios/AudioNote/Services/SpeechRecognizer.swift`

- [ ] **Step 1: Add recognitionMode property and error capture**

Add properties to `SpeechRecognizer`:

```swift
private(set) var recognitionMode: RecognitionMode = .online
private var recognitionError: SpeechRecognitionError?
```

- [ ] **Step 2: Update startRecording() to set mode and capture errors**

In `startRecording()`, update the network check section (around line 117):

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

In the recognition task error handler (around line 186), capture the error instead of just logging:

```swift
if let error = error as NSError? {
    Logger.error("Recognition error: \(error.localizedDescription), code: \(error.code)")
    selfStrong.recognitionError = .recognitionFailed(error)
    // Don't cancel — let recording continue, audio is saved
}

if error != nil {
    Logger.warning("Unknown error in recognition task")
    selfStrong.recognitionError = .recognitionFailed(nil)
}
```

And update the `guard` at the start of `startRecording()` to handle the `notAvailable` case more specifically:

```swift
guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
    Logger.error("Speech recognition not available")
    recognitionMode = .failed
    recognitionError = .notAvailable
    throw SpeechRecognitionError.notAvailable
}
```

- [ ] **Step 3: Add recognizeFromFile(url:) method**

Add a new method after `getAudioFileName()`:

```swift
/// Re-recognize a saved audio file using online recognition.
/// Returns the recognized text.
func recognizeFromFile(url: URL) async throws -> String {
    guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
        throw SpeechRecognitionError.notAvailable
    }

    guard NetworkMonitor.shared.checkConnectivity() else {
        Logger.warning("recognizeFromFile skipped: device is offline")
        throw SpeechRecognitionError.notAvailable
    }

    Logger.info("Starting file-based online recognition: \(url.path)")

    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = false
    request.requiresOnDeviceRecognition = false  // Force online for upgrade
    if #available(iOS 16.0, *) {
        request.addsPunctuation = true
    }

    return try await withCheckedThrowingContinuation { continuation in
        speechRecognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                Logger.error("File recognition error: \(error.localizedDescription)")
                continuation.resume(throwing: SpeechRecognitionError.recognitionFailed(error))
                return
            }

            if let result = result, result.isFinal {
                let text = result.bestTranscription.formattedString
                Logger.info("File recognition complete, text length: \(text.count)")
                continuation.resume(returning: text)
            }
        }
    }
}

/// Whether the last recording session ended with a recognition error
var hasRecognitionError: Bool {
    recognitionError != nil
}

/// The error from the last recognition session, if any
var lastRecognitionError: SpeechRecognitionError? {
    recognitionError
}
```

- [ ] **Step 4: Update stopRecording() to preserve mode before cleanup**

At the start of `stopRecording()`, before cleanup, snapshot the final mode. The `recognitionMode` and `recognitionError` properties are already set during recording and will survive `stopRecording()` since they're set before cleanup.

Add after obtaining `finalText`:

```swift
// If recognition had an error but we still have text via on-device fallback,
// or if the task completed successfully, determine the final mode
if recognitionError != nil && !finalText.isEmpty {
    // Had error but got text via framework fallback — keep current mode
} else if recognitionError != nil && finalText.isEmpty {
    recognitionMode = .failed
}
```

- [ ] **Step 5: Commit**

```bash
git add ios/AudioNote/Services/SpeechRecognizer.swift
git commit -m "feat: add recognition mode tracking and file-based re-recognition to SpeechRecognizer"
```

---

### Task 4: Rewrite TranscriptionViewModel Orchestration

**Files:**
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`

- [ ] **Step 1: Add new published properties and setup network listener**

Add properties:

```swift
@Published var recognitionMode: RecognitionMode = .online
@Published var isEnhancing: Bool = false

private var networkRecoveryTask: Task<Void, Never>?
private let networkRecoveryDebounce: UInt64 = 2_000_000_000  // 2 seconds
```

In `init()`, add NetworkMonitor callback setup after existing setup:

```swift
setupNetworkMonitor()
```

Add the setup method:

```swift
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
```

- [ ] **Step 2: Update startRecording() to track mode**

After the speech stream starts (line 135 area), read the mode:

```swift
recognitionMode = speechRecognizer.recognitionMode
Logger.info("Recognition mode: \(speechRecognizer.recognitionMode)")
```

- [ ] **Step 3: Rewrite stopRecording() with assess→enhance→LLM pipeline**

Replace the current `stopRecording()` method (lines 149-212):

```swift
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
```

- [ ] **Step 4: Add assessAndEnhance method**

```swift
/// Phase 2: After saving, assess recognition quality and enhance if possible
private func assessAndEnhance(record: TranscriptionRecord, originalText: String) async {
    let optimizationEnabled = UserDefaults.standard.bool(forKey: "audioNote:enableLLMOptimization")
    let token = UserDefaults.standard.string(forKey: "audioNote:llmToken") ?? ""

    switch record.recognitionMode {
    case .online:
        // Best case: online recognition succeeded, go straight to LLM
        if optimizationEnabled {
            await processWithLLM(recordId: record.id, originalText: originalText)
        }

    case .onDevice:
        // On-device succeeded but can be upgraded
        if NetworkMonitor.shared.checkConnectivity() {
            // Auto-upgrade to online recognition
            await enhanceRecognition(recordId: record.id)
        }
        // Run LLM if online (either now or after enhance completes)
        if optimizationEnabled && NetworkMonitor.shared.checkConnectivity() {
            await processWithLLM(recordId: record.id, originalText: originalText)
        }

    case .failed:
        // Recognition failed — try online if available
        if NetworkMonitor.shared.checkConnectivity() {
            await retryRecognitionFromFile(recordId: record.id)
        }

    default:
        break
    }
}
```

- [ ] **Step 5: Add enhanceRecognition (online upgrade for on-device result)**

```swift
/// Re-recognize a record's audio using online recognition for better quality
func enhanceRecognition(recordId: UUID) async {
    guard let record = try? await storage.get(id: recordId),
          let audioFileName = record.audioFileName else {
        Logger.warning("Cannot enhance: record or audio file not found")
        return
    }

    let audioURL = AudioRecorderService.generateFileUrl(for: UUID(uuidString: audioFileName.replacingOccurrences(of: ".m4a", with: "")) ?? UUID())

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
```

- [ ] **Step 6: Add retryRecognitionFromFile (for failed recognition)**

```swift
/// Retry recognition from saved audio file after a failure
func retryRecognitionFromFile(recordId: UUID) async {
    guard let record = try? await storage.get(id: recordId),
          let audioFileName = record.audioFileName else {
        Logger.warning("Cannot retry: record or audio file not found")
        return
    }

    let uuid = UUID(uuidString: audioFileName.replacingOccurrences(of: ".m4a", with: "")) ?? UUID()
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
        let optimizationEnabled = UserDefaults.standard.bool(forKey: "audioNote:enableLLMOptimization")
        if optimizationEnabled {
            await processWithLLM(recordId: record.id, originalText: text)
        }
    } catch {
        Logger.error("Retry recognition failed: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 7: Rewrite processWithLLM to distinguish offline**

```swift
func processWithLLM(recordId: UUID, originalText: String) async {
    isLLMProcessing = true
    llmProcessingFailed = false

    let token = UserDefaults.standard.string(forKey: "audioNote:llmToken") ?? ""

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

    let maxAttempts = 3

    for attempt in 0..<maxAttempts {
        do {
            let result = try await llmService.optimizeAndProcess(originalText, token: token)
            Logger.info("LLM processWithLLM succeeded on attempt \(attempt + 1)")

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
            return
        } catch let error as LLMError {
            Logger.warning("LLM processWithLLM failed (attempt \(attempt + 1)/\(maxAttempts)): \(error.errorDescription ?? "unknown")")

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

            if attempt < maxAttempts - 1 {
                let delay = 1.0 * pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        } catch {
            Logger.warning("LLM processWithLLM failed (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
            if attempt < maxAttempts - 1 {
                let delay = 1.0 * pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    Logger.error("LLM processWithLLM failed after \(maxAttempts) attempts")
    isLLMProcessing = false
    llmProcessingFailed = true

    if var record = try? await storage.get(id: recordId) {
        record.llmProcessingStatus = .failed
        try? await storage.save(record)
    }
}
```

- [ ] **Step 8: Add networkDidRecover and manual retry methods**

```swift
/// Called when network transitions from disconnected → connected (debounced)
func networkDidRecover() async {
    Logger.info("Network recovered — processing pending items")
    let records = (try? await storage.loadAll()) ?? []

    // 1. Process records never LLM-processed
    let pendingLLM = records.filter { $0.llmProcessingStatus == nil }
    for record in pendingLLM {
        guard NetworkMonitor.shared.checkConnectivity() else { return }
        _ = await aiProcessingService.processRecord(record)
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
```

- [ ] **Step 9: Update updateRecord and callers to preserve recognitionMode**

In `TranscriptionViewModel.updateRecord()`, update the init to preserve recognitionMode:

```swift
let updatedRecord = TranscriptionRecord(
    id: record.id,
    content: record.content,
    createdAt: existingRecord?.createdAt ?? record.createdAt,
    duration: record.duration,
    language: record.language,
    title: record.title,
    summary: record.summary,
    tags: record.tags,
    llmProcessingStatus: record.llmProcessingStatus,
    recognitionMode: record.recognitionMode ?? existingRecord?.recognitionMode
)
```

In `RecordingView.saveEditedText()`, update the record init (around line 510) to pass recognitionMode:

```swift
let updatedRecord = TranscriptionRecord(
    id: recordId ?? UUID(),
    content: editedText,
    createdAt: Date(),
    duration: viewModel.recordingDuration,
    language: viewModel.selectedLanguage.rawValue,
    recognitionMode: viewModel.recognitionMode
)
```

- [ ] **Step 10: Commit**

```bash
git add ios/AudioNote/ViewModels/TranscriptionViewModel.swift ios/AudioNote/Views/RecordingView.swift
git commit -m "feat: rewrite recording orchestration with network-aware assess-enhance-LLM pipeline"
```

---

### Task 5: Add Recognition Mode Indicator to RecordingView

**Files:**
- Modify: `ios/AudioNote/Views/RecordingView.swift`

- [ ] **Step 1: Add mode indicator to recording control section**

In the `recordingControlSection` (around line 145), add a mode indicator between the duration display and the recording button. Insert after line 158 (after the "正在录制" text):

```swift
// Recognition mode indicator
if viewModel.isRecording {
    HStack(spacing: 6) {
        Circle()
            .fill(modeColor)
            .frame(width: 8, height: 8)
        Text(modeLabel)
            .font(.caption)
            .foregroundColor(.secondary)
    }
    .padding(.vertical, 4)
}
```

Add computed properties at the bottom of `RecordingView`:

```swift
private var modeColor: Color {
    switch viewModel.recognitionMode {
    case .online: return .green
    case .onDevice: return .yellow
    case .enhanced: return .blue
    case .failed: return .red
    }
}

private var modeLabel: String {
    switch viewModel.recognitionMode {
    case .online: return "在线识别"
    case .onDevice: return "离线识别"
    case .enhanced: return "已在线升级"
    case .failed: return "识别失败"
    }
}
```

- [ ] **Step 2: Update the post-recording text section header to show mode**

Replace the `isLLMProcessing` branch in the text section header (around line 250-258) with an additional mode display. After the LLM processing/failed indicators, add a standalone mode indicator for non-recording state:

In the `else` branch (around line 279), after `Text("Recording.Result".localized)`, add:

```swift
Text(modeLabel)
    .font(.caption2)
    .foregroundColor(modeColor)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(modeColor.opacity(0.1))
    .cornerRadius(4)
```

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/Views/RecordingView.swift
git commit -m "feat: add recognition mode indicator to recording UI"
```

---

### Task 6: Add Recognition Mode Label & Action Buttons to TranscriptionDetailView

**Files:**
- Modify: `ios/AudioNote/Views/TranscriptionDetailView.swift`

- [ ] **Step 1: Add recognitionMode to local state**

Add to the state properties at top:

```swift
@State private var currentRecognitionMode: RecognitionMode?
```

Initialize in `init()`:

```swift
self._currentRecognitionMode = State(initialValue: record.recognitionMode)
```

- [ ] **Step 2: Add recognition mode badge to metadata section**

Add after the duration HStack in `metadataSection`:

```swift
if let mode = currentRecognitionMode {
    HStack(spacing: 6) {
        Image(systemName: recognitionModeIcon(for: mode))
            .foregroundColor(recognitionModeColor(for: mode))
        Text(recognitionModeLabel(for: mode))
            .foregroundColor(recognitionModeColor(for: mode))
    }
    .font(.subheadline)
    .padding(.vertical, 2)
}
```

Add helper functions at the bottom of the struct:

```swift
private func recognitionModeIcon(for mode: RecognitionMode) -> String {
    switch mode {
    case .online: return "wifi"
    case .onDevice: return "antenna.radiowaves.left.and.right.slash"
    case .enhanced: return "arrow.up.doc"
    case .failed: return "exclamationmark.triangle"
    }
}

private func recognitionModeColor(for mode: RecognitionMode) -> Color {
    switch mode {
    case .online: return .green
    case .onDevice: return .yellow
    case .enhanced: return .blue
    case .failed: return .red
    }
}

private func recognitionModeLabel(for mode: RecognitionMode) -> String {
    switch mode {
    case .online: return "在线识别"
    case .onDevice: return "离线识别"
    case .enhanced: return "已在线升级"
    case .failed: return "识别失败"
    }
}
```

- [ ] **Step 3: Add action buttons section between content and LLM results**

Insert between `contentSection` and `llmResultsSection` (replace existing `llmResultsSection` with enhanced version):

Add a new `actionsSection` computed property:

```swift
private var actionsSection: some View {
    VStack(spacing: 8) {
        // Online upgrade button — only for onDevice/failed with audio file
        if (currentRecognitionMode == .onDevice || currentRecognitionMode == .failed),
           record.audioFileName != nil {
            Button {
                upgradeRecognition()
            } label: {
                HStack {
                    if viewModel.isEnhancing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.8)
                        Text("正在升级识别...")
                    } else {
                        Image(systemName: "arrow.up.doc")
                        Text("在线升级识别")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .cornerRadius(8)
            }
            .disabled(viewModel.isEnhancing)
        }
        // Note: LLM retry is handled by the existing llmStatusView
    }
    .font(.subheadline)
}
```

Add action methods:

```swift
private func upgradeRecognition() {
    Task {
        await viewModel.reRecognizeOnline(recordId: record.id)
        // Refresh local state
        if let updated = try? await viewModel.getRecord(id: record.id) {
            await MainActor.run {
                currentRecognitionMode = updated.recognitionMode
                if updated.content != editedContent {
                    editedContent = updated.content
                }
                if updated.llmProcessingStatus != currentLLMStatus {
                    currentLLMStatus = updated.llmProcessingStatus
                    currentTitle = updated.title
                    currentSummary = updated.summary
                    currentTags = updated.tags
                }
            }
        }
    }
}

// Note: LLM retry is handled by the existing reprocessRecord() method and llmStatusView.
// The existing reprocessRecord() already handles nil/completed/failed LLM statuses.
// We add upgradeRecognition() for the new recognition upgrade flow.
```

- [ ] **Step 4: Wire actionsSection into the view body**

In the main `body`, insert `actionsSection` between `contentSection` and the playback section. After the closing `}` of `contentSection` and before `if let audioFileName = record.audioFileName {`, add:

```swift
actionsSection
    .padding(.top, 4)

Divider()
```

So the body layout becomes: metadataSection → Divider → contentSection → actionsSection → Divider → playback → llmResultsSection.

- [ ] **Step 5: Update existing reprocessRecord and saveEditing to preserve recognitionMode**

In `reprocessRecord()`, update the `TranscriptionRecord` init to include `recognitionMode`:

```swift
let updatedRecord = TranscriptionRecord(
    id: record.id,
    content: result.optimizedText,
    createdAt: record.createdAt,
    duration: record.duration,
    language: record.language,
    audioFileName: record.audioFileName,
    title: result.title,
    summary: result.summary,
    tags: result.tags,
    llmProcessingStatus: .completed,
    optimizedContent: originalText != record.content ? originalText : record.optimizedContent,
    recognitionMode: record.recognitionMode
)
```

In `saveEditing()`, update the `TranscriptionRecord` init to include `recognitionMode`:

```swift
let updatedRecord = TranscriptionRecord(
    id: record.id,
    content: editedContent,
    createdAt: record.createdAt,
    duration: record.duration,
    language: record.language,
    audioFileName: record.audioFileName,
    title: record.title,
    summary: record.summary,
    tags: record.tags,
    llmProcessingStatus: record.llmProcessingStatus,
    recognitionMode: record.recognitionMode
)
```

- [ ] **Step 6: Commit**

```bash
git add ios/AudioNote/Views/TranscriptionDetailView.swift
git commit -m "feat: add recognition mode badge and action buttons to detail view"
```

---

### Task 7: Verify End-to-End Flows

- [ ] **Step 1: Build and verify compilation**

```bash
cd /Users/karsa/proj/audionote/ios && xcodebuild -project AudioNote.xcodeproj -scheme AudioNote -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 2: Verify existing LLMService/AIProcessingService changes compile**

The pre-existing changes in `LLMService.swift` and `AIProcessingService.swift` should still compile with the new changes. Confirm no conflicts.

- [ ] **Step 3: Manual verification checklist**

Run on simulator or device and verify these scenarios:

| Scenario | Expected Behavior |
|----------|-------------------|
| Online → record | Shows "在线识别" indicator, LLM auto-processes |
| Offline → record | Shows "离线识别" indicator, saves text, no LLM |
| Offline → record → go online | Network recovery triggers auto-upgrade + LLM |
| Offline → record → detail view | Shows "离线识别" badge + "在线升级识别" button |
| Airplane mode → record → fail | Shows "识别失败", audio saved, retry available |
| Detail view → tap "在线升级识别" | Re-recognizes from audio file, updates mode to "已在线升级" |

- [ ] **Step 4: Final commit (if any fixes from verification)**

```bash
git add -A
git commit -m "fix: address issues found during end-to-end verification"
```

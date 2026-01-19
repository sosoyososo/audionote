# Service Contracts

## SpeechRecognizer Protocol

```swift
enum RecognitionLanguage: String, CaseIterable, Identifiable, Codable {
    case chinese = "zh-CN"
    case english = "en-US"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}
```

```swift
protocol SpeechRecognizerProtocol {
    /// Authorization status for speech recognition
    var authorizationStatus: SFSpeechRecognizerAuthorizationStatus { get }

    /// Whether speech recognition is available on this device
    var isAvailable: Bool { get }

    /// Current recognition language
    var recognitionLanguage: RecognitionLanguage { get set }

    /// Start recognition with real-time result callbacks
    func startRecognition() async throws -> AsyncStream<String>

    /// Stop current recognition session
    func stopRecording()

    /// Request user authorization
    func requestAuthorization() async -> Bool
}
```

## StorageService Protocol

```swift
protocol StorageServiceProtocol {
    /// Save a new transcription record
    func save(_ record: TranscriptionRecord) async throws

    /// Load all transcription records, sorted by date descending
    func loadAll() async throws -> [TranscriptionRecord]

    /// Delete a specific record by ID
    func delete(id: UUID) async throws

    /// Get a single record by ID
    func get(id: UUID) async throws -> TranscriptionRecord
}
```

## ViewModel Contract: TranscriptionViewModel

### State

```swift
@Published var isRecording: Bool
@Published var transcribedText: String
@Published var partialText: String
@Published var recordingDuration: TimeInterval
@Published var historyRecords: [TranscriptionRecord]
@Published var currentRecordId: UUID?
@Published var authorizationStatus: AuthorizationStatus
@Published var selectedLanguage: RecognitionLanguage
```

### Actions

| Action | Input | Output | Side Effects |
|--------|-------|--------|--------------|
| `startRecording()` | - | Success/Failure | `isRecording = true`, starts audio capture |
| `stopRecording()` | - | Final transcribed text | `isRecording = false`, saves record |
| `setLanguage(_:)` | RecognitionLanguage | - | Updates speech recognizer language |
| `deleteRecord(id: UUID)` | Record ID | - | Removes from local storage |
| `copyToClipboard(text: String)` | Text | Success | UIPasteboard updated |
| `shareText(text: String)` | Text | - | Presents UIActivityViewController |

### AuthorizationStatus Enum

```swift
enum AuthorizationStatus {
    case notDetermined
    case denied
    case restricted
    case authorized
}
```

### Logging

The system MUST log the following events for debugging:

```swift
enum LogLevel: String {
    case debug, info, warning, error
}

func log(_ message: String, level: LogLevel = .info, file: String = #file, function: String = #function, line: Int = #line)
```

- Speech recognition start/stop events
- Partial result updates
- Error events
- Permission status changes
```

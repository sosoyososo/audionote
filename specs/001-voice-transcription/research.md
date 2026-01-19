# Research: iOS Speech Recognition

## Decision: Use Apple Speech Framework (SFSpeechRecognizer)

**Speech Framework** is Apple's native speech recognition solution, providing:
- On-device recognition (iOS 16+) for privacy and offline support
- Cloud-based recognition for older iOS versions
- Real-time and file-based transcription
- No third-party dependencies required

### Alternatives Considered

| Alternative | Rejected Because |
|-------------|------------------|
| Google Speech-to-Text API | Requires network, API keys, billing setup |
| Azure Cognitive Services | Additional dependency, cloud cost |
| OpenAI Whisper API | Requires network, API key management |
| Vosk offline | Third-party library, more complex integration |

## Speech Framework Best Practices

### Permission Handling

```swift
// Request authorization
SFSpeechRecognizer.requestAuthorization { status in
    switch status {
    case .authorized:
        // Enable speech recognition
    case .denied, .restricted, .notDetermined:
        // Show permission request UI
    }
}
```

- Must include `NSSpeechRecognitionUsageDescription` in Info.plist
- Must request both speech recognition and microphone permissions
- Handle permission denials gracefully with settings navigation

### Real-time Recognition Setup

```swift
let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
let request = SFSpeechAudioBufferRecognitionRequest()

// Configure for real-time
request.shouldReportPartialResults = true

// Start recognition
let task = recognizer?.recognitionTask(with: request) { result, error in
    if let result = result {
        // Process partial or final results
        text = result.bestTranscription.formattedString
    }
}
```

### Audio Session Configuration

```swift
do {
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
} catch {
    // Handle error
}
```

## Local Storage Strategy

### JSON File Storage for Transcriptions

```swift
// Storage location
let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
let transcriptionsFile = documentsPath.appendingPathComponent("transcriptions.json")

// Save
try JSONEncoder().encode(records).write(to: transcriptionsFile)

// Load
let records = try JSONDecoder().decode([TranscriptionRecord].self, from: Data(contentsOf: transcriptionsFile))
```

### Data Model

```swift
struct TranscriptionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let content: String
    let createdAt: Date
    let duration: TimeInterval?

    init(id: UUID = UUID(), content: String, createdAt: Date = Date(), duration: TimeInterval? = nil) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.duration = duration
    }
}
```

## UI/UX Guidelines

### Recording State Indication

- Visual feedback during recording (pulsing animation)
- Show real-time transcription with placeholder until confirmed
- Recording duration display
- Stop button clearly accessible

### History List

- Group by date (Today, Yesterday, Earlier)
- Show preview of first line
- Swipe to delete gesture
- Empty state with call-to-action

### Share/Copy

- Use standard `UIPasteboard` for copy
- Use `UIActivityViewController` for share
- Success feedback (toast/haptic)

## iOS Version Compatibility

| Feature | Minimum iOS |
|---------|-------------|
| SFSpeechRecognizer | iOS 10.0 |
| Partial results | iOS 10.0 |
| On-device recognition | iOS 16.0 |
| Real-time transcription | iOS 10.0 |

**Target**: iOS 15.0+ to balance modern SwiftUI features and speech capabilities.

## References

- [SFSpeechRecognizer Documentation](https://developer.apple.com/documentation/speech)
- [AVAudioSession Best Practices](https://developer.apple.com/documentation/avfaudio/avaudiosession)
- [Apple Human Interface Guidelines - Audio](https://developer.apple.com/design/human-interface-guidelines/audio)

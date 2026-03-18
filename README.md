# AudioNote

A simple iOS voice transcription app that converts speech to text using iOS Speech Recognition framework.

## Features

- **Voice Recording** - Record voice and transcribe it to text in real-time
- **Multi-language Support** - Supports English and Chinese (Simplified) transcription
- **History Management** - Save and browse your transcription history
- **Duration Tracking** - Each recording shows its duration

## Requirements

- iOS 16.0+
- Xcode 15.0+
- Swift 5.9+

## Getting Started

1. Clone the repository
2. Open `ios/AudioNote.xcodeproj` in Xcode
3. Select your target device/simulator
4. Build and run (⌘+R)

## Permissions

The app requires the following permissions:
- **Microphone** - For recording audio
- **Speech Recognition** - For transcribing speech to text

## Project Structure

```
ios/AudioNote/
├── App/              # App entry point
├── Models/           # Data models
├── Services/         # Business logic (Speech recognition, storage)
├── Utilities/        # Helpers (Language manager, permissions)
├── ViewModels/       # View models
└── Views/            # SwiftUI views
```

## License

MIT License

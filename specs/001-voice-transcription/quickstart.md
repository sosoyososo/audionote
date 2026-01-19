# Quickstart: AudioNote iOS App

## Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- iOS 15.0+ simulator or device
- Xcode Command Line Tools: `xcode-select --install`

## Development Setup

### 1. Open the Project

```bash
# Navigate to project directory
cd /Users/karsa/proj/audionote

# Open in Xcode
open ios/AudioNote.xcodeproj
```

Or open `ios/AudioNote.xcodeproj` in Xcode directly.

### 2. Verify Build

```bash
cd ios
xcodebuild -scheme AudioNote -destination 'platform=iOS Simulator,name=iPhone 15' build
```

### 3. Run on Simulator

Select an iOS 15+ simulator in Xcode and press Cmd+R.

## Key Dependencies

| Framework | Purpose | Import |
|-----------|---------|--------|
| SwiftUI | UI framework | `import SwiftUI` |
| Speech | Speech recognition | `import Speech` |
| AVFoundation | Audio capture | `import AVFoundation` |

## Project Structure Overview

```
ios/AudioNote/
├── App/              # App entry point
├── Models/           # Data models (TranscriptionRecord)
├── Views/            # SwiftUI views
├── ViewModels/       # MVVM view models
├── Services/         # Business logic (Speech, Storage)
├── Utilities/        # Helper classes (Permissions)
└── Resources/        # Assets, Info.plist
```

## Development Workflow

1. **Create new feature**: Create branch from `main`
2. **Implement**: Write code in appropriate layer
3. **Test**: Use simulator or physical device
4. **Build verification**: Run `xcodebuild` before committing
5. **Commit**: Conventional commit messages

## Common Commands

```bash
# Build
xcodebuild -scheme AudioNote build

# Test
xcodebuild -scheme AudioNote test

# Clean build folder
rm -rf ~/Library/Developer/Xcode/DerivedData/AudioNote-*
```

## Testing on Device

1. Connect iOS device via USB
2. Select device in Xcode dropdown
3. Trust developer certificate on device
4. Press Cmd+R to run

## Troubleshooting

### Speech Recognition Not Working

- Check iOS version (on-device requires iOS 16+)
- Verify microphone permissions in Settings > Privacy
- Ensure device has network connection (for cloud-based recognition on iOS 15)

### Build Errors

- Clean build folder: Product > Clean Build Folder
- Restart Xcode
- Update Xcode command line tools: `sudo xcode-select --switch /Applications/Xcode.app`

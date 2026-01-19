# Implementation Plan: iOS 语音转文字

**Branch**: `001-voice-transcription` | **Date**: 2025-01-18 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-voice-transcription/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

A minimal iOS voice transcription app using SwiftUI and Apple Speech Framework. Core features include real-time speech-to-text conversion, transcription history management, text copy and share functionality. No login required, local storage only.

## Technical Context

**Language/Version**: Swift 5.9
**Primary Dependencies**: SwiftUI, Speech Framework, AVFoundation
**Storage**: UserDefaults (small data) + JSON file storage (transcriptions)
**Testing**: XCTest
**Target Platform**: iOS 15.0+
**Project Type**: mobile
**Performance Goals**: Real-time transcription with < 500ms latency
**Constraints**: Offline-capable, no backend required, minimal permissions
**Scale/Scope**: Single-user local app, ~5-8 screens

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

No constitution rules defined - project follows standard iOS development practices.

## Project Structure

### Documentation (this feature)

```text
specs/[###-feature]/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
ios/
├── AudioNote/
│   ├── App/
│   │   └── AudioNoteApp.swift
│   ├── Models/
│   │   └── TranscriptionRecord.swift
│   ├── Views/
│   │   ├── ContentView.swift
│   │   ├── RecordingView.swift
│   │   ├── HistoryListView.swift
│   │   └── TranscriptionDetailView.swift
│   ├── Services/
│   │   ├── SpeechRecognizer.swift
│   │   └── TranscriptionStorage.swift
│   ├── ViewModels/
│   │   └── TranscriptionViewModel.swift
│   ├── Utilities/
│   │   └── PermissionsManager.swift
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   └── Info.plist
│   └── Preview Content/
├── AudioNoteTests/
└── AudioNoteUITests/
```

**Structure Decision**: Standard SwiftUI app structure with MVVM pattern. Models for data, Views for UI, ViewModels for state management, Services for business logic.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| N/A | N/A | N/A |

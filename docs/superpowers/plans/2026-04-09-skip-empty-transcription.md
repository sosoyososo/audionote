# Skip Empty Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Skip saving record and LLM call when transcription is empty after recording ends.

**Architecture:** Add a simple guard clause in `stopRecording()` that checks for non-empty content before saving.

**Tech Stack:** Swift 5.9, SwiftUI

---

## Task 1: Add empty content guard in stopRecording()

**Files:**
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`

- [ ] **Step 1: Read the file to find exact insertion point**

Read lines 149-200 of `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` to see current `stopRecording()` structure.

- [ ] **Step 2: Add empty content check after contentToSave is computed**

Find the code around line 160:
```swift
let contentToSave = finalText.isEmpty ? partialText : finalText
```

After this line, add:
```swift
// Check if there's actual content to save
let trimmedContent = contentToSave.trimmingCharacters(in: .whitespacesAndNewlines)
if trimmedContent.isEmpty {
    Logger.info("No valid content detected, skipping save and LLM processing")
    speechRecognizer.stopRecording()
    isRecording = false
    stopDurationTimer()
    transcribedText = ""
    return
}
```

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/ViewModels/TranscriptionViewModel.swift
git commit -m "feat: skip save and LLM when transcription is empty"
```

---

## Task 2: Verify build

- [ ] **Step 1: Run xcodebuild**

```bash
cd /Users/karsa/proj/audionote/ios && xcodebuild -project AudioNote.xcodeproj -scheme AudioNote -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' build 2>&1 | grep -E "BUILD|error:" | tail -10
```

Expected: BUILD SUCCEEDED

---

## Spec Coverage

- [x] Skip save when empty → Task 1
- [x] Skip LLM call when empty → Task 1 (both skipped via early return before storage.save)
- [x] Build verification → Task 2

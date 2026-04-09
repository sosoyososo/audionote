# Plan: LLM Transcription Optimization

## Overview

Add LLM-powered transcription text optimization as an optional feature. When enabled, the recorded transcription text is automatically sent to LLM for punctuation correction and homophone error fixing.

## Tech Stack

- Swift 5.9 + SwiftUI
- iOS Speech Framework
- MVVM Architecture
- Existing LLMService for API calls

## Architecture

### Settings Page
- Add `enableLLMOptimization` toggle in SettingsView
- Store preference in UserDefaults (key: `audioNote:enableLLMOptimization`)
- Validate LLM availability when toggle is turned ON (show loading, call API, show result)

### Transcription Flow
1. User records audio → Speech Recognition produces text
2. Recording stops → Check if `enableLLMOptimization` is ON
3. If ON: Show loading, call LLM optimization API, replace text with optimized result
4. If OFF: Keep original text, no LLM call

### LLMService Changes
- Add `optimize(_ text: String, token: String) async throws -> String` method
- Use multi-language prompt for punctuation and homophone correction

## File Changes

| File | Change |
|------|--------|
| `SettingsViewModel.swift` | Add `enableLLMOptimization` and `isValidating` properties |
| `SettingsView.swift` | Add toggle UI and validation logic |
| `LLMService.swift` | Add `optimize()` method |
| `TranscriptionViewModel.swift` | Call LLM optimization after recording |
| `TranscriptionRecord.swift` | Add `optimizedContent` field |

## Prompt Design

```
你是一个语音转录文本优化助手。原始文本由 iOS Speech SDK 生成，可能存在标点缺失、同音词错误等问题。
请直接返回优化后的文本，不要添加任何解释或标记。
```

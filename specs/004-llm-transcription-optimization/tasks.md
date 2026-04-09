# Tasks: LLM Transcription Optimization

## Phase 1: Settings Page

- [x] **1.1** Update `SettingsViewModel.swift`
  - Add `@Published var enableLLMOptimization: Bool = false`
  - Add `@Published var isValidating: Bool = false`
  - Add `@Published var validationMessage: String?`
  - Load/save `enableLLMOptimization` from UserDefaults (key: `audioNote:enableLLMOptimization`)
  - Add `validateLLMConfiguration()` method to test API connectivity

- [x] **1.2** Update `SettingsView.swift`
  - Add Toggle("启用录音优化") bound to `enableLLMOptimization`
  - When toggle turns ON: call `validateLLMConfiguration()` with loading state
  - Show success/failure toast based on validation result
  - Disable toggle during validation

## Phase 2: LLMService Enhancement

- [x] **2.1** Add `optimize()` method to `LLMService.swift`
  - Create `OptimizeRequest` struct with messages
  - Create `OptimizeResponse` struct for simple text response
  - Implement `optimize(_ text: String, token: String) async throws -> String`
  - Use multi-language optimization prompt

## Phase 3: TranscriptionViewModel Integration

- [x] **3.1** Update `TranscriptionViewModel.swift`
  - Add `@Published var isOptimizing: Bool = false`
  - Add `optimizeTranscription()` method
  - Modify `stopRecording()` to check `enableLLMOptimization` setting and call optimization if enabled
  - Replace `transcribedText` with optimized text after completion

## Phase 4: UI Loading State

- [x] **4.1** Update `RecordingView.swift`
  - Show loading indicator when `isOptimizing` is true
  - Display "正在优化..." text during optimization

## Phase 5: Verification

- [ ] **5.1** Test toggle validation in Settings
- [ ] **5.2** Test optimization with toggle ON
- [ ] **5.3** Test no optimization with toggle OFF
- [ ] **5.4** Verify Chinese text optimization
- [ ] **5.5** Verify English text optimization

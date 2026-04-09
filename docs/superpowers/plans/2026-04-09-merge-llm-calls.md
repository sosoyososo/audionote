# Merge LLM Calls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge two separate LLM calls (optimize transcript + extract tags) into one unified call triggered after recording ends.

**Architecture:** Add `optimizeAndProcess()` method to `LLMService` that returns all results in one JSON. Replace existing `optimizeTranscription()` flow with unified call in `TranscriptionViewModel`. Update UI states in `RecordingView` and `TranscriptionDetailView`.

**Tech Stack:** Swift 5.9, SwiftUI, Speech Framework, AVFoundation

---

## File Map

| File | Responsibility |
|------|----------------|
| `ios/AudioNote/Services/LLMService.swift` | Add `optimizeAndProcess()` method with combined prompt and result struct |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` | Replace `optimizeTranscription()` with unified call, add retry logic, update record with all fields |
| `ios/AudioNote/Views/RecordingView.swift` | Add `isLLMProcessing`, `llmProcessingFailed` states; show loading/retry/optimized label |
| `ios/AudioNote/Views/TranscriptionDetailView.swift` | Show "优化后" label when `optimizedContent != nil`, show retry button on failure |

---

## Task 1: Add `optimizeAndProcess()` to LLMService

**Files:**
- Modify: `ios/AudioNote/Services/LLMService.swift`

- [ ] **Step 1: Add new result struct after `LLMResult` (line 27)**

```swift
struct LLMOptimizeAndProcessResult: Decodable {
    let optimizedText: String
    let title: String
    let summary: String
    let tags: [String]
}
```

- [ ] **Step 2: Add `optimizeAndProcess()` method after `optimize()` method (after line 182)**

```swift
func optimizeAndProcess(_ text: String, token: String) async throws -> LLMOptimizeAndProcessResult {
    guard !token.isEmpty else {
        Logger.error("LLM optimizeAndProcess failed: token not set")
        throw LLMError.tokenNotSet
    }

    let systemPrompt = """
你是一个语音转录文本优化助手和笔记组织助手。原始文本由 iOS Speech SDK 生成，可能存在标点缺失、同音词错误等问题。

请完成以下任务：
1. 优化转录文本，修正标点和同音词错误
2. 为笔记提取标题（简短明了）
3. 生成50-100字的摘要
4. 提取3-5个标签

请严格按照以下JSON格式返回，不要添加任何解释或标记：
{"optimizedText": "...", "title": "...", "summary": "...", "tags": [...]}
"""

    let request = APIRequest(messages: [
        APIRequest.Message(role: "system", content: systemPrompt),
        APIRequest.Message(role: "user", content: text)
    ])

    return try await callOptimizeAndProcessAPI(request: request, token: token)
}
```

- [ ] **Step 3: Add `callOptimizeAndProcessAPI()` private method after `callOptimizeAPI()` (after line 214)**

```swift
private func callOptimizeAndProcessAPI(request: APIRequest, token: String) async throws -> LLMOptimizeAndProcessResult {
    guard let url = URL(string: baseURL) else {
        throw LLMError.invalidURL
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try JSONEncoder().encode(request)

    let (data, response) = try await URLSession.shared.data(for: urlRequest)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw LLMError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
        let responseBody = String(data: data, encoding: .utf8) ?? "unable to decode response body"
        Logger.error("LLM API error: HTTP \(httpResponse.statusCode), body: \(responseBody)")
        throw LLMError.httpError(httpResponse.statusCode)
    }

    let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)

    guard let content = apiResponse.choices.first?.message.content else {
        throw LLMError.invalidResponse
    }

    guard let jsonData = content.data(using: .utf8) else {
        throw LLMError.decodingError
    }

    return try JSONDecoder().decode(LLMOptimizeAndProcessResult.self, from: jsonData)
}
```

- [ ] **Step 4: Commit**

```bash
git add ios/AudioNote/Services/LLMService.swift
git commit -m "feat: add optimizeAndProcess method to LLMService"
```

---

## Task 2: Update TranscriptionViewModel with unified LLM call and retry logic

**Files:**
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`

- [ ] **Step 1: Add new properties after `isOptimizing` (line 16)**

```swift
@Published var isLLMProcessing: Bool = false
@Published var llmProcessingFailed: Bool = false
```

- [ ] **Step 2: Replace `stopRecording()` LLM call section (lines 186-194)**

Find:
```swift
// Check if LLM optimization is enabled
let optimizationEnabled = UserDefaults.standard.bool(forKey: "audioNote:enableLLMOptimization")
if optimizationEnabled {
    await optimizeTranscription(recordId: record.id)
}

Task {
    await aiProcessingService.processPendingRecords()
}
```

Replace with:
```swift
// Check if LLM optimization is enabled
let optimizationEnabled = UserDefaults.standard.bool(forKey: "audioNote:enableLLMOptimization")
if optimizationEnabled {
    await processWithLLM(recordId: record.id, originalText: contentToSave)
}
```

- [ ] **Step 3: Replace `optimizeTranscription()` method (lines 203-226) with new `processWithLLM()` method**

Find:
```swift
func optimizeTranscription(recordId: UUID) async {
    isOptimizing = true

    let token = UserDefaults.standard.string(forKey: "audioNote:llmToken") ?? ""

    do {
        let optimizedContent = try await llmService.optimize(transcribedText, token: token)
        Logger.info("LLM optimization succeeded, original length: \(transcribedText.count), optimized length: \(optimizedContent.count)")

        // Update the record with optimized content
        if var record = try? await storage.get(id: recordId) {
            record.content = optimizedContent
            record.optimizedContent = transcribedText // Keep original
            try await storage.save(record)
            transcribedText = optimizedContent
            await loadHistory()
        }
    } catch {
        Logger.error("LLM optimization failed: \(error.localizedDescription)")
        // Keep original text if optimization fails
    }

    isOptimizing = false
}
```

Replace with:
```swift
func processWithLLM(recordId: UUID, originalText: String) async {
    isLLMProcessing = true
    llmProcessingFailed = false

    let token = UserDefaults.standard.string(forKey: "audioNote:llmToken") ?? ""
    let maxAttempts = 3
    var lastError: Error?

    for attempt in 0..<maxAttempts {
        do {
            let result = try await llmService.optimizeAndProcess(originalText, token: token)
            Logger.info("LLM processWithLLM succeeded on attempt \(attempt + 1)")

            // Update the record with all fields
            if var record = try? await storage.get(id: recordId) {
                record.optimizedContent = originalText // Keep original
                record.content = result.optimizedText
                record.title = result.title
                record.summary = result.summary
                record.tags = result.tags
                record.llmProcessingStatus = .completed
                try await storage.save(record)
                transcribedText = result.optimizedText
                await loadHistory()
            }

            isLLMProcessing = false
            llmProcessingFailed = false
            return
        } catch {
            lastError = error
            Logger.warning("LLM processWithLLM failed (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")

            if attempt < maxAttempts - 1 {
                let delay = 1.0 * pow(2.0, Double(attempt))
                Logger.info("Retrying in \(delay)s...")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // All attempts failed
    Logger.error("LLM processWithLLM failed after \(maxAttempts) attempts")
    isLLMProcessing = false
    llmProcessingFailed = true

    // Mark record as failed
    if var record = try? await storage.get(id: recordId) {
        record.llmProcessingStatus = .failed
        try? await storage.save(record)
    }
}
```

- [ ] **Step 4: Update references to `isOptimizing` in UI bindings**

The existing `isOptimizing` binding in RecordingView (line 250-258) checks `viewModel.isOptimizing`. Update RecordingView to use `viewModel.isLLMProcessing` instead.

- [ ] **Step 5: Commit**

```bash
git add ios/AudioNote/ViewModels/TranscriptionViewModel.swift
git commit -m "feat: merge LLM calls with unified processWithLLM and retry logic"
```

---

## Task 3: Update RecordingView UI states

**Files:**
- Modify: `ios/AudioNote/Views/RecordingView.swift`

- [ ] **Step 1: Update text section header - replace `isOptimizing` checks (lines 250-258)**

Find:
```swift
} else if viewModel.isOptimizing {
    HStack(spacing: 6) {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
            .scaleEffect(0.8)
        Text("正在优化...")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    Spacer()
```

Replace with:
```swift
} else if viewModel.isLLMProcessing {
    HStack(spacing: 6) {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
            .scaleEffect(0.8)
        Text("正在处理...")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    Spacer()
} else if viewModel.llmProcessingFailed {
    HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle")
            .foregroundColor(.orange)
        Text("处理失败")
            .font(.caption)
            .foregroundColor(.orange)
        Button("重试") {
            Task {
                if let recordId = viewModel.currentRecordId,
                   let record = await viewModel.getRecord(id: recordId) {
                    await viewModel.processWithLLM(recordId: recordId, originalText: record.optimizedContent ?? record.content)
                }
            }
        }
        .font(.caption)
        .foregroundColor(.accentColor)
    }
    Spacer()
```

- [ ] **Step 2: Update text content area - replace `isOptimizing` loading view (lines 302-314)**

Find:
```swift
} else if viewModel.isOptimizing {
    // Optimization loading
    VStack {
        ProgressView()
            .padding()
        Text("正在优化转录内容...")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(.bottom)
    }
    .frame(maxWidth: .infinity)
    .background(Color(.systemGray6))
    .cornerRadius(12)
```

Replace with:
```swift
} else if viewModel.isLLMProcessing {
    // LLM processing loading
    VStack {
        ProgressView()
            .padding()
        Text("正在处理转录内容...")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(.bottom)
    }
    .frame(maxWidth: .infinity)
    .background(Color(.systemGray6))
    .cornerRadius(12)
} else if viewModel.llmProcessingFailed {
    // Show original text with retry option
    VStack {
        Image(systemName: "exclamationmark.triangle")
            .foregroundColor(.orange)
            .padding(.top)
        Text("处理失败，请点击上方重试")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(.bottom)
    }
    .frame(maxWidth: .infinity)
    .background(Color(.systemGray6))
    .cornerRadius(12)
```

- [ ] **Step 3: Add "优化后" label in resultTextView when text is optimized**

Find `resultTextView` computed property and update it to show "优化后" label when `viewModel.llmProcessingFailed == false && viewModel.isLLMProcessing == false && !viewModel.transcribedText.isEmpty` and we know optimization was applied.

Actually, looking at the design, we need to know if the text was actually optimized. The ViewModel doesn't currently track this. We need to add a way to detect if optimization succeeded. Let me check if we can use `isOptimizing` state differently.

Wait - the issue is we need to track whether optimization succeeded. The current flow:
- `isLLMProcessing = true` during processing
- If all 3 attempts fail: `llmProcessingFailed = true`
- If succeeds: both are false, and `transcribedText` contains optimized text

But we can't tell from the View alone if the text was optimized vs just saved. We need to add a tracking property.

- [ ] **Step 3a: Add `isTextOptimized: Bool` property to TranscriptionViewModel**

Add after line 17:
```swift
@Published var isTextOptimized: Bool = false
```

- [ ] **Step 3b: Set `isTextOptimized = true` in `processWithLLM()` on success**

In `processWithLLM()`, after successful save, add:
```swift
isTextOptimized = true
```

And reset it in `startRecording()`:
```swift
isTextOptimized = false
```

- [ ] **Step 3c: Update RecordingView to show "优化后" label**

In `resultTextView`, update to show a label when `viewModel.isTextOptimized` is true. Add a label above the text:

```swift
if viewModel.isTextOptimized {
    HStack {
        Image(systemName: "checkmark.seal.fill")
            .foregroundColor(.green)
        Text("优化后")
            .font(.caption)
            .foregroundColor(.green)
        Spacer()
    }
    .padding(.bottom, 4)
}
```

- [ ] **Step 4: Commit**

```bash
git add ios/AudioNote/Views/RecordingView.swift
git commit -m "feat: update RecordingView UI for LLM processing states"
```

---

## Task 4: Update TranscriptionDetailView

**Files:**
- Modify: `ios/AudioNote/Views/TranscriptionDetailView.swift`

- [ ] **Step 1: Add "优化后" label to content section header when `optimizedContent` exists**

In `contentSection` (line 124), add header showing "优化后" when `record.optimizedContent != nil`:

```swift
private var contentSection: some View {
    VStack(alignment: .leading, spacing: 8) {
        if record.optimizedContent != nil {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                Text("优化后")
                    .font(.caption)
                    .foregroundColor(.green)
                Spacer()
            }
        }

        Group {
            if isEditing {
                TextEditor(text: $editedContent)
                    .font(.body)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
            } else {
                Text(editedContent)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
```

- [ ] **Step 2: Update `reprocessRecord()` to use unified LLM call**

The current `reprocessRecord()` uses `AIProcessingService.processRecord()` which only extracts title/summary/tags. We need to update it to use the new unified flow. However, since `AIProcessingService` still uses the old `process()` method, we need to decide: should `reprocessRecord()` also re-optimize?

Based on design, when user clicks retry, it should do the full unified process. But `TranscriptionDetailView` doesn't have direct access to the original text for re-optimization.

Actually, looking at the flow:
- `record.content` = current (possibly optimized) text
- `record.optimizedContent` = original text (if optimized)

For retry, we should use `record.optimizedContent ?? record.content` as the original text.

Update `reprocessRecord()`:

```swift
private func reprocessRecord() {
    isProcessing = true
    currentLLMStatus = .processing
    Task {
        let originalText = record.optimizedContent ?? record.content
        let token = UserDefaults.standard.string(forKey: "audioNote:llmToken") ?? ""
        let llmService = LLMService()

        do {
            let result = try await llmService.optimizeAndProcess(originalText, token: token)
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
                optimizedContent: originalText != record.content ? originalText : record.optimizedContent
            )
            try await viewModel.updateRecord(updatedRecord)
            await MainActor.run {
                isProcessing = false
                currentLLMStatus = .completed
                currentTitle = result.title
                currentSummary = result.summary
                currentTags = result.tags
                editedContent = result.optimizedText
            }
        } catch {
            Logger.error("LLM reprocess failed: \(error.localizedDescription)")
            await MainActor.run {
                isProcessing = false
                currentLLMStatus = .failed
            }
        }
        await viewModel.loadHistory()
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/Views/TranscriptionDetailView.swift
git commit -m "feat: update TranscriptionDetailView for merged LLM calls"
```

---

## Task 5: Verify build

- [ ] **Step 1: Run Xcode build**

```bash
cd /Users/karsa/proj/audionote/ios && xcodebuild -project AudioNote.xcodeproj -scheme AudioNote -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -50
```

Expected: BUILD SUCCEEDED

---

## Spec Coverage Check

- [x] LLMService new unified method → Task 1
- [x] Single call replaces two separate calls → Task 2
- [x] Retry up to 2 times (3 total) → Task 2
- [x] Failed state with retry button → Tasks 2, 3, 4
- [x] RecordingView shows loading → Task 3
- [x] RecordingView shows "优化后" on success → Task 3
- [x] TranscriptionDetailView shows "优化后" on success → Task 4
- [x] Settings structure unchanged → N/A (no changes needed)
- [x] Original text preserved in `optimizedContent` → Task 2

---

## Self-Review

1. **Placeholder scan**: No TBD/TODO found - all code is complete
2. **Type consistency**: `LLMOptimizeAndProcessResult` struct defined in Task 1, used in Tasks 2 and 4
3. **Method names**: `processWithLLM()` in ViewModel, `optimizeAndProcess()` in LLMService - consistent naming
4. **Property names**: `isLLMProcessing`, `llmProcessingFailed`, `isTextOptimized` - all clearly named

# LLM Processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add LLM-powered post-transcription processing to extract title, summary, and tags from voice transcription records, with auto-processing after recording and manual reprocessing option.

**Architecture:** MVVM pattern with dedicated service layer. LLMService handles API calls with retry logic. AIProcessingService coordinates auto/manual triggering. SettingsViewModel manages token persistence. TranscriptionRecord extended with LLM processing fields.

**Tech Stack:** Swift 5.9, SwiftUI, AVFoundation, Speech Framework, URLSession for API calls

---

## File Structure

### New Files to Create

| File | Responsibility |
|------|----------------|
| `ios/AudioNote/Services/LLMService.swift` | API calls to llm.karsa.info with retry logic |
| `ios/AudioNote/Services/AIProcessingService.swift` | Auto/manual processing orchestration |
| `ios/AudioNote/ViewModels/SettingsViewModel.swift` | Token persistence via UserDefaults |
| `ios/AudioNote/Views/SettingsView.swift` | Settings Tab UI with token input |

Note: `LLMStatus` enum is defined inside `TranscriptionRecord.swift` as a nested type, not a separate file.

### Files to Modify

| File | Changes |
|------|---------|
| `ios/AudioNote/Models/TranscriptionRecord.swift` | Add title, summary, tags, llmProcessingStatus fields |
| `ios/AudioNote/Views/ContentView.swift` | Add Settings Tab |
| `ios/AudioNote/Views/TranscriptionDetailView.swift` | Display LLM results, add manual trigger button |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` | Integrate auto-processing after recording |

---

## Task 1: Extend TranscriptionRecord Model

**Files:**
- Modify: `ios/AudioNote/Models/TranscriptionRecord.swift`

- [ ] **Step 1: Add LLMStatus enum and fields to TranscriptionRecord**

```swift
import Foundation

enum LLMStatus: String, Codable {
    case pending
    case processing
    case completed
    case failed
}

struct TranscriptionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var content: String
    let createdAt: Date
    var duration: TimeInterval?
    var language: String?
    var audioFileName: String?

    // LLM processing fields
    var title: String?
    var summary: String?
    var tags: [String]?
    var llmProcessingStatus: LLMStatus?

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
        llmProcessingStatus: LLMStatus? = nil
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
    }

    // ... existing computed properties ...
}
```

- [ ] **Step 2: Update save method in TranscriptionStorage to handle new fields**

Check `TranscriptionStorage.swift` for JSONEncoder configuration - may need to add custom coding keys if not using direct encoding.

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/Models/TranscriptionRecord.swift
git commit -m "feat: extend TranscriptionRecord with LLM processing fields"
```

---

## Task 2: Create LLMService

**Files:**
- Create: `ios/AudioNote/Services/LLMService.swift`
- Test: Manual API testing via Xcode console

- [ ] **Step 1: Create LLMService with API call logic**

```swift
import Foundation

enum LLMError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError
    case tokenNotSet
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let code): return "HTTP error: \(code)"
        case .decodingError: return "Failed to decode response"
        case .tokenNotSet: return "API token not set"
        case .networkError(let error): return error.localizedDescription
        }
    }
}

struct LLMResult {
    let title: String
    let summary: String
    let tags: [String]
}

actor LLMService {
    private let baseURL = "https://llm.karsa.info/v1/chat/completions"
    private let maxRetries = 3
    private let baseDelay: TimeInterval = 1.0

    struct APIRequest: Encodable {
        let model: String = "gpt-4o-mini"
        let messages: [Message]

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    struct APIResponse: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let message: Message

            struct Message: Decodable {
                let content: String
            }
        }
    }

    struct LLMResponse: Decodable {
        let title: String
        let summary: String
        let tags: [String]
    }

    func process(_ transcription: String, token: String) async throws -> LLMResult {
        guard !token.isEmpty else {
            throw LLMError.tokenNotSet
        }

        let systemPrompt = """
        You are a note organizer. Extract title, summary (50-100 chars), and tags (3-5) from the following transcription.
        Response JSON format only, no other text:
        {"title": "...", "summary": "...", "tags": [...]}
        """

        let request = APIRequest(messages: [
            APIRequest.Message(role: "system", content: systemPrompt),
            APIRequest.Message(role: "user", content: transcription)
        ])

        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                return try await callAPI(request: request, token: token)
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    let delay = baseDelay * pow(2.0, Double(attempt))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? LLMError.networkError(NSError(domain: "LLMService", code: -1))
    }

    private func callAPI(request: APIRequest, token: String) async throws -> LLMResult {
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
            throw LLMError.httpError(httpResponse.statusCode)
        }

        let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)

        guard let content = apiResponse.choices.first?.message.content else {
            throw LLMError.invalidResponse
        }

        // Parse JSON from content string
        guard let jsonData = content.data(using: .utf8) else {
            throw LLMError.decodingError
        }

        let llmResponse = try JSONDecoder().decode(LLMResponse.self, from: jsonData)

        return LLMResult(
            title: llmResponse.title,
            summary: llmResponse.summary,
            tags: llmResponse.tags
        )
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/AudioNote/Services/LLMService.swift
git commit -m "feat: add LLMService for API calls with retry"
```

---

## Task 3: Create SettingsViewModel and SettingsView

**Files:**
- Create: `ios/AudioNote/ViewModels/SettingsViewModel.swift`
- Create: `ios/AudioNote/Views/SettingsView.swift`

- [ ] **Step 1: Create SettingsViewModel**

```swift
import Foundation
import Combine

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var llmToken: String = ""
    @Published var showSaveConfirmation: Bool = false

    private let tokenKey = "llm.api.token"

    init() {
        loadToken()
    }

    func loadToken() {
        llmToken = UserDefaults.standard.string(forKey: tokenKey) ?? ""
    }

    func saveToken() {
        UserDefaults.standard.set(llmToken, forKey: tokenKey)
        showSaveConfirmation = true

        // Reset confirmation after delay
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showSaveConfirmation = false
        }
    }

    var hasToken: Bool {
        !llmToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
```

- [ ] **Step 2: Create SettingsView**

```swift
import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @EnvironmentObject private var languageManager: LanguageManager

    var body: some View {
        NavigationView {
            Form {
                Section {
                    SecureField("LLM API Token", text: $viewModel.llmToken)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    Button("Action.Save".localized) {
                        viewModel.saveToken()
                    }
                    .disabled(viewModel.llmToken.isEmpty)
                } header: {
                    Text("Settings.LLM.Title")
                } footer: {
                    Text("Settings.LLM.Footer")
                }

                Section {
                    HStack {
                        Text("Settings.LLM.Status")
                        Spacer()
                        if viewModel.hasToken {
                            Text("✅ Configured")
                                .foregroundColor(.secondary)
                        } else {
                            Text("⚠️ Not Set")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Tab.Settings".localized)
            .overlay(alignment: .bottom) {
                if viewModel.showSaveConfirmation {
                    ToastView(message: "Settings.Saved".localized, isShowing: .constant(true))
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(LanguageManager.shared)
}
```

- [ ] **Step 3: Add localization strings**

Add to Localizable.strings:
```
"Tab.Settings" = "Settings";
"Settings.LLM.Title" = "LLM Configuration";
"Settings.LLM.Footer" = "Enter your API token for LLM processing. Token is stored locally on device.";
"Settings.LLM.Status" = "Token Status";
"Settings.Saved" = "Settings saved";
```

- [ ] **Step 4: Commit**

```bash
git add ios/AudioNote/ViewModels/SettingsViewModel.swift ios/AudioNote/Views/SettingsView.swift
git commit -m "feat: add Settings tab with LLM token configuration"
```

---

## Task 4: Add Settings Tab to ContentView

**Files:**
- Modify: `ios/AudioNote/Views/ContentView.swift`

- [ ] **Step 1: Add Settings tab**

```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    @EnvironmentObject private var languageManager: LanguageManager
    @State private var refreshId = UUID()

    var body: some View {
        ZStack {
            TabView {
                RecordingView(viewModel: viewModel)
                    .tabItem {
                        Label("Tab.Recording".localized(for: languageManager.current), systemImage: "mic.fill")
                    }

                HistoryListView(viewModel: viewModel)
                    .tabItem {
                        Label("Tab.History".localized(for: languageManager.current), systemImage: "list.bullet")
                    }

                SettingsView()
                    .tabItem {
                        Label("Tab.Settings".localized(for: languageManager.current), systemImage: "gear")
                    }
            }
            .environmentObject(viewModel)
        }
        .id(refreshId)
        .onReceive(NotificationCenter.default.publisher(for: .languageChanged)) { _ in
            refreshId = UUID()
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/AudioNote/Views/ContentView.swift
git commit -m "feat: add Settings tab to ContentView"
```

---

## Task 5: Create AIProcessingService

**Files:**
- Create: `ios/AudioNote/Services/AIProcessingService.swift`

- [ ] **Step 1: Create AIProcessingService**

```swift
import Foundation

actor AIProcessingService {
    private let llmService = LLMService()
    private let storage = TranscriptionStorage.shared

    func processRecord(_ record: TranscriptionRecord) async -> TranscriptionRecord {
        let token = UserDefaults.standard.string(forKey: "llm.api.token") ?? ""

        var updatedRecord = record
        updatedRecord.llmProcessingStatus = .processing

        do {
            let result = try await llmService.process(record.content, token: token)
            updatedRecord.title = result.title
            updatedRecord.summary = result.summary
            updatedRecord.tags = result.tags
            updatedRecord.llmProcessingStatus = .completed
        } catch {
            Logger.error("LLM processing failed for record \(record.id): \(error.localizedDescription)")
            updatedRecord.llmProcessingStatus = .failed
        }

        do {
            try await storage.save(updatedRecord)
        } catch {
            Logger.error("Failed to save processed record: \(error.localizedDescription)")
        }
        return updatedRecord
    }

    /// Process records that have never been processed (llmProcessingStatus == nil)
    /// Records with .failed status are NOT auto-processed to avoid infinite loops
    func processPendingRecords() async {
        do {
            let records = try await storage.loadAll()
            // Only process records with nil status (never processed)
            // Do NOT auto-process .failed records to avoid infinite retry loops
            let pendingRecords = records.filter { $0.llmProcessingStatus == nil }

            for record in pendingRecords {
                _ = await processRecord(record)
            }
        } catch {
            Logger.error("Failed to load records for processing: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/AudioNote/Services/AIProcessingService.swift
git commit -m "feat: add AIProcessingService for auto/manual processing"
```

---

## Task 6: Integrate Auto-Processing in TranscriptionViewModel

**Files:**
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`

- [ ] **Step 1: Add AIProcessingService and auto-process after save**

Add property and modify stopRecording:

```swift
// Add to class properties
private let aiProcessingService = AIProcessingService()

// Modify stopRecording() - add after successful save:
Task {
    await aiProcessingService.processPendingRecords()
}
```

- [ ] **Step 2: Update updateRecord() to preserve LLM fields**

Modify the `updateRecord()` method to include LLM fields:

```swift
func updateRecord(_ record: TranscriptionRecord) async throws {
    // Preserve the original createdAt timestamp when updating
    let existingRecord = try await storage.get(id: record.id)
    let updatedRecord = TranscriptionRecord(
        id: record.id,
        content: record.content,
        createdAt: existingRecord?.createdAt ?? record.createdAt,
        duration: record.duration,
        language: record.language,
        // Preserve LLM fields
        title: record.title,
        summary: record.summary,
        tags: record.tags,
        llmProcessingStatus: record.llmProcessingStatus
    )
    try await storage.save(updatedRecord)
    await loadHistory()
}
```

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/ViewModels/TranscriptionViewModel.swift
git commit -m "feat: integrate auto LLM processing after recording"
```

---

## Task 7: Add Manual Trigger and Display to TranscriptionDetailView

**Files:**
- Modify: `ios/AudioNote/Views/TranscriptionDetailView.swift`

- [ ] **Step 1: Add LLM results section and manual trigger button**

```swift
import SwiftUI

struct TranscriptionDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var viewModel: TranscriptionViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var actionsViewModel = RecordActionsViewModel()
    @State private var isEditing = false
    @State private var editedContent: String = ""
    @State private var isProcessing = false

    // ... existing init and body ...

    private var llmResultsSection: some View {
        Group {
            if record.title != nil || record.summary != nil || record.tags != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()

                    if let title = record.title, !title.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Detail.LLM.Title".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(title)
                                .font(.headline)
                        }
                    }

                    if let summary = record.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Detail.LLM.Summary".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(summary)
                                .font(.body)
                        }
                    }

                    if let tags = record.tags, !tags.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Detail.LLM.Tags".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            FlowLayout(spacing: 8) {
                                ForEach(tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.1))
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }

                    Button {
                        Task {
                            isProcessing = true
                            let processingService = AIProcessingService()
                            _ = await processingService.processRecord(record)
                            // Reload the view to show updated data
                            await viewModel.loadHistory()
                            isProcessing = false
                        }
                    } label: {
                        HStack {
                            if isProcessing {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Detail.LLM.Reprocess".localized)
                        }
                    }
                    .disabled(isProcessing)
                }
            }
        }
    }

    // Add FlowLayout for tags
    struct FlowLayout: Layout {
        var spacing: CGFloat = 8

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
            return result.size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
            for (index, subview) in subviews.enumerated() {
                subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                         y: bounds.minY + result.positions[index].y),
                             proposal: .unspecified)
            }
        }

        struct FlowResult {
            var size: CGSize = .zero
            var positions: [CGPoint] = []

            init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
                var x: CGFloat = 0
                var y: CGFloat = 0
                var rowHeight: CGFloat = 0

                for subview in subviews {
                    let size = subview.sizeThatFits(.unspecified)
                    if x + size.width > maxWidth && x > 0 {
                        x = 0
                        y += rowHeight + spacing
                        rowHeight = 0
                    }
                    positions.append(CGPoint(x: x, y: y))
                    rowHeight = max(rowHeight, size.height)
                    x += size.width + spacing
                }

                self.size = CGSize(width: maxWidth, height: y + rowHeight)
            }
        }
    }
}
```

- [ ] **Step 2: Update saveEditing() to preserve LLM fields**

The existing `saveEditing()` function creates a new TranscriptionRecord without LLM fields. Update it to include them:

```swift
private func saveEditing() {
    let updatedRecord = TranscriptionRecord(
        id: record.id,
        content: editedContent,
        createdAt: record.createdAt,
        duration: record.duration,
        language: record.language,
        title: record.title,
        summary: record.summary,
        tags: record.tags,
        llmProcessingStatus: record.llmProcessingStatus
    )
    // ... rest of function
}
```

- [ ] **Step 3: Add to content section in body**

In the ScrollView content, add `llmResultsSection` after `contentSection`.

- [ ] **Step 4: Add localization strings**

```
"Detail.LLM.Title" = "Title";
"Detail.LLM.Summary" = "Summary";
"Detail.LLM.Tags" = "Tags";
"Detail.LLM.Reprocess" = "AI Reprocess";
```

- [ ] **Step 5: Commit**

```bash
git add ios/AudioNote/Views/TranscriptionDetailView.swift
git commit -m "feat: add LLM results display and manual reprocess button"
```

---

## Task 8: Add Project to Xcode

**Files:**
- Modify: `project.yml` or use Xcode to add new files

- [ ] **Step 1: Add new files to Xcode project**

New files to add:
- `ios/AudioNote/Services/LLMService.swift`
- `ios/AudioNote/Services/AIProcessingService.swift`
- `ios/AudioNote/ViewModels/SettingsViewModel.swift`
- `ios/AudioNote/Views/SettingsView.swift`

Open Xcode and add these files to the AudioNote target.

- [ ] **Step 2: Build and verify**

```bash
cd ios && xcodebuild -scheme AudioNote -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Expected: BUILD SUCCEEDED

---

## Summary

| Task | Files | Status |
|------|-------|--------|
| 1 | TranscriptionRecord.swift | ⬜ |
| 2 | LLMService.swift | ⬜ |
| 3 | SettingsViewModel.swift, SettingsView.swift | ⬜ |
| 4 | ContentView.swift | ⬜ |
| 5 | AIProcessingService.swift | ⬜ |
| 6 | TranscriptionViewModel.swift (updateRecord fix) | ⬜ |
| 7 | TranscriptionDetailView.swift (LLM display + saveEditing fix) | ⬜ |
| 8 | Xcode project | ⬜ |

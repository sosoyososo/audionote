# LLM Processing Feature Design

## Overview

Add LLM-powered post-transcription processing to extract title, summary, and tags from voice transcription records. The feature includes automatic processing after recording and manual reprocessing option.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    ContentView (TabView)                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │Recording │  │ History  │  │ Settings │              │
│  │   Tab    │  │   Tab    │  │   Tab    │              │
│  └──────────┘  └──────────┘  └──────────┘              │
└─────────────────────────────────────────────────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
┌─────────────────┐ ┌──────────────┐ ┌───────────────┐
│TranscriptionVM  │ │AIProcessVM   │ │ SettingsViewModel│
│  (recording)    │ │(LLM calling) │ │ (token save)  │
└────────┬────────┘ └──────┬───────┘ └───────┬───────┘
         │                 │                 │
         ▼                 ▼                 ▼
┌─────────────────┐ ┌──────────────┐ ┌───────────────┐
│SpeechRecognizer │ │ LLMService   │ │ UserDefaults  │
│ (transcription) │ │ (API call)   │ │ (token store) │
└─────────────────┘ └──────────────┘ └───────────────┘
```

## Data Model

### TranscriptionRecord Extension

```swift
struct TranscriptionRecord {
    let id: UUID
    var content: String       // Original transcription text
    let createdAt: Date
    var duration: TimeInterval?
    var language: String?
    var audioFileName: String?

    // New LLM processing fields
    var title: String?        // Extracted title
    var summary: String?      // Summary excerpt
    var tags: [String]?       // Tag list
    var llmProcessingStatus: LLMStatus?  // Processing status
}

enum LLMStatus: String, Codable {
    case pending
    case processing
    case completed
    case failed
}
```

## Components

| Component | Responsibility |
|----------|----------------|
| `LLMService` | Call llm.karsa.info API, handle request/response/retry |
| `SettingsView` | Settings Tab with Token input field |
| `SettingsViewModel` | Token read/save to UserDefaults |
| `AIProcessingService` | Coordinate auto/manual triggering, status management |

## Data Flow

### Auto Processing Flow

```
stopRecording()
  → Save TranscriptionRecord (status: .pending)
  → AIProcessingService.processPendingRecords()
  → LLMService.call(title, summary, tags)
  → Update record (status: .completed)
  → Retry failed records (max 3 times)
```

### Manual Processing Flow

```
Detail page tap "AI Process" button
  → LLMService.call()
  → Update record
  → Display result
```

## Settings Page

- **Token Input**: SecureField for API token
- **Token Storage**: UserDefaults with key `llm.api.token`
- **Validation**: Check token is non-empty before API calls

## Error Handling

- Silent retry: 3 attempts with exponential backoff
- On final failure: Set status to `.failed`, show brief toast
- No blocking UI for user

## API Contract

### LLM API Request

```
POST https://llm.karsa.info/v1/chat/completions
Headers:
  Authorization: Bearer {token}
  Content-Type: application/json

Body:
{
  "model": "gpt-4o-mini",
  "messages": [
    {
      "role": "system",
      "content": "You are a note organizer. Extract title, summary (50-100 chars), and tags (3-5) from the following transcription. Response JSON format: {\"title\": \"...\", \"summary\": \"...\", \"tags\": [...]}"
    },
    {
      "role": "user",
      "content": "{transcription_content}"
    }
  ]
}
```

### Expected Response

```json
{
  "choices": [
    {
      "message": {
        "content": "{\"title\": \"...\", \"summary\": \"...\", \"tags\": [...]}"
      }
    }
  ]
}
```

## UI Changes

1. **ContentView**: Add Settings Tab
2. **SettingsView**: Token input field with save button
3. **TranscriptionDetailView**: Display title/summary/tags section, add "AI Process" button for manual trigger

## Implementation Order

1. Extend TranscriptionRecord model with LLM fields
2. Create LLMService for API calls
3. Create SettingsViewModel and SettingsView
4. Add Settings tab to ContentView
5. Create AIProcessingService for auto processing
6. Integrate auto processing in TranscriptionViewModel
7. Add manual trigger button to TranscriptionDetailView
8. Display LLM results in TranscriptionDetailView

# Data Model: iOS 语音转文字

## Entities

### TranscriptionRecord

Represents a single transcription session with its output text.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | UUID | Yes | Unique identifier for the record |
| `content` | String | Yes | The full transcribed text |
| `createdAt` | Date | Yes | Timestamp when recording started |
| `duration` | TimeInterval | No | Recording duration in seconds |
| `language` | String | No | Recognition language (e.g., "zh-CN", "en-US") |

### RecognitionLanguage

Supported recognition languages.

| Language | Identifier | Display Name |
|----------|------------|--------------|
| Chinese | zh-CN | 中文 |
| English | en-US | English |

### Validation Rules

- `content`: Must not be empty after trimming whitespace
- `createdAt`: Must be in the past or present
- `duration`: Must be positive if provided
- `language`: Must be a valid BCP-47 language code if provided

### Relationships

```
TranscriptionRecord
└── No foreign relationships (local-only storage)
```

### State Transitions

```
[New] --save()--> [Persisted]
[Persisted] --delete()--> [Deleted]
```

## Storage Schema

### JSON File Format

Located at: `App_Documents/transcriptions.json`

```json
[
  {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "content": "这是转写的文本内容",
    "createdAt": "2025-01-18T10:30:00Z",
    "duration": 45.5,
    "language": "zh-CN"
  }
]
```

### UserDefaults Keys

- `audioNote:hasOnboarded` - Boolean, whether user has completed initial permission flow
- `audioNote:lastUsedLanguage` - String, BCP-47 language identifier (e.g., "zh-CN")

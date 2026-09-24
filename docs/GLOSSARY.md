# GLOSSARY

> Agent-readable term → symbol map. **Use `codegraph_explore <term>` first**; this file is for terms that don't have an obvious code symbol, or when you need to verify which exact name owns a concept.

> Format: `Term — file:line — short note`. If you can't find a term here, search code before assuming it doesn't exist.

## Domain: Recording / Recognition

| Term | Symbol | Note |
|---|---|---|
| **assess-and-enhance pipeline** | `TranscriptionViewModel.assessAndEnhance` at `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:233` | Phase-2 dispatch: routes `.online` → LLM, `.onDevice` → LLM-or-enhance, `.failed` → retry-from-file |
| **RecordingViewModel** | _(does not exist)_ | **Misnomer trap.** The orchestrator is `TranscriptionViewModel` (line 1 of its file). Don't create one — this name will confuse future readers |
| **RecognitionMode** | `TranscriptionRecord.RecognitionMode` at `ios/AudioNote/Models/TranscriptionRecord.swift:3` | Enum: `.online` / `.onDevice` / `.enhanced` / `.failed`. **Never** add a 5th case without updating `assessAndEnhance` and the UI mode badges |
| **enhanced** | `RecognitionMode.enhanced` | Set when `SpeechRecognizer.recognizeFromFile` succeeds; means we re-ran recognition against the saved audio, not the live stream |
| **assess** | informal — no symbol | The dispatch decision itself, lived in `assessAndEnhance`. Don't rename files to "Assessment" |

## Domain: Persistence

| Term | Symbol | Note |
|---|---|---|
| **TranscriptionRecord** | `ios/AudioNote/Models/TranscriptionRecord.swift:17` | The on-disk model. JSON-serialized by `TranscriptionStorage`. Adding a field is a **schema change** — see Contracts (not yet written) |
| **optimizedContent** | field on `TranscriptionRecord` | User-edited text. **Invariant**: when `optimizedContent != content`, auto-enhance MUST skip (see `assessAndEnhance` skipped branch) |
| **audioFileName** | field on `TranscriptionRecord` | UUID + `.m4a`. File URL is reconstructed via `AudioRecorderService.generateFileUrl(for: uuid)` — **do not** store URLs directly |
| **archived** | field on `TranscriptionRecord` (Bool, default `false`) | When true, record is hidden from `LibraryListView.displayedRecords`. Still counted by `archivedHitIDs` when matching the current search/tag filters |
| **archivedAt** | field on `TranscriptionRecord` (`Date?`, default `nil`) | Set when archived; cleared on unarchive. Drives archive ordering and freshness logic if added later |
| **TranscriptionStorage** | `ios/AudioNote/Services/TranscriptionStorage.swift:26` | Single source of truth for read/write of records. Always go through this; don't write JSON manually |

## Domain: Services (boundary, do not cross directly)

| Term | Symbol | Note |
|---|---|---|
| **AudioRecorderService** | `ios/AudioNote/Services/AudioRecorderService.swift:4` | Owns audio file naming and lifecycle. Use `generateFileUrl(for:)` to derive URLs |
| **SpeechRecognizer** | `ios/AudioNote/Services/SpeechRecognizer.swift:34` | Wraps Apple `SFSpeechRecognizer`. Two modes: live stream (`startRecording`) and file re-recognition (`recognizeFromFile`) |
| **LLMService** | `ios/AudioNote/Services/LLMService.swift:38` | Three entry points: `process` (just call), `optimize` (text-only), `optimizeAndProcess` (single API call). **Prefer the merged variant** — see ADR-0002 (TODO) |
| **NetworkMonitor** | `ios/AudioNote/Utilities/NetworkMonitor.swift:4` | Singleton `.shared`. `checkConnectivity()` is the gate before any LLM/online call |
| **AIProcessingService** | `ios/AudioNote/Services/AIProcessingService.swift:3` | Background queue / retry helper. `processPendingRecords` runs on app launch for records left in intermediate states |

## Domain: Configuration / Settings

| Term | Symbol | Note |
|---|---|---|
| **enableLLMOptimization** | `UserDefaults` key `audioNote:enableLLMOptimization` | Read at `assessAndEnhance:234` and elsewhere. **Boolean UserDefaults, not a Settings field** — it's an old shortcut |
| **SettingsViewModel** | `ios/AudioNote/ViewModels/SettingsViewModel.swift:1` | Surface for user-facing toggles. The internal flag is synced from this VM |

## Domain: Navigation

| Term | Symbol | Note |
|---|---|---|
| **思录 (Library)** | `ios/AudioNote/Views/LibraryListView.swift:3` | The renamed History tab (zh: 思录, en: Library). Hosts the records browser with search, tag filter, and archived banner. Previously `HistoryListView`; renamed per docs/superpowers/specs/2026-09-23-library-search-tag-archive-design.md |
| **LibraryArchivedMatchesView** | `ios/AudioNote/Views/LibraryListView.swift` (same file) | Pushed sub-page reached from the archived-hit banner. Shows only archived records that match the parent's current search/tag filters |
| **TaggedItem** | `ios/AudioNote/Models/TranscriptionRecord.swift` | `(name: String, score: Double)` — a tag with LLM-assigned relevance score in `[0.0, 1.0]`. LLM is prompted to return tags sorted by score desc. Legacy `[String]` records on disk auto-migrate via `decodeTags` with a descending pseudo-score ladder (1.0, 0.75, 0.5, 0.25, 0.0) |

## Anti-glossary (terms that exist but should NOT be used)

| Term | Why not |
|---|---|
| `RecordingViewModel` | Doesn't exist. Use `TranscriptionViewModel` |
| `BookmarkStore` | From the other app. **Not in audionote** — don't port the name |
| `pipeline` | Used informally. The actual pipeline is `assessAndEnhance`; say that |

## When to update this file

- New public type (struct/class/enum) that survives across features
- New `UserDefaults` key
- Any rename of an existing entry above

## When NOT to update

- Internal helpers
- View-private types
- Test fixtures
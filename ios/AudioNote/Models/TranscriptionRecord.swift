import Foundation

enum RecognitionMode: String, Codable {
    case online
    case onDevice
    case enhanced
    case failed
}

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
    var optimizedContent: String? // Original content before LLM optimization
    var recognitionMode: RecognitionMode?

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
        llmProcessingStatus: LLMStatus? = nil,
        optimizedContent: String? = nil,
        recognitionMode: RecognitionMode? = nil
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
        self.optimizedContent = optimizedContent
        self.recognitionMode = recognitionMode
    }

    var formattedDuration: String {
        guard let duration = duration, duration > 0 else { return "" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var preview: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "(无内容)"
        }
        let maxLength = 50
        if trimmed.count <= maxLength {
            return trimmed
        }
        return String(trimmed.prefix(maxLength)) + "..."
    }

    var displayLanguage: String {
        guard let language = language else { return "" }
        switch language {
        case "zh-CN": return "中文"
        case "en-US": return "English"
        default: return language
        }
    }
}

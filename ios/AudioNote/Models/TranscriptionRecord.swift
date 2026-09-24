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

/// A tag with a relevance score produced by the LLM. `score` is in `[0.0, 1.0]`,
/// higher means more relevant to the underlying transcription. The LLM is
/// instructed to return tags sorted by score descending.
struct TaggedItem: Codable, Hashable, Equatable {
    let name: String
    let score: Double
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
    var tags: [TaggedItem]?
    var llmProcessingStatus: LLMStatus?
    var optimizedContent: String? // Original content before LLM optimization
    var recognitionMode: RecognitionMode?

    // Archive fields
    var archived: Bool = false
    var archivedAt: Date? = nil

    init(
        id: UUID = UUID(),
        content: String,
        createdAt: Date = Date(),
        duration: TimeInterval? = nil,
        language: String? = nil,
        audioFileName: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        tags: [TaggedItem]? = nil,
        llmProcessingStatus: LLMStatus? = nil,
        optimizedContent: String? = nil,
        recognitionMode: RecognitionMode? = nil,
        archived: Bool = false,
        archivedAt: Date? = nil
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
        self.archived = archived
        self.archivedAt = archivedAt
    }

    // MARK: - Codable

    /// Custom decoder so optional / defaulted fields survive when the on-disk
    /// JSON was written by an older build that didn't carry them. Swift's
    /// auto-synthesized `init(from:)` requires every key to be present, so we
    /// use `decodeIfPresent` everywhere a missing value should fall back to
    /// the property's declared default.
    ///
    /// Also handles the legacy `tags` shape (`[String]`) by mapping it onto
    /// `[TaggedItem]` with descending pseudo-scores (1.0, 0.75, 0.5, 0.25,
    /// 0.0) so existing tag display order is preserved after upgrade.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.content = try c.decode(String.self, forKey: .content)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        self.language = try c.decodeIfPresent(String.self, forKey: .language)
        self.audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.tags = try Self.decodeTags(container: c)
        self.llmProcessingStatus = try c.decodeIfPresent(LLMStatus.self, forKey: .llmProcessingStatus)
        self.optimizedContent = try c.decodeIfPresent(String.self, forKey: .optimizedContent)
        self.recognitionMode = try c.decodeIfPresent(RecognitionMode.self, forKey: .recognitionMode)
        self.archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        self.archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    /// Accepts either `[TaggedItem]` (current) or `[String]` (legacy) on disk.
    /// Legacy strings get sequential descending pseudo-scores so the visual
    /// order from before the upgrade is roughly preserved.
    ///
    /// `decodeIfPresent` returns nil only for *missing* keys — a present-but-
    /// wrong-type value throws. So we guard with `contains(.tags)` and then
    /// use `try?` on each shape attempt to fall through cleanly.
    private static func decodeTags(container: KeyedDecodingContainer<CodingKeys>) throws -> [TaggedItem]? {
        guard container.contains(.tags) else { return nil }
        if let items = try? container.decode([TaggedItem].self, forKey: .tags) {
            return items
        }
        if let legacy = try? container.decode([String].self, forKey: .tags) {
            let ladder: [Double] = [1.0, 0.75, 0.5, 0.25, 0.0]
            return legacy.enumerated().map { idx, name in
                TaggedItem(name: name, score: ladder[min(idx, ladder.count - 1)])
            }
        }
        // Key present but neither shape decodable — treat as no tags rather
        // than blowing up the whole records file.
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, createdAt, duration, language, audioFileName
        case title, summary, tags, llmProcessingStatus, optimizedContent, recognitionMode
        case archived, archivedAt
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

    /// Just the tag names, in the order the LLM returned them (descending score).
    /// Use this for any string-based matching or display where the score is irrelevant.
    var tagNames: [String] {
        tags?.map(\.name) ?? []
    }

    /// Highest score across the record's tags, or `nil` when there are no tags.
    var maxTagScore: Double? {
        tags?.map(\.score).max()
    }
}

extension TranscriptionRecord {
    /// Look up the score for a tag name on this record (case-insensitive).
    /// Returns `nil` if the tag isn't present.
    func score(forTagName name: String) -> Double? {
        guard let tags = tags else { return nil }
        let needle = name.lowercased()
        return tags.first { $0.name.lowercased() == needle }?.score
    }
}

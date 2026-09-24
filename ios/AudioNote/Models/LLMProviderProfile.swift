import Foundation

/// User-managed LLM provider configuration. Each profile points at one
/// OpenAI-compatible `/chat/completions` endpoint. The API key (if any)
/// lives in the Keychain under `service = "audioNote.llm"`,
/// `account = profile.id.uuidString` — never in UserDefaults.
///
/// See `docs/superpowers/specs/2026-09-24-multi-provider-llm-design.md`
/// and `docs/decisions/0003-multi-provider-llm.md`.
struct LLMProviderProfile: Codable, Identifiable, Hashable {
    /// Stable identifier. Doubles as the Keychain account name.
    let id: UUID

    /// Human-friendly label shown in Settings — e.g. "My DeepSeek",
    /// "Local Ollama". Falls back to `baseURL.host` when empty.
    var displayName: String

    /// Full OpenAI-compatible chat completions URL. Examples:
    /// - `https://api.openai.com/v1/chat/completions`
    /// - `https://api.deepseek.com/v1/chat/completions`
    /// - `http://localhost:11434/v1/chat/completions` (Ollama)
    /// - `http://localhost:1234/v1/chat/completions` (LM Studio)
    var baseURL: URL

    /// Model name passed straight to the provider as `model`.
    /// e.g. `gpt-4o-mini`, `deepseek-chat`, `qwen2.5:7b`.
    var model: String

    /// When true, `LLMService` attaches `Authorization: Bearer <apiKey>`.
    /// Set to false for unauthenticated local servers (Ollama, LM Studio).
    var requiresAPIKey: Bool

    /// Set when the profile was created. Used only for UI sort order.
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        baseURL: URL,
        model: String,
        requiresAPIKey: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.requiresAPIKey = requiresAPIKey
        self.createdAt = createdAt
    }

    /// Fallback when `displayName` is blank. Used by `ProviderProfileStore` and
    /// the Settings list when no display name is set.
    var effectiveDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return baseURL.host ?? baseURL.absoluteString
    }

    // MARK: - Validation

    /// `true` when the profile has the minimum fields required to attempt
    /// a call. `requiresAPIKey` is checked separately by the caller because
    /// the API key is stored outside the profile.
    var isComplete: Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.absoluteString.isEmpty
    }

    /// Lightweight sanity check the Settings form runs before saving.
    /// Returns nil if everything looks fine; otherwise an enum case the
    /// caller maps to a localized message via `.localized`.
    func validate() -> LLMProfileValidationError? {
        if displayName.count > 40 {
            return .displayNameTooLong
        }
        guard let scheme = baseURL.scheme?.lowercased() else {
            return .missingScheme
        }
        guard scheme == "https" || scheme == "http" else {
            return .unsupportedScheme
        }
        if scheme == "http" {
            let host = baseURL.host?.lowercased() ?? ""
            let isLocal = host == "localhost" || host == "127.0.0.1" || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.16.") || host == "[::1]"
            if !isLocal {
                return .plainHttpNotLocal
            }
        }
        // Reject URLs that don't end in `/chat/completions`. Without the
        // path, the server typically 301s to its docs page and iOS won't
        // follow a POST redirect into an HTML response — surfacing as a
        // confusing "App Transport Security" error.
        let path = baseURL.path.lowercased()
        if !path.hasSuffix("/chat/completions") {
            return .missingChatCompletionsPath
        }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingModel
        }
        return nil
    }
}

/// Validation outcomes for `LLMProviderProfile.validate()`. Mapped to
/// localized strings at the call site so the model file stays free of
/// UI strings.
enum LLMProfileValidationError {
    case displayNameTooLong
    case missingScheme
    case unsupportedScheme
    case plainHttpNotLocal
    case missingChatCompletionsPath
    case missingModel

    var localizedMessage: String {
        switch self {
        case .displayNameTooLong:
            return "Settings.LLM.Profile.Error.DisplayNameTooLong".localized
        case .missingScheme:
            return "Settings.LLM.Profile.Error.MissingScheme".localized
        case .unsupportedScheme:
            return "Settings.LLM.Profile.Error.UnsupportedScheme".localized
        case .plainHttpNotLocal:
            return "Settings.LLM.Profile.Error.PlainHttpNotLocal".localized
        case .missingChatCompletionsPath:
            return "Settings.LLM.Profile.Error.MustEndInChatCompletions".localized
        case .missingModel:
            return "Settings.LLM.Profile.Error.MissingModel".localized
        }
    }
}

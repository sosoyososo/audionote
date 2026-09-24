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

    /// Lightweight sanity check the Settings form runs before saving. Returns
    /// nil if everything looks fine, otherwise a user-readable reason.
    func validate() -> String? {
        if displayName.count > 40 {
            return "Display name must be 40 characters or fewer."
        }
        guard let scheme = baseURL.scheme?.lowercased() else {
            return "Base URL must include a scheme (https:// or http://)."
        }
        guard scheme == "https" || scheme == "http" else {
            return "Base URL scheme must be http or https."
        }
        if scheme == "http" {
            let host = baseURL.host?.lowercased() ?? ""
            let isLocal = host == "localhost" || host == "127.0.0.1" || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.16.") || host == "[::1]"
            if !isLocal {
                return "Plain http is only allowed for localhost or LAN addresses."
            }
        }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Model name is required."
        }
        return nil
    }
}

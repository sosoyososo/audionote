import Foundation

/// Errors surfaced from `LLMService`. The set is intentionally small and
/// user-readable; detail lives in `errorDescription` for the Settings toast
/// and the `TranscriptionViewModel.errorMessage` path.
///
/// See `docs/superpowers/specs/2026-09-24-multi-provider-llm-design.md`
/// and `docs/decisions/0003-multi-provider-llm.md`.
enum LLMError: Error, LocalizedError {
    case profileIncomplete
    case apiKeyRequired
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError
    case offline
    case networkError(Error)
    /// Surfaces a concrete reason for `LLMService.ping` failures. Wraps HTTP
    /// status code, body excerpt, or transport-level message.
    case testConnectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .profileIncomplete:
            return "Provider profile is incomplete (check base URL and model)."
        case .apiKeyRequired:
            return "API Key is required for this provider."
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError:
            return "Failed to decode response"
        case .offline:
            return "No network connection"
        case .networkError(let error):
            return error.localizedDescription
        case .testConnectionFailed(let reason):
            return reason
        }
    }
}

/// The on-the-wire schema the LLM is asked to return from
/// `optimizeAndProcess`. **Locked by ADR-0002 and ADR-0003** — adding or
/// renaming a field is a breaking change for both this struct and the
/// `TranscriptionRecord` consumer downstream.
struct LLMOptimizeAndProcessResult: Decodable {
    let optimizedText: String
    let title: String
    let summary: String
    let tags: [TaggedItem]
}

/// Single LLM service. Talks to whichever `LLMProviderProfile` the caller
/// passes in — no global state, no defaults. The caller is responsible for
/// reading the active profile from `ProviderProfileStore` and the API key
/// from Keychain.
///
/// Three public methods:
/// - `optimizeAndProcess(_:profile:apiKey:)` — the merged text-cleanup +
///   title/summary/tags extraction used after a successful recording. **The**
///   only path that produces a `TranscriptionRecord` enrichment. Has retry.
/// - `ping(profile:apiKey:)` — a one-shot "does this profile work?" check
///   used by the Settings "测试连接" button. No JSON parsing, no retry.
///
/// Both methods run the same 3 gates (profile completeness, network,
/// HTTP 2xx). Both retry transient failures (5xx + network error), 3x
/// exponential backoff, 4xx/`.offline`/`.apiKeyRequired`/`.profileIncomplete`
/// are NOT retried.
actor LLMService {
    private let maxRetries = 3
    private let baseDelay: TimeInterval = 1.0

    // MARK: - Wire types (kept private to this file)

    private struct APIRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool = false

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct APIResponse: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let message: Message

            struct Message: Decodable {
                let content: String
            }
        }
    }

    // MARK: - Prompts (locked, NOT user-configurable — see ADR-0003)

    /// Used by the merged `optimizeAndProcess` entry point. Kept here (not
    /// inlined) so a future code review can see the full system prompt
    /// without grepping through call sites.
    private static let optimizeAndProcessPrompt = """
    你是一个语音转录文本优化助手和笔记组织助手。原始文本由 iOS Speech SDK 生成，可能存在以下问题：

    - 标点缺失或错误
    - 同音/近音词错误（例如 "语音" → "200题"、"摘要" → "简要"、"转录" → "转入"、"会议" → "回议"）
    - 重复词、无意义语气词（"嗯"、"那个"、"然后那个"等）

    请完成以下任务：

    1. 优化转录文本：
       - 修正明显的标点和同音词错误，根据上下文推断正确用词
       - 不要翻译，保留原始语言（中文录音保持中文）
       - 不要过度修改用户措辞；不确定的内容保留原文
       - 保留原始语义和口语化风格
    2. 为笔记提取标题（简短明了，8-20 字）
    3. 生成 50-100 字摘要
    4. 提取 3-5 个标签，每个标签附带 0.0-1.0 相关性分数（1.0=高度相关，0.0=边缘相关），按分数从高到低排序

    请严格按照以下 JSON 格式返回，不要添加任何解释或 markdown 标记：
    {"optimizedText": "...", "title": "...", "summary": "...", "tags": [{"name": "...", "score": 0.0}, ...]}
    """

    private static let pingPrompt = "ping"

    // MARK: - Public API

    /// Optimize and organize a transcription in one round-trip. Returns the
    /// 4-field schema consumed by `TranscriptionViewModel` / detail view.
    /// Retries transient failures.
    func optimizeAndProcess(
        _ text: String,
        profile: LLMProviderProfile,
        apiKey: String?
    ) async throws -> LLMOptimizeAndProcessResult {
        try validateProfile(profile, apiKey: apiKey)

        return try await retryingRequest(
            profile: profile,
            apiKey: apiKey,
            buildRequest: {
                APIRequest(
                    model: profile.model,
                    messages: [
                        APIRequest.Message(role: "system", content: Self.optimizeAndProcessPrompt),
                        APIRequest.Message(role: "user", content: text),
                    ]
                )
            },
            sendAndParse: { urlRequest, profile in
                let content = try await self.sendAndExtractContent(urlRequest: urlRequest, profile: profile)
                return try Self.parseOptimizeAndProcess(content: content)
            }
        )
    }

    /// Lightweight "is this profile reachable + authorized?" check. Sends a
    /// minimal user message; does NOT parse JSON; does NOT retry.
    ///
    /// Return semantics:
    /// - Success: returns normally (caller shows ✓).
    /// - Failure: throws `LLMError.testConnectionFailed("<reason>")`. The
    ///   reason is short and user-readable — the caller can show it verbatim
    ///   in the Settings toast.
    func ping(profile: LLMProviderProfile, apiKey: String?) async throws {
        try validateProfile(profile, apiKey: apiKey)

        let request = APIRequest(
            model: profile.model,
            messages: [
                APIRequest.Message(role: "user", content: Self.pingPrompt),
            ]
        )

        let urlRequest = try buildURLRequest(
            profile: profile,
            apiKey: apiKey,
            body: try JSONEncoder().encode(request)
        )

        do {
            let (_, response) = try await URLSession.shared.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.invalidResponse
            }
            if !(200...299).contains(httpResponse.statusCode) {
                throw LLMError.testConnectionFailed("HTTP \(httpResponse.statusCode)")
            }
        } catch let error as LLMError {
            throw LLMError.testConnectionFailed(error.errorDescription ?? "Unknown error")
        } catch {
            throw LLMError.testConnectionFailed(error.localizedDescription)
        }
    }

    // MARK: - Validation (gate #1)

    private func validateProfile(_ profile: LLMProviderProfile, apiKey: String?) throws {
        guard profile.isComplete else {
            Logger.warning("LLM call skipped: profile incomplete")
            throw LLMError.profileIncomplete
        }
        if profile.requiresAPIKey {
            let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                Logger.warning("LLM call skipped: API key required but not set")
                throw LLMError.apiKeyRequired
            }
        }
    }

    // MARK: - HTTP build

    private func buildURLRequest(
        profile: LLMProviderProfile,
        apiKey: String?,
        body: Data
    ) throws -> URLRequest {
        var request = URLRequest(url: profile.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if profile.requiresAPIKey, let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        if let bodyString = String(data: body, encoding: .utf8) {
            Logger.debug("LLM request body: \(bodyString)")
        }
        return request
    }

    // MARK: - Send + parse (gates #2 + #3)

    /// Sends the request, checks network + HTTP status, decodes the
    /// OpenAI-compatible envelope, returns the first `content` string.
    /// Throws on network errors / non-2xx / envelope shape failures.
    private func sendAndExtractContent(
        urlRequest: URLRequest,
        profile: LLMProviderProfile
    ) async throws -> String {
        // Gate #2 — network
        guard NetworkMonitor.shared.checkConnectivity() else {
            Logger.warning("LLM call skipped: device is offline")
            throw LLMError.offline
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            Logger.error("LLM transport error: \(error.localizedDescription)")
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        // Gate #3 — HTTP status
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "unable to decode response body"
            Logger.error("LLM API error: HTTP \(httpResponse.statusCode), body: \(responseBody)")
            throw LLMError.httpError(httpResponse.statusCode)
        }

        let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
        guard let content = apiResponse.choices.first?.message.content else {
            throw LLMError.invalidResponse
        }
        _ = profile // (currently unused — kept for future per-profile hooks)
        return content
    }

    // MARK: - Retry loop

    /// Drives `send` with up to `maxRetries` attempts. Only retries transient
    /// failures (HTTP 5xx, transport-level `.networkError`); 4xx and all
    /// "user-fixable" errors (`.profileIncomplete`, `.apiKeyRequired`,
    /// `.offline`, `.invalidResponse`) bubble up immediately.
    ///
    /// `buildRequest` is invoked once per attempt so the body is freshly
    /// encoded — gives future callers a hook for prompt variations without
    /// having to re-derive the APIRequest shape themselves.
    private func retryingRequest<T>(
        profile: LLMProviderProfile,
        apiKey: String?,
        buildRequest: () throws -> APIRequest,
        sendAndParse: (URLRequest, LLMProviderProfile) async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            let urlRequest: URLRequest
            do {
                let body = try JSONEncoder().encode(buildRequest())
                urlRequest = try buildURLRequest(profile: profile, apiKey: apiKey, body: body)
            } catch {
                throw error
            }

            do {
                let value = try await sendAndParse(urlRequest, profile)
                if attempt > 0 {
                    Logger.info("LLM call succeeded on attempt \(attempt + 1)")
                }
                return value
            } catch let error as LLMError {
                lastError = error
                let shouldRetry = Self.shouldRetry(error)
                Logger.warning("LLM call failed (attempt \(attempt + 1)/\(maxRetries)): \(error.errorDescription ?? "unknown")")

                if !shouldRetry {
                    throw error
                }
                if attempt < maxRetries - 1 {
                    let delay = baseDelay * pow(2.0, Double(attempt))
                    Logger.info("Retrying in \(delay)s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                lastError = error
                Logger.warning("LLM call failed (attempt \(attempt + 1)/\(maxRetries)): \(error.localizedDescription)")
                if attempt < maxRetries - 1 {
                    let delay = baseDelay * pow(2.0, Double(attempt))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw lastError ?? LLMError.networkError(NSError(domain: "LLMService", code: -1))
    }

    private static func shouldRetry(_ error: LLMError) -> Bool {
        switch error {
        case .httpError(let code) where (500...599).contains(code):
            return true
        case .networkError:
            return true
        default:
            return false
        }
    }

    // MARK: - JSON parsing + extraction fallback

    /// Parses the 4-field schema out of `content`. Tries direct decode first,
    /// then falls back to balanced-brace extraction so that local models
    /// which wrap JSON in markdown fences or surrounding prose still work.
    static func parseOptimizeAndProcess(content: String) throws -> LLMOptimizeAndProcessResult {
        if let directData = content.data(using: .utf8),
           let direct = try? JSONDecoder().decode(LLMOptimizeAndProcessResult.self, from: directData) {
            return direct
        }

        Logger.warning("LLM optimizeAndProcess: direct JSON decode failed; attempting extraction. Raw (first 500 chars): \(String(content.prefix(500)))")

        if let extracted = extractFirstJSONObject(from: content),
           let extractedData = extracted.data(using: .utf8),
           let extractedResult = try? JSONDecoder().decode(LLMOptimizeAndProcessResult.self, from: extractedData) {
            Logger.info("LLM optimizeAndProcess: extraction succeeded")
            return extractedResult
        }

        Logger.error("LLM optimizeAndProcess: extraction failed. Full content: \(content)")
        throw LLMError.decodingError
    }

    /// Find the first balanced top-level `{...}` substring in `text`,
    /// respecting JSON string boundaries (quotes and backslash escapes).
    /// Returns nil if no balanced object exists.
    private static func extractFirstJSONObject(from text: String) -> String? {
        guard let firstBrace = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escapeNext = false
        var lastBraceIndex: String.Index?

        var idx = firstBrace
        while idx < text.endIndex {
            let c = text[idx]
            if escapeNext {
                escapeNext = false
            } else if c == "\\" {
                escapeNext = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        lastBraceIndex = idx
                        break
                    }
                }
            }
            idx = text.index(after: idx)
        }

        guard let end = lastBraceIndex else { return nil }
        return String(text[firstBrace...end])
    }
}

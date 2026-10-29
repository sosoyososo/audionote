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

/// One candidate offered to the model by the `findRelated` call. Encodable
/// but not actually put on the wire as JSON — it is rendered into the
/// candidate block of `findRelatedPrompt` — so the conformance is there for
/// callers (and future prompts) that want to send the list structurally.
struct RelatedNoteCandidate: Encodable {
    let id: UUID
    let title: String
    let summary: String
}

/// One "this candidate is related to the current note" verdict from the model.
/// `score` is the model's own 0.0-1.0 rating, independent of how the candidate
/// was prescreened — the two numbers are not comparable (see spec §3).
struct RelatedNoteMatch: Decodable {
    let id: UUID
    let score: Double
}

/// Envelope of the `findRelated` response.
///
/// Decoded through `JSONSerialization` rather than `JSONDecoder`, **on
/// purpose**. A standard array decode is all-or-nothing, so a model that
/// returns three good pairs plus one truncated uuid would throw all four
/// away — and the reply is adversarial input, where that shape is ordinary.
/// `JSONSerialization` hands the array back as plain values, so each element
/// can be judged on its own and only the unreadable ones dropped. A `Decodable`
/// rewrite is not the answer: its cursor cannot *skip* an element it fails to
/// decode, so a lenient `try?` loop silently swallows everything after it.
///
/// The envelope itself is still all-or-nothing: `nil` means "not a reply we
/// can read at all", which is what sends `parseRelated` on to the
/// balanced-brace extraction and then to `decodingError`.
private enum RelatedPayload {

    /// Returns nil only when the envelope is unusable. A `related` key that
    /// is simply absent yields `[]` — a model answering `{}` means "nothing
    /// related", not "malformed".
    static func parse(_ data: Data) -> [RelatedNoteMatch]? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let raw = envelope["related"] else { return [] }
        guard let elements = raw as? [Any] else { return nil }
        return elements.compactMap(element)
    }

    /// **The strictness boundary. An element survives only if `id` is a JSON
    /// string that parses as a `UUID` *and* `score` is a JSON number.**
    /// Everything else is dropped, explicitly including the near-misses a
    /// lenient reader might rescue — a truncated uuid (`"id": "1111-11"`,
    /// the most common model slip), a score as a JSON *string* (`"0.9"`), a
    /// missing `id`, a missing `score`, and a non-object element.
    private static func element(_ raw: Any) -> RelatedNoteMatch? {
        guard let fields = raw as? [String: Any],
              let id = fields["id"] as? String,
              let uuid = UUID(uuidString: id)
        else { return nil }
        guard let score = jsonNumber(fields["score"]) else { return nil }
        return RelatedNoteMatch(id: uuid, score: score)
    }

    /// `JSONSerialization` has no boolean type — `true` and `false` arrive as
    /// `__NSCFBoolean`, an `NSNumber` subclass, and `as? Double` succeeds on
    /// it. A bare `as? Double` would therefore read `"score": true` as a
    /// perfect `1.0`: a maximal relevance claim the model never made, which
    /// then tops the display list and persists. Check the CF type first.
    ///
    /// This covers the boolean case only, not a general range check — an
    /// out-of-range number (`85`, `1e300`) still passes, as it did before
    /// the switch to `JSONSerialization`. That gap is known and tracked
    /// separately; do not read this guard as a strictness guarantee.
    private static func jsonNumber(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return value as? Double
    }
}

/// The `proposeTagMerges` response.
///
/// Every field is checked against the library: the target must be a tag the
/// library has (a merge does not create vocabulary), and the sources must be
/// tags the library has (the model does not get to invent them). Names are
/// compared by **identity**, so a proposal that lists `Work` and `work` as
/// two tags is one tag, not two — the same rule the chips and the filters
/// use.
private enum TagMergePayload {

    /// Returns nil only when the envelope is unusable. A `merges` key that
    /// is simply absent yields `[]` — a model answering `{}` means "nothing
    /// to merge", not "malformed".
    static func parse(_ data: Data, knownCounts: [String: Int]) -> [TagMergeProposal]? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let raw = envelope["merges"] else { return [] }
        guard let elements = raw as? [Any] else { return nil }
        return elements.compactMap { element($0, knownCounts: knownCounts) }
    }

    private static func element(_ raw: Any, knownCounts: [String: Int]) -> TagMergeProposal? {
        guard let fields = raw as? [String: Any],
              let rawTarget = fields["target"] as? String
        else { return nil }

        let target = TagIdentity.normalized(rawTarget)
        guard !target.isEmpty else { return nil }

        // The counts are keyed by identity: the library's spelling for a
        // tag may differ from the one the model wrote, and the number of
        // notes carrying it does not.
        var countByKey: [String: Int] = [:]
        for (name, count) in knownCounts {
            countByKey[TagIdentity.key(name), default: 0] += count
        }

        guard countByKey[TagIdentity.key(target)] != nil else { return nil }

        guard let rawSources = fields["sources"] as? [Any] else { return nil }

        var seen = Set([TagIdentity.key(target)])
        var sources: [String] = []
        var counts: [String: Int] = [:]

        for raw in rawSources {
            guard let rawName = raw as? String else { continue }
            let spelling = TagIdentity.normalized(rawName)
            guard !spelling.isEmpty else { continue }
            let key = TagIdentity.key(spelling)
            guard let count = countByKey[key] else { continue }  // 不在库里 ✓
            guard seen.insert(key).inserted else { continue }      // 同一个标签不重复 ✓
            sources.append(spelling)
            counts[spelling] = count
        }

        // One source is not a merge.
        guard sources.count >= 1 else { return nil }
        return TagMergeProposal(target: target, sources: sources, counts: counts)
    }
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
        var stream: Bool = false

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
    ///
    /// Parameterized by the library's existing tags — see
    /// `existingTagVocabulary`. The rules themselves are unconditional: two
    /// notes from the same user should agree on whether `Work` is `Work` or
    /// `work`, and a leading space should never survive. The vocabulary block
    /// is the part that only pays off once a library exists.
    ///
    /// Internal rather than private so a test can pin it — the same reason
    /// `findRelatedPrompt` is. ADR-0003 freezes the wording from being
    /// user-configurable; it does not freeze it from being asserted.
    static func optimizeAndProcessPrompt(existingTagVocabulary: [String]) -> String {
        var prompt = """
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

        标签必须严格遵守：
        - 不要首尾空格，标签两端干净
        - 中文标签保持原样，不要翻译
        - 英文标签一律用小写（如 "Work"、"WORK"、"work" 统一写成 "work"）
        - 同一主题在整个文库中使用同一个写法，不要因为换一条笔记就换个说法
        """

        // Only present when the library already has tags. On a cold library the
        // prompt is byte-identical to one without vocabulary, so there is no
        // token cost and no behavior change for a first note.
        if !existingTagVocabulary.isEmpty {
            prompt += """

            【已有标签】
            \(existingTagVocabulary.joined(separator: "、"))

            提取标签时：如果上面已有能准确概括本条的标签，直接复用它的写法；
            只有在确实没有合适的已有标签时，才新造一个新标签。
            不要为了凑数给本条贴上不相关的已有标签。
            """
        }

        prompt += """

        请严格按照以下 JSON 格式返回，不要添加任何解释或 markdown 标记：
        {"optimizedText": "...", "title": "...", "summary": "...", "tags": [{"name": "...", "score": 0.0}, ...]}
        """
        return prompt
    }

    /// How many existing tags are worth showing the model. The list competes
    /// for the model's attention with the transcription itself, so it stays
    /// short and ordered by how much of the library actually uses each tag —
    /// the head of the distribution is where reuse pays off.
    static let maxTagVocabulary = 30

    /// Internal rather than private so a test can pin the interpolated
    /// prompt against this exact text. ADR-0003 freezes the wording, not the
    /// access level.
    static let findRelatedPrompt = """
    你是一个笔记关联助手。下面是一条笔记，以及候选笔记的列表。

    【当前笔记】
    标题：{title}
    摘要：{summary}

    【候选笔记】
    {candidates}

    请选出与【当前笔记】在主题或内容上真正相关的候选，最多 5 条，不足则少给。
    只返回你确实认为相关的；如果没有任何一条相关，返回空数组。
    不要返回格式错误的 id，不要编造候选列表中不存在的 id。
    id 字段必须是上面给定的完整 uuid 字符串。
    score 是这一对笔记的相关程度，0.0-1.0，与候选列表的规模无关：
    即使只有一条候选也要如实给分。

    严格返回 JSON，不要任何解释或 markdown 标记：
    {"related": [{"id": "<uuid>", "score": 0.85}]}
    """

    /// The three placeholders, in the order they appear in `findRelatedPrompt`.
    private static let findRelatedPlaceholders = ["{title}", "{summary}", "{candidates}"]

    /// `findRelatedPrompt` already cut at its three placeholders, so
    /// interpolation is one forward join over `findRelatedPlaceholders.count`
    /// literal segments.
    ///
    /// This is the whole point of splitting once, at load time. Chained
    /// `replacingOccurrences(of:with:)` passes each re-scan the *output* of the
    /// previous one, so a note title that literally reads `{candidates}` would
    /// be picked up by a later pass and land in the candidate slot — the
    /// candidate block displaced, the title position showing the whole list.
    /// The input is model-generated, so the probability is low, not zero.
    /// Here a field is copied in verbatim and never rescanned.
    ///
    /// Invariant: 4 parts, because each placeholder occurs exactly once and in
    /// `findRelatedPlaceholders` order. `makeSystemPrompt` falls back to the
    /// un-interpolated prompt if that ever stops holding, and a test pins it.
    private static let findRelatedPromptParts: [String] = {
        var parts: [String] = []
        var remainder = Substring(findRelatedPrompt)
        for placeholder in findRelatedPlaceholders {
            guard let range = remainder.range(of: placeholder) else {
                parts.append(String(remainder))
                return parts
            }
            parts.append(String(remainder[..<range.lowerBound]))
            remainder = remainder[range.upperBound...]
        }
        parts.append(String(remainder))
        return parts
    }()

    private static let pingPrompt = "ping"

    /// Builds the `findRelated` system prompt. Extracted from `findRelated` so
    /// the network-free half of that call is testable without a stub server.
    ///
    /// The candidate block is one line per candidate: `<uuid>. 标题：… 摘要：…`
    /// Filtering the model's *reply* is `RelatedNotesService.sanitize`'s job;
    /// this is only the outbound text.
    ///
    /// NOTE: the prose above says `最多 5 条`. That is a model instruction and
    /// is deliberately a literal, but it must stay in sync with
    /// `RelatedNotesService.maxRelated` — the cap the reply is trimmed to.
    static func makeSystemPrompt(
        currentTitle: String,
        currentSummary: String,
        candidates: [RelatedNoteCandidate]
    ) -> String {
        let candidateBlock = candidates
            .map { "\($0.id.uuidString). 标题：\($0.title) 摘要：\($0.summary)" }
            .joined(separator: "\n")

        let fields = [currentTitle, currentSummary, candidateBlock]
        let parts = findRelatedPromptParts
        guard parts.count == fields.count + 1 else {
            // Template and placeholders drifted apart. Shipping the literal
            // prompt beats shipping a prompt with an empty title slot.
            Logger.error("LLM findRelated: prompt template invariant broken (\(parts.count) parts)")
            return findRelatedPrompt
        }

        var prompt = parts[0]
        for (index, part) in parts.dropFirst().enumerated() {
            prompt += fields[index] + part
        }
        return prompt
    }

    // MARK: - Public API

    /// Optimize and organize a transcription in one round-trip. Returns the
    /// 4-field schema consumed by `TranscriptionViewModel` / detail view.
    /// Retries transient failures.
    /// `existingTags` is the library's tag vocabulary (see
    /// `TranscriptionViewModel.existingTagVocabulary`), already trimmed,
    /// deduped and capped by the caller. Pass `[]` for a cold library.
    func optimizeAndProcess(
        _ text: String,
        profile: LLMProviderProfile,
        apiKey: String?,
        existingTags: [String] = []
    ) async throws -> LLMOptimizeAndProcessResult {
        try validateProfile(profile, apiKey: apiKey)

        let result = try await retryingRequest(
            profile: profile,
            apiKey: apiKey,
            buildRequest: {
                APIRequest(
                    model: profile.model,
                    messages: [
                        APIRequest.Message(
                            role: "system",
                            content: Self.optimizeAndProcessPrompt(
                                existingTagVocabulary: existingTags
                            )
                        ),
                        APIRequest.Message(role: "user", content: text),
                    ]
                )
            },
            sendAndParse: { urlRequest, profile in
                let content = try await self.sendAndExtractContent(urlRequest: urlRequest, profile: profile)
                return try Self.parseOptimizeAndProcess(content: content)
            }
        )
        Self.logVocabularyUsage(offered: existingTags, returned: result.tags)
        return result
    }

    /// How much of the vocabulary the model actually used.
    ///
    /// The number that matters: of the tags the model returned, how many were
    /// offered to it in the first place. A low value means the vocabulary is
    /// not reaching this note's topic, so the model invents tags the library
    /// already has — which is how 43 notes ended up carrying 158 tags.
    ///
    /// Tag names and counts only. Never the transcript, never the key.
    private static func logVocabularyUsage(offered: [String], returned: [TaggedItem]) {
        let offeredKeys = Set(offered.map(TagIdentity.key))
        let reused = returned.filter { offeredKeys.contains(TagIdentity.key($0.name)) }.count
        let names = returned.map(\.name).joined(separator: ",")
        Logger.info("tag vocabulary: offered=\(offered.count) returned=\(returned.count) reused=\(reused) tags=\(names)")
    }

    /// Second, independent LLM call: which of the given candidates are
    /// actually related to the current note. Kept separate from
    /// `optimizeAndProcess` because that call's user message is the raw
    /// transcript and its prompt asks the model to rewrite it — injecting
    /// 20 other notes' summaries into the same message invites the model to
    /// import them into the "optimized" output (spec §4.2).
    ///
    /// Runs the same three gates and the same retry policy as
    /// `optimizeAndProcess`. The returned ids are unvalidated: the caller
    /// must intersect them with the candidate set before persisting, which
    /// is what `RelatedNotesService.sanitize` does.
    func findRelated(
        currentTitle: String,
        currentSummary: String,
        candidates: [RelatedNoteCandidate],
        profile: LLMProviderProfile,
        apiKey: String?
    ) async throws -> [RelatedNoteMatch] {
        try validateProfile(profile, apiKey: apiKey)

        let systemPrompt = Self.makeSystemPrompt(
            currentTitle: currentTitle,
            currentSummary: currentSummary,
            candidates: candidates
        )

        return try await retryingRequest(
            profile: profile,
            apiKey: apiKey,
            buildRequest: {
                APIRequest(
                    model: profile.model,
                    messages: [
                        APIRequest.Message(role: "system", content: systemPrompt),
                        APIRequest.Message(role: "user", content: "请找出相关笔记。"),
                    ]
                )
            },
            sendAndParse: { urlRequest, profile in
                let content = try await self.sendAndExtractContent(urlRequest: urlRequest, profile: profile)
                return try Self.parseRelated(content: content)
            }
        )
    }

    /// Ask the model which of the library's tags mean the same thing.
    ///
    /// A third, separate call: `optimizeAndProcess` extracts and organizes
    /// one note (ADR-0002 freezes its response schema), `findRelated` picks
    /// related notes, and this one *groups* the vocabulary. Three tasks in
    /// one prompt invite the model to answer the wrong question.
    ///
    /// The model proposes; the user disposes. Nothing is merged here — the
    /// caller turns the proposals into a list the user can prune before
    /// anything changes (ADR-0010).
    ///
    /// `tags` is the whole library's vocabulary with how many notes carry
    /// each tag. The counts are context the model needs: a tag on one note
    /// and a tag on forty are very different things to merge.
    func proposeTagMerges(
        tags: [(name: String, count: Int)],
        profile: LLMProviderProfile,
        apiKey: String?,
        onText: @escaping (String) -> Void = { _ in }
    ) async throws -> [TagMergeProposal] {
        try validateProfile(profile, apiKey: apiKey)
        guard !tags.isEmpty else { return [] }

        let knownCounts = Dictionary(uniqueKeysWithValues: tags.map { ($0.name, $0.count) })

        // The answer is a long generation, and a timeout is not a transient
        // failure: retrying it pays for the same slow answer twice. One
        // attempt, and a timeout long enough for it.
        let body = try JSONEncoder().encode(
            APIRequest(
                model: profile.model,
                messages: [
                    APIRequest.Message(
                        role: "system",
                        content: Self.tagMergePrompt(tags: tags)
                    ),
                        APIRequest.Message(role: "user", content: "请找出可以合并的标签。"),
                ],
                stream: true
            )
        )
        var request = try buildURLRequest(profile: profile, apiKey: apiKey, body: body)
        // This one bounds the wait for the *response headers*. The stream
        // itself is bounded by the session's resource timeout, so a long
        // generation does not hit a wall — it keeps arriving.
        request.timeoutInterval = 90

        // Gate #2 — network, same as every other call.
        guard NetworkMonitor.shared.checkConnectivity() else {
            Logger.warning("LLM call skipped: device is offline")
            throw LLMError.offline
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            Logger.error("LLM proposeTagMerges: HTTP \(http.statusCode)")
            throw LLMError.httpError(http.statusCode)
        }

        var content = ""
        for try await line in bytes.lines {
            guard let piece = Self.sseContent(in: line) else { continue }
            content += piece
            onText(content)
        }

        let head = content.prefix(300).replacingOccurrences(of: "\n", with: " ")
        Logger.info("LLM proposeTagMerges: streamed \(content.count) chars, head: \(head)")
        return try Self.parseTagMerges(content: content, knownCounts: knownCounts)
    }

    /// The content of one server-sent event, or nil for a line that carries
    /// none.
    ///
    /// The wire format is the OpenAI-compatible one: `data: {...}` lines,
    /// each carrying a chat-completion chunk whose `delta.content` is the
    /// piece that arrived. `[DONE]` ends the stream.
    static func sseContent(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty else { return nil }
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = event["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return nil }
        return content
    }

    /// The prompt for `proposeTagMerges`.
    ///
    /// Internal rather than private so a test can pin the wording against
    /// this exact text — ADR-0010 freezes it, the way ADR-0003 freezes the
    /// other two.
    static func tagMergePrompt(tags: [(name: String, count: Int)]) -> String {
        let list = tags
            .map { "\($0.name)（\($0.count) 条笔记）" }
            .joined(separator: "、")

        return """
        你是一个标签整理助手。下面是这个笔记库里的全部标签，以及每个标签出现在多少条笔记里。

        【标签列表】
        \(list)

        请找出**语义相同**、应该合并成一个的标签组：
        - 只合并真正同义的标签（同一个意思的不同写法），例如「工作项」和「工作会议」；
          **不要合并只是相关但不同的标签**，例如「会议」和「会议纪要」不是同一个意思。
        - 每组给出合并后的名字：用这一组里最常用、最准确的那个写法。
        - **合并后的名字必须出现在 2 条及以上笔记里** —— 没人用的词不适合当分类词。
          （要合并进去的来源标签可以只出现一次 ✓）
        - sources 里列出这一组里要合并进去的标签，不要包含 target 自己；一组最多列 4 个。
        - **最多给出 10 组**，挑最值得合并的那些；如果没有可以合并的标签，返回空数组。
        - 不要编造不在上面列表里的标签。

        严格返回 JSON，不要任何解释或 markdown 标记：
        {"merges": [{"target": "工作", "sources": ["工作项", "工作会议"]}]}
        """
    }

    /// Parse the model's reply into proposals.
    ///
    /// Tolerant on purpose: a malformed entry is dropped and the rest
    /// survive. The envelope itself is all-or-nothing — `nil` means "not a
    /// reply we can read at all", which sends this on to the balanced-brace
    /// extraction and then to `decodingError`.
    static func parseTagMerges(
        content: String,
        knownCounts: [String: Int]
    ) throws -> [TagMergeProposal] {
        if let directData = content.data(using: .utf8),
           let parsed = TagMergePayload.parse(directData, knownCounts: knownCounts) {
            return parsed
        }

        if let extracted = extractFirstJSONObject(from: content),
           let extractedData = extracted.data(using: .utf8),
           let parsed = TagMergePayload.parse(extractedData, knownCounts: knownCounts) {
            return parsed
        }

        Logger.error("LLM proposeTagMerges: could not parse content: \(content)")
        throw LLMError.decodingError
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
        timeout: TimeInterval = 60,
        maxAttempts: Int = 3,
        buildRequest: () throws -> APIRequest,
        sendAndParse: (URLRequest, LLMProviderProfile) async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            let urlRequest: URLRequest
            do {
                let body = try JSONEncoder().encode(buildRequest())
                var request = try buildURLRequest(profile: profile, apiKey: apiKey, body: body)
                request.timeoutInterval = timeout
                urlRequest = request
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
                Logger.warning("LLM call failed (attempt \(attempt + 1)/\(maxAttempts)): \(error.errorDescription ?? "unknown")")

                if !shouldRetry {
                    throw error
                }
                if attempt < maxAttempts - 1 {
                    let delay = baseDelay * pow(2.0, Double(attempt))
                    Logger.info("Retrying in \(delay)s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                lastError = error
                Logger.warning("LLM call failed (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
                if attempt < maxAttempts - 1 {
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

    /// Parse the `findRelated` response. Direct JSON first, then the same
    /// balanced-brace extraction used by `parseOptimizeAndProcess` (models in
    /// the M2.7 lineage wrap JSON in prose). An empty `related` array is a
    /// valid answer, not an error — "none of these are related" is a real
    /// outcome the caller must be able to persist as zero edges.
    ///
    /// Only the *envelope* is all-or-nothing. A malformed element inside a
    /// well-formed `related` array is dropped by `RelatedPayload` and the
    /// surviving elements are returned, so a reply carrying one truncated
    /// uuid still contributes the pairs that were complete.
    static func parseRelated(content: String) throws -> [RelatedNoteMatch] {
        if let directData = content.data(using: .utf8), let parsed = RelatedPayload.parse(directData) {
            return parsed
        }

        if let extracted = extractFirstJSONObject(from: content),
           let extractedData = extracted.data(using: .utf8),
           let parsed = RelatedPayload.parse(extractedData) {
            return parsed
        }

        Logger.error("LLM findRelated: could not parse content: \(content)")
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

// MARK: - Related notes

/// `link(for:)` is tested against a stub, so the one method it needs is
/// declared as a protocol. The actor-isolated original satisfies the async
/// requirement unchanged.
extension LLMService: RelatedNotesLLM {}

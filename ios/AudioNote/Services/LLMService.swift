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
            } catch let error as LLMError {
                lastError = error
                // Only retry on transient errors (HTTP 5xx and network errors)
                let shouldRetry: Bool
                switch error {
                case .httpError(let code) where (500...599).contains(code):
                    shouldRetry = true
                case .networkError:
                    shouldRetry = true
                default:
                    shouldRetry = false
                }

                if shouldRetry && attempt < maxRetries - 1 {
                    let delay = baseDelay * pow(2.0, Double(attempt))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else if !shouldRetry {
                    throw error
                }
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

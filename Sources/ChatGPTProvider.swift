import Foundation

/// Subscription-backed Codex Responses transport. It never uses the API key.
struct ChatGPTProvider: StreamingTranslationProvider {
    let config: ProviderConfig

    var displayName: String { "ChatGPT subscription" }
    var requiresAPIKey: Bool { false }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        var result = ""
        for try await piece in translateStream(text, from: source, to: target) { result += piece }
        return OpenAICompatibleProvider.sanitize(result)
    }

    func translateStream(_ text: String, from source: String, to target: String)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !text.trimmed.isEmpty else { continuation.finish(); return }
                    let user = userPrompt(text: text.trimmed, from: source, to: target)
                    let system = systemPrompt(from: source, to: target)
                    var credentials = try await ChatGPTAuth.validCredentials()
                    var produced = false

                    for attempt in 0..<2 {
                        let request = try Self.request(model: config.model, system: system,
                                                       user: user, credentials: credentials,
                                                       timeout: config.timeout)
                        let (bytes, response) = try await URLSession.shared.bytes(for: request)
                        if let http = response as? HTTPURLResponse, http.statusCode == 401, attempt == 0 {
                            credentials = try await ChatGPTAuth.validCredentials(forceRefresh: true)
                            continue
                        }
                        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                            var body = ""
                            for try await line in bytes.lines where body.count < 600 { body += line }
                            throw TranslationError.http(status: http.statusCode, body: body)
                        }
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            if let piece = Self.delta(from: line) {
                                produced = true
                                continuation.yield(piece)
                            }
                            if let message = Self.failure(from: line) {
                                throw TranslationError.transport("ChatGPT: \(message)")
                            }
                        }
                        break
                    }
                    if !produced { throw TranslationError.emptyResponse(displayName) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: OpenAICompatibleProvider.friendly(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func request(model: String, system: String, user: String,
                        credentials: ChatGPTAuth.Credentials, timeout: TimeInterval) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": [["role": "user", "content": [["type": "input_text", "text": user]]]],
            "store": false,
            "stream": true,
        ]
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("vibe-translate", forHTTPHeaderField: "originator")
        request.setValue("0.153.0", forHTTPHeaderField: "version")
        request.setValue("model=\(model)", forHTTPHeaderField: "x-codex-routing-hint")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func delta(from line: String) -> String? {
        guard let event = event(from: line), event["type"] as? String == "response.output_text.delta" else {
            return nil
        }
        return event["delta"] as? String
    }

    static func failure(from line: String) -> String? {
        guard let event = event(from: line), event["type"] as? String == "response.failed",
              let response = event["response"] as? [String: Any],
              let error = response["error"] as? [String: Any] else { return nil }
        return error["message"] as? String ?? "The request failed."
    }

    private static func event(from line: String) -> [String: Any]? {
        guard line.hasPrefix("data:"),
              let data = String(line.dropFirst(5)).trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func systemPrompt(from source: String, to target: String) -> String {
        PromptTemplate.fill(config.systemPrompt.trimmed.isEmpty ? PromptTemplate.defaultSystem
                            : config.systemPrompt, text: nil, from: source, to: target)
    }

    private func userPrompt(text: String, from source: String, to target: String) -> String {
        let template = config.userPrompt.trimmed.isEmpty ? PromptTemplate.defaultUser : config.userPrompt
        let filled = PromptTemplate.fill(template, text: text, from: source, to: target)
        return filled.contains(text) ? filled : filled + "\n\n" + text
    }
}

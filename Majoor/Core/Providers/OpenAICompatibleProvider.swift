// OpenAICompatibleProvider.swift
// Majoor — Tiers L and P: any server that speaks OpenAI chat completions
//
// Ollama, LM Studio, vLLM and MLX servers on the Mac mini (tier L), and hosted
// zero-retention endpoints such as Fireworks or Together (tier P), all expose
// `POST {base}/chat/completions` and `GET {base}/models`. This class is the same
// shape as `AnthropicProvider` so the agent loop cannot tell them apart; the
// translation lives in `OpenAIWire` and is tested without a network.

import Foundation

final nonisolated class OpenAICompatibleProvider: LLMProvider, @unchecked Sendable {

    let name: String
    let model: String
    let tier: ProviderTier
    let baseURL: URL
    /// Loopback endpoints: "the server is not running" wording, no network retries.
    let isLocal: Bool

    private let apiKey: String
    private let maxTokens: Int
    private let session: URLSession
    private let maxRetries: Int
    private let retryBaseDelay: Double

    /// Local models think slowly and the whole turn counts against this; on a
    /// byte stream it is the gap-between-packets budget instead.
    private let completionTimeout: TimeInterval = 600
    private let streamTimeout: TimeInterval = 180
    private let probeTimeout: TimeInterval = 10

    init(tier: ProviderTier, baseURL: URL, model: String, apiKey: String = "", maxTokens: Int = 8192,
         session: URLSession = .shared, maxRetries: Int = 2, retryBaseDelay: Double = 2.0) {
        self.tier = tier
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.session = session
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
        self.isLocal = TierEndpoint.isLoopbackHost(baseURL)
        switch tier {
        case .local: self.name = "Local · \(model)"
        case .privateCloud: self.name = "Private · \(model)"
        case .frontier: self.name = model
        }
    }

    private var host: String {
        guard let host = baseURL.host else { return baseURL.absoluteString }
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }

    // MARK: - LLMProvider

    func complete(
        systemPrompt: String,
        messages: [AnthropicMessage],
        tools: [AnthropicTool]
    ) async throws -> (response: LLMResponse, usage: AnthropicUsage?) {
        let request = OpenAIWire.request(model: model, systemPrompt: systemPrompt, messages: messages, tools: tools,
                                         maxTokens: maxTokens, stream: false)
        let data = try await send(request)
        let wire = try Self.decodeResponse(data)
        let result = try OpenAIWire.response(wire)
        log(result)
        return result
    }

    func stream(
        systemPrompt: String,
        messages: [AnthropicMessage],
        tools: [AnthropicTool],
        onDelta: @Sendable @escaping (StreamDelta) -> Void
    ) async throws -> (response: LLMResponse, usage: AnthropicUsage?) {
        let request = OpenAIWire.request(model: model, systemPrompt: systemPrompt, messages: messages, tools: tools,
                                         maxTokens: maxTokens, stream: true)
        let body = try JSONEncoder().encode(request)
        let urlRequest = urlRequest(path: "chat/completions", method: "POST", body: body, timeout: streamTimeout, accept: "text/event-stream")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let urlError as URLError {
            throw OpenAIWire.networkError(urlError, isLocal: isLocal, host: host)
        }
        guard let http = response as? HTTPURLResponse else { throw LLMError.apiError("Invalid HTTP response from \(host)") }
        guard http.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            throw OpenAIWire.error(status: http.statusCode, body: errorData, retryAfter: retryAfter(http), host: host, model: model)
        }

        var accumulator = OpenAIWire.SSEAccumulator()
        do {
            for try await line in bytes.lines {
                for delta in accumulator.feed(line: line) { onDelta(delta) }
                if accumulator.isDone { break }
            }
        } catch let urlError as URLError {
            throw OpenAIWire.networkError(urlError, isLocal: isLocal, host: host)
        }
        let result = try accumulator.finish()
        log(result)
        return result
    }

    // MARK: - Structured output

    /// Asks for a JSON object (`response_format`) and parses it. When the model
    /// answers with something else, it is shown its answer once and asked again;
    /// a second miss is an error, never a guess. For the job runner (Phase 2
    /// step 5), which validates the object against its schema afterwards.
    func completeJSON(systemPrompt: String, messages: [AnthropicMessage]) async throws -> (value: JSONValue, usage: AnthropicUsage?) {
        var messages = messages
        var total: AnthropicUsage?
        for attempt in 0..<2 {
            let request = OpenAIWire.request(model: model, systemPrompt: systemPrompt, messages: messages, tools: [],
                                             maxTokens: maxTokens, stream: false, responseFormat: .jsonObject)
            let data = try await send(request)
            let (response, usage) = try OpenAIWire.response(Self.decodeResponse(data))
            total = Self.add(total, usage)
            let text: String
            switch response {
            case .text(let t): text = t
            case .mixed(let t, _, _): text = t
            case .truncated(let t, _, _): text = t
            case .toolCalls: text = ""
            }
            if let value = Self.parseJSONObject(text) { return (value, total) }
            guard attempt == 0 else { break }
            MajoorLogger.log("⚠️ \(name) did not return a JSON object; asking once more")
            messages.append(AnthropicMessage(role: "assistant", content: .string(text.isEmpty ? "(empty)" : text)))
            messages.append(AnthropicMessage(role: "user", content: .string(
                "That was not a valid JSON object. Reply with exactly one JSON object and nothing else.")))
        }
        throw LLMError.decodingError("\(name) did not return a JSON object")
    }

    /// The first JSON object in `text`, tolerating a ``` fence or prose around it.
    static func parseJSONObject(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"), open < close else { return nil }
        let candidate = String(trimmed[open...close])
        guard let data = candidate.data(using: .utf8), let value = try? JSONValue(data: data), value.objectValue != nil else { return nil }
        return value
    }

    // MARK: - Models

    /// `GET {base}/models`: the ids the server offers, and how long it took to
    /// answer. Settings ▸ Models uses it as the "Test" button.
    static func probe(baseURL: URL, apiKey: String, session: URLSession = .shared) async throws -> (models: [String], latency: TimeInterval) {
        let probe = OpenAICompatibleProvider(tier: .local, baseURL: baseURL, model: "", apiKey: apiKey, session: session, maxRetries: 0)
        let started = ContinuousClock.now
        let models = try await probe.listModels()
        let elapsed = ContinuousClock.now - started
        return (models, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    func listModels() async throws -> [String] {
        let request = urlRequest(path: "models", method: "GET", body: nil, timeout: probeTimeout, accept: "application/json")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw OpenAIWire.networkError(urlError, isLocal: isLocal, host: host)
        }
        guard let http = response as? HTTPURLResponse else { throw LLMError.apiError("Invalid HTTP response from \(host)") }
        guard http.statusCode == 200 else {
            throw OpenAIWire.error(status: http.statusCode, body: data, retryAfter: retryAfter(http), host: host, model: model)
        }
        do {
            return try JSONDecoder().decode(OpenAIWire.ModelList.self, from: data).data.map(\.id).sorted()
        } catch {
            throw LLMError.decodingError("\(host)/models did not return an OpenAI-style model list")
        }
    }

    // MARK: - Transport

    private func urlRequest(path: String, method: String, body: Data?, timeout: TimeInterval, accept: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// POSTs a chat completion. 429 and 5xx are retried with backoff (the
    /// `retry-after` header wins when present); a transport error is retried
    /// once on a remote host and never on a loopback one, where a refused
    /// connection means the server is simply not running.
    private func send(_ request: OpenAIWire.Request) async throws -> Data {
        let body = try JSONEncoder().encode(request)
        var lastError: LLMError?
        var nextDelay = retryBaseDelay
        for attempt in 0...maxRetries {
            if attempt > 0 {
                MajoorLogger.log("⏳ \(name): retrying in \(Int(nextDelay.rounded(.up)))s (attempt \(attempt + 1)/\(maxRetries + 1))")
                try await Task.sleep(for: .seconds(nextDelay))
                nextDelay = retryBaseDelay * pow(2.0, Double(attempt))
            }
            let urlRequest = urlRequest(path: "chat/completions", method: "POST", body: body, timeout: completionTimeout, accept: "application/json")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: urlRequest)
            } catch let urlError as URLError {
                let mapped = OpenAIWire.networkError(urlError, isLocal: isLocal, host: host)
                if let llmError = mapped as? LLMError, !isLocal, attempt == 0, maxRetries > 0 {
                    lastError = llmError
                    continue
                }
                throw mapped
            }
            guard let http = response as? HTTPURLResponse else { throw LLMError.apiError("Invalid HTTP response from \(host)") }
            if http.statusCode == 200 { return data }

            let retryAfter = retryAfter(http)
            let error = OpenAIWire.error(status: http.statusCode, body: data, retryAfter: retryAfter, host: host, model: model)
            let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
            if retryable, attempt < maxRetries {
                lastError = error
                if let retryAfter { nextDelay = Double(retryAfter) }
                continue
            }
            throw error
        }
        throw lastError ?? LLMError.apiError("\(host) failed after \(maxRetries + 1) attempts")
    }

    private func retryAfter(_ http: HTTPURLResponse) -> Int? {
        http.value(forHTTPHeaderField: "retry-after").flatMap(Int.init)
    }

    private static func decodeResponse(_ data: Data) throws -> OpenAIWire.Response {
        do {
            return try JSONDecoder().decode(OpenAIWire.Response.self, from: data)
        } catch {
            MajoorLogger.error("OpenAI-compatible decode failed: \(error)")
            throw LLMError.decodingError(OpenAIWire.errorMessage(from: data) ?? error.localizedDescription)
        }
    }

    private static func add(_ a: AnthropicUsage?, _ b: AnthropicUsage?) -> AnthropicUsage? {
        guard let b else { return a }
        guard let a else { return b }
        return AnthropicUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens)
    }

    private func log(_ result: (response: LLMResponse, usage: AnthropicUsage?)) {
        let label: String
        switch result.response {
        case .text: label = "text"
        case .toolCalls(let calls, _): label = "\(calls.count) tool call(s)"
        case .mixed(_, let calls, _): label = "text + \(calls.count) tool call(s)"
        case .truncated: label = "truncated"
        }
        MajoorLogger.log("✅ \(name): \(label), tokens: \(result.usage?.inputTokens ?? 0)in/\(result.usage?.outputTokens ?? 0)out")
    }
}

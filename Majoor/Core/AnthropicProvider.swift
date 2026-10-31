// AnthropicProvider.swift
// Majoor — Claude API Implementation

import Foundation

// Nonisolated — network calls happen off the main thread
final nonisolated class AnthropicProvider: LLMProvider, @unchecked Sendable {
    
    let name: String
    let model: String
    private var _apiKey: String
    private var apiKey: String { stateLock.withLock { _apiKey } }
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let apiVersion = "2023-06-01"
    // Covers thinking + visible output together, since the 5-family models think
    // adaptively. 16384 left too little for the answer on hard tasks, which is what
    // made max_tokens truncation reachable. The API imposes no streaming
    // requirement here (that check is client-side SDK validation, and this is a raw
    // URLSession client); the real ceiling is the request timeout below. Opus 5 and
    // Sonnet 5 allow 128K output, Haiku 4.5 allows 64K — this value is safe on all
    // three, which matters because ModelRouter can route any of them through here.
    private let maxTokens = 32768
    
    // Retry configuration — 3 retries = 4 total attempts (0, 1, 2, 3)
    private let maxRetries = 3
    /// Timeouts get their own, lower cap — see the `.timedOut` arm for why.
    private let timedOutMaxRetries = 1
    private let baseDelaySeconds: Double = 2.0      // For 429s: 2s, 4s, 8s
    private let networkRetryBaseSeconds: Double = 10.0 // For network timeouts: 10s, 20s, 40s

    // Circuit breaker — stops hammering a down API
    // Protected by stateLock because complete() and stream() can run concurrently
    private let stateLock = NSLock()
    private var _consecutiveFailures: Int = 0
    private var _circuitOpenUntil: Date?
    private let circuitBreakerThreshold = 5
    private let circuitBreakerCooldownSeconds: TimeInterval = 60

    private func checkCircuitBreaker() throws {
        stateLock.lock()
        let openUntil = _circuitOpenUntil
        stateLock.unlock()
        if let openUntil, Date() < openUntil {
            let remaining = Int(openUntil.timeIntervalSince(Date()))
            throw LLMError.apiError("Claude API is temporarily paused after repeated failures. Resuming in \(remaining)s.")
        }
    }

    private func recordSuccess() {
        stateLock.withLock {
            _consecutiveFailures = 0
            _circuitOpenUntil = nil
        }
    }

    private func recordExhaustedRetries() {
        stateLock.withLock {
            _consecutiveFailures += 1
            if _consecutiveFailures >= circuitBreakerThreshold {
                _circuitOpenUntil = Date().addingTimeInterval(circuitBreakerCooldownSeconds)
                MajoorLogger.error("Circuit breaker OPEN — \(_consecutiveFailures) consecutive failures. Pausing API calls for \(Int(circuitBreakerCooldownSeconds))s.")
            }
        }
    }

    init(apiKey: String, model: String = ModelRouter.sonnetModel) {
        self._apiKey = apiKey
        self.model = model
        self.name = model.contains("opus") ? "Claude Opus" :
                    model.contains("sonnet") ? "Claude Sonnet" :
                    model.contains("haiku") ? "Claude Haiku" : "Claude"
    }

    func updateAPIKey(_ newKey: String) {
        stateLock.withLock { _apiKey = newKey }
    }
    
    func complete(
        systemPrompt: String,
        messages: [AnthropicMessage],
        tools: [AnthropicTool]
    ) async throws -> (response: LLMResponse, usage: AnthropicUsage?) {
        
        guard !apiKey.isEmpty else { throw LLMError.invalidAPIKey }
        try checkCircuitBreaker()

        // No `thinking` field — claude-opus-5 / claude-sonnet-5 run adaptive
        // thinking by default, and AgentLoop echoes response blocks verbatim so
        // thinking blocks survive the tool loop.
        let request = AnthropicRequest(
            model: model,
            maxTokens: maxTokens,
            system: systemPrompt,
            messages: messages,
            tools: tools.isEmpty ? nil : tools
        )

        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        
        var urlRequest = URLRequest(url: URL(string: baseURL)!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = requestData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        // Opus with large contexts can take 3+ minutes to respond, and a turn that
        // actually uses the full maxTokens budget takes longer still — too short a
        // timeout here just trades a truncated answer for a retried network error.
        urlRequest.timeoutInterval = model.contains("opus") ? 600 : 360
        
        // Retry loop with exponential backoff for 429, 529, and network errors
        var lastError: Error?
        var lastWasNetworkTimeout = false
        for attempt in 0...maxRetries {
            if attempt > 0 {
                // Use longer backoff after network timeouts (server was likely still processing)
                let base = lastWasNetworkTimeout ? networkRetryBaseSeconds : baseDelaySeconds
                let delay = base * pow(2.0, Double(attempt - 1))
                let reason = lastWasNetworkTimeout ? "Network timeout" : "Rate limited"
                MajoorLogger.log("⏳ \(reason) — retrying in \(Int(delay))s (attempt \(attempt + 1)/\(maxRetries + 1))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            lastWasNetworkTimeout = false

            let data: Data
            let httpResponse: URLResponse
            do {
                (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
            } catch let urlError as URLError {
                // Classify network errors: no internet vs timeout vs other
                switch urlError.code {
                case .cancelled:
                    // URLSession reports task cancellation as URLError(.cancelled),
                    // not CancellationError. Left in the default arm it became a
                    // "network error" and was retried at 10/20/40s — so pressing Stop
                    // meant waiting out the ladder and landing on a bogus summary.
                    throw CancellationError()
                case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                    MajoorLogger.log("⚠️ No internet connection")
                    throw LLMError.noInternet
                case .timedOut:
                    lastWasNetworkTimeout = true
                    lastError = LLMError.networkError("Request timed out — API may be slow")
                    MajoorLogger.log("⚠️ Request timed out (attempt \(attempt + 1)/\(timedOutMaxRetries + 1))")
                    // Deliberately fewer retries than other network errors. A timeout
                    // after the full 600s/360s budget usually means the model was still
                    // generating, and the retry re-sends an identical request — so each
                    // attempt bills another full generation. At a 32K output ceiling
                    // three retries is four paid generations for one answer.
                    if attempt < timedOutMaxRetries { continue }
                    throw lastError!
                default:
                    lastWasNetworkTimeout = true
                    lastError = LLMError.networkError(urlError.localizedDescription)
                    MajoorLogger.log("⚠️ Network error: \(urlError.localizedDescription)")
                    if attempt < maxRetries { continue }
                    throw lastError!
                }
            } catch {
                lastWasNetworkTimeout = true
                lastError = LLMError.networkError(error.localizedDescription)
                MajoorLogger.log("⚠️ Network error: \(error.localizedDescription)")
                if attempt < maxRetries { continue }
                throw lastError!
            }
            
            guard let http = httpResponse as? HTTPURLResponse else {
                throw LLMError.apiError("Invalid HTTP response")
            }
            
            switch http.statusCode {
            case 200:
                // Success — decode and return
                let response: AnthropicResponse
                do {
                    response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
                } catch {
                    MajoorLogger.error("Decode failed: \(error)")
                    throw LLMError.decodingError(error.localizedDescription)
                }
                
                MajoorLogger.log("✅ API: \(response.stopReason ?? "?"), tokens: \(response.usage?.inputTokens ?? 0)in/\(response.usage?.outputTokens ?? 0)out")
                // HTTP 200 means the transport is healthy. Whether the *model*
                // finished is a separate axis, deliberately kept out of the breaker.
                recordSuccess()

                // Report what actually happened instead of inventing an answer. A
                // turn the model did not finish must never reach the loop as `.text`,
                // because the loop treats any text as the final answer — which is how
                // a cut-off run used to be persisted as a completed success.
                switch response.stopReason {
                case "max_tokens":
                    return (.truncated(partialText: visibleText(response.content),
                                       toolCalls: parsedToolCalls(response),
                                       rawContent: response.content), response.usage)

                case "refusal":
                    throw LLMError.refused(category: response.stopDetails?.category)

                case "model_context_window_exceeded":
                    // Route into the trimming recovery the loop already implements
                    // rather than dead-ending as a blank completion.
                    throw LLMError.contextOverflow

                case "pause_turn":
                    // Not a clean ending — the API paused a long turn and expects the
                    // conversation resent to resume. Unreachable while every declared
                    // tool is client-side, but it must not sit in the clean bucket:
                    // treating it as end_turn would complete the task on a half-turn.
                    return (.truncated(partialText: visibleText(response.content),
                                       toolCalls: parsedToolCalls(response),
                                       rawContent: response.content), response.usage)

                default:
                    // end_turn, stop_sequence, nil, and any future reason carrying real
                    // content. Forward-tolerant by design — an unrecognized reason with
                    // a genuine answer still returns normally.
                    return (parseResponse(response), response.usage)
                }
                
            case 401:
                throw LLMError.invalidAPIKey
                
            case 429:
                // Rate limited — use retry-after header if available, otherwise backoff
                let retryAfterSec = http.value(forHTTPHeaderField: "retry-after").flatMap(Int.init)
                lastError = LLMError.rateLimited(retryAfter: retryAfterSec)
                if let retryAfter = retryAfterSec.map(Double.init), attempt < maxRetries {
                    MajoorLogger.log("⏳ Rate limited — retrying in \(Int(retryAfter))s (attempt \(attempt + 1)/\(maxRetries + 1))")
                    try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                    continue  // Skip the normal backoff, we already waited
                }
                if attempt < maxRetries { continue }
                
            case 529:
                // API overloaded — always retry
                MajoorLogger.log("⏳ 529 API overloaded")
                lastError = LLMError.serverOverloaded
                if attempt < maxRetries { continue }

            case 500, 502, 503:
                // Server errors — retry
                lastError = LLMError.apiError("Server error (HTTP \(http.statusCode))")
                if attempt < maxRetries { continue }

            case 400:
                // Check if this is a context overflow error
                if let err = try? JSONDecoder().decode(AnthropicError.self, from: data) {
                    let msg = err.error.message.lowercased()
                    if msg.contains("too many tokens") || msg.contains("token") && msg.contains("limit")
                        || msg.contains("context length") || msg.contains("max tokens")
                        || msg.contains("prompt is too long") {
                        throw LLMError.contextOverflow
                    }
                    throw LLMError.apiError(err.error.message)
                }
                throw LLMError.apiError("Bad request (HTTP 400)")

            default:
                // Non-retryable error — fail immediately
                if let err = try? JSONDecoder().decode(AnthropicError.self, from: data) {
                    throw LLMError.apiError(err.error.message)
                }
                throw LLMError.apiError("HTTP \(http.statusCode)")
            }
        }
        
        // All retries exhausted — update circuit breaker
        recordExhaustedRetries()
        throw lastError ?? LLMError.apiError("Request failed after \(maxRetries + 1) attempts")
    }

    // MARK: - Streaming

    func stream(
        systemPrompt: String,
        messages: [AnthropicMessage],
        tools: [AnthropicTool],
        onDelta: @Sendable @escaping (StreamDelta) -> Void
    ) async throws -> (response: LLMResponse, usage: AnthropicUsage?) {
        guard !apiKey.isEmpty else { throw LLMError.invalidAPIKey }
        try checkCircuitBreaker()

        var request = AnthropicRequest(
            model: model,
            maxTokens: maxTokens,
            system: systemPrompt,
            messages: messages,
            tools: tools.isEmpty ? nil : tools
        )
        request.stream = true
        let body = try JSONEncoder().encode(request)

        var urlRequest = URLRequest(url: URL(string: baseURL)!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        // Shorter than the non-streaming path on purpose: on a byte stream this acts
        // as the gap-between-packets budget, not the whole-turn budget, so a long
        // answer doesn't accumulate against it.
        urlRequest.timeoutInterval = model.contains("opus") ? 300 : 180

        let (bytes, httpResponse) = try await URLSession.shared.bytes(for: urlRequest)

        guard let http = httpResponse as? HTTPURLResponse else {
            throw LLMError.apiError("Invalid HTTP response")
        }
        guard http.statusCode == 200 else {
            // Collect error body
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            // Trip circuit breaker on retryable server errors
            if [429, 500, 502, 503, 529].contains(http.statusCode) {
                recordExhaustedRetries()
            }
            if http.statusCode == 401 { throw LLMError.invalidAPIKey }
            if http.statusCode == 429 { throw LLMError.rateLimited(retryAfter: nil) }
            if http.statusCode == 529 { throw LLMError.serverOverloaded }
            if let err = try? JSONDecoder().decode(AnthropicError.self, from: errorData) {
                throw LLMError.apiError(err.error.message)
            }
            throw LLMError.apiError("HTTP \(http.statusCode)")
        }

        // Parse SSE stream using .lines (handles UTF-8 multi-byte chars like emojis correctly)
        var accumulatedText = ""
        var finalUsage: AnthropicUsage?

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }

            let jsonStr = String(line.dropFirst(6))
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let eventType = json["type"] as? String ?? ""

            switch eventType {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   let deltaType = delta["type"] as? String,
                   deltaType == "text_delta",
                   let text = delta["text"] as? String {
                    accumulatedText += text
                    onDelta(.textDelta(text))
                }
            case "message_delta":
                if let delta = json["delta"] as? [String: Any] {
                    let stopReason = delta["stop_reason"] as? String
                    onDelta(.messageDelta(stopReason: stopReason))
                }
                if let usage = json["usage"] as? [String: Any],
                   let outputTokens = usage["output_tokens"] as? Int {
                    finalUsage = AnthropicUsage(inputTokens: finalUsage?.inputTokens ?? 0, outputTokens: outputTokens)
                }
            case "message_start":
                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any],
                   let inputTokens = usage["input_tokens"] as? Int {
                    finalUsage = AnthropicUsage(inputTokens: inputTokens, outputTokens: finalUsage?.outputTokens ?? 0)
                }
            case "content_block_stop":
                onDelta(.contentBlockStop)
            default:
                break
            }
        }

        let totalUsage: AnthropicUsage? = finalUsage

        recordSuccess()
        return (.text(accumulatedText), totalUsage)
    }

    /// Recursively convert AnyCodable to native types for JSON serialization.
    private static func anyCodableToAny(_ value: AnyCodable) -> Any {
        switch value.value {
        case let arr as [AnyCodable]:
            return arr.map { anyCodableToAny($0) }
        case let dict as [String: AnyCodable]:
            return dict.mapValues { anyCodableToAny($0) }
        default:
            return value.value
        }
    }

    /// The visible half of a turn that didn't finish.
    private func visibleText(_ content: [AnthropicContentBlock]) -> String {
        content.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
    }

    /// Tool calls carried by an unfinished turn. Handed up so the loop can *answer*
    /// them (every `tool_use` needs a matching `tool_result` or the next request
    /// 400s) — never so it can run them, since a cut can sever the input JSON.
    private func parsedToolCalls(_ response: AnthropicResponse) -> [ToolCall] {
        switch parseResponse(response) {
        case .toolCalls(let calls, _):  return calls
        case .mixed(_, let calls, _):   return calls
        case .truncated(_, let calls, _): return calls
        case .text:                     return []
        }
    }

    private func parseResponse(_ response: AnthropicResponse) -> LLMResponse {
        var textParts: [String] = []
        var toolCalls: [ToolCall] = []
        
        for block in response.content {
            switch block.type {
            case "text":
                if let text = block.text, !text.isEmpty { textParts.append(text) }
            case "tool_use":
                if let id = block.id, let name = block.name {
                    // Convert AnyCodable input to [String: String] for native tools
                    var args: [String: String] = [:]
                    if let input = block.input {
                        for (key, val) in input {
                            if let s = val.stringValue { args[key] = s }
                            else if let i = val.intValue { args[key] = String(i) }
                            else if let b = val.boolValue { args[key] = String(b) }
                            else { args[key] = "\(val.value)" }
                        }
                    }
                    // Also preserve raw JSON for MCP tools that need complex types (arrays, objects)
                    var rawJSON: Data? = nil
                    if let input = block.input {
                        let rawDict = input.mapValues { Self.anyCodableToAny($0) }
                        rawJSON = try? JSONSerialization.data(withJSONObject: rawDict)
                    }
                    toolCalls.append(ToolCall(id: id, toolName: name, arguments: args, rawInputJSON: rawJSON))
                }
            case "thinking", "redacted_thinking":
                // Deliberately contributes nothing to textParts — with the default
                // display ("omitted") the thinking text is empty, and reasoning is
                // never user-facing output. The blocks are preserved for the tool
                // loop by handing `response.content` back verbatim as rawContent
                // below; never rebuild or edit them.
                break
            default: break
            }
        }

        let text = textParts.joined(separator: "\n")
        if !toolCalls.isEmpty && !text.isEmpty {
            return .mixed(text: text, toolCalls: toolCalls, rawContent: response.content)
        }
        if !toolCalls.isEmpty { return .toolCalls(toolCalls, rawContent: response.content) }
        return .text(text)
    }
}

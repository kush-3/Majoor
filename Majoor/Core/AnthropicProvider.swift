// AnthropicProvider.swift
// Majoor — Claude API Implementation

import Foundation

// Nonisolated — network calls happen off the main thread
final nonisolated class AnthropicProvider: LLMProvider, @unchecked Sendable {
    
    let name: String
    let model: String
    private var apiKey: String
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let apiVersion = "2023-06-01"
    private let maxTokens = 16384
    
    // Retry configuration — 3 retries = 4 total attempts (0, 1, 2, 3)
    private let maxRetries = 3
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

    init(apiKey: String, model: String = "claude-sonnet-4-20250514") {
        self.apiKey = apiKey
        self.model = model
        self.name = model.contains("opus") ? "Claude Opus" :
                    model.contains("sonnet") ? "Claude Sonnet" :
                    model.contains("haiku") ? "Claude Haiku" : "Claude"
    }
    
    func updateAPIKey(_ newKey: String) {
        self.apiKey = newKey
    }
    
    func complete(
        systemPrompt: String,
        messages: [AnthropicMessage],
        tools: [AnthropicTool]
    ) async throws -> (response: LLMResponse, usage: AnthropicUsage?) {
        
        guard !apiKey.isEmpty else { throw LLMError.invalidAPIKey }
        try checkCircuitBreaker()

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
        // Opus with large contexts can take 3+ minutes to respond
        urlRequest.timeoutInterval = model.contains("opus") ? 300 : 180
        
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
                case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                    MajoorLogger.log("⚠️ No internet connection")
                    throw LLMError.noInternet
                case .timedOut:
                    lastWasNetworkTimeout = true
                    lastError = LLMError.networkError("Request timed out — API may be slow")
                    MajoorLogger.log("⚠️ Request timed out (attempt \(attempt + 1)/\(maxRetries + 1))")
                    if attempt < maxRetries { continue }
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
                
                // Detect truncated tool calls — if stop_reason is "max_tokens" and
                // there are tool_use blocks, the arguments were likely cut off.
                // Return a text response telling the agent to use smaller writes.
                if response.stopReason == "max_tokens" {
                    let hasToolUse = response.content.contains { $0.type == "tool_use" }
                    if hasToolUse {
                        MajoorLogger.log("⚠️ Response truncated (max_tokens) with pending tool calls — requesting smaller output")
                        let recoveryText = response.content
                            .compactMap { $0.text }
                            .joined(separator: "\n")
                        let message = recoveryText.isEmpty
                            ? "My previous response was truncated because the output was too large. I'll break this into smaller steps."
                            : recoveryText + "\n\n[Output was truncated. Breaking into smaller steps.]"
                        recordSuccess()
                        return (.text(message), response.usage)
                    }
                }

                let llmResponse = parseResponse(response)
                MajoorLogger.log("✅ API: \(response.stopReason ?? "?"), tokens: \(response.usage?.inputTokens ?? 0)in/\(response.usage?.outputTokens ?? 0)out")
                recordSuccess()
                return (llmResponse, response.usage)
                
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
                        || msg.contains("context length") || msg.contains("max tokens") {
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

        // Build request body with stream: true
        let request = AnthropicRequest(
            model: model,
            maxTokens: maxTokens,
            system: systemPrompt,
            messages: messages,
            tools: tools.isEmpty ? nil : tools
        )

        var requestDict: [String: Any]
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        requestDict = (try? JSONSerialization.jsonObject(with: requestData) as? [String: Any]) ?? [:]
        requestDict["stream"] = true

        let body = try JSONSerialization.data(withJSONObject: requestDict)

        var urlRequest = URLRequest(url: URL(string: baseURL)!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
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
            default: break
            }
        }
        
        let text = textParts.joined(separator: "\n")
        if !toolCalls.isEmpty && !text.isEmpty { return .mixed(text: text, toolCalls: toolCalls) }
        if !toolCalls.isEmpty { return .toolCalls(toolCalls) }
        return .text(text)
    }
}

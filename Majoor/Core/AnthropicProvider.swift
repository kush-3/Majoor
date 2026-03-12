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
    
    // Retry configuration
    private let maxRetries = 3
    private let baseDelaySeconds: Double = 2.0  // 2s, 4s, 8s exponential backoff
    
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
        urlRequest.timeoutInterval = 120
        
        // Retry loop with exponential backoff for 429 and 529
        var lastError: Error?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delay = baseDelaySeconds * pow(2.0, Double(attempt - 1))
                MajoorLogger.log("⏳ Rate limited — retrying in \(Int(delay))s (attempt \(attempt + 1)/\(maxRetries + 1))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            let data: Data
            let httpResponse: URLResponse
            do {
                (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
            } catch {
                // Network error — retry on transient failures
                lastError = LLMError.networkError(error.localizedDescription)
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
                        return (.text(message), response.usage)
                    }
                }
                
                let llmResponse = parseResponse(response)
                MajoorLogger.log("✅ API: \(response.stopReason ?? "?"), tokens: \(response.usage?.inputTokens ?? 0)in/\(response.usage?.outputTokens ?? 0)out")
                return (llmResponse, response.usage)
                
            case 401:
                throw LLMError.invalidAPIKey
                
            case 429:
                // Rate limited — use retry-after header if available, otherwise backoff
                if let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init), attempt < maxRetries {
                    MajoorLogger.log("⏳ 429 with retry-after: \(Int(retryAfter))s")
                    try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                    lastError = LLMError.rateLimited(retryAfter: Int(retryAfter))
                    continue  // Skip the normal backoff, we already waited
                }
                lastError = LLMError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(Int.init))
                if attempt < maxRetries { continue }
                
            case 529:
                // API overloaded — always retry
                MajoorLogger.log("⏳ 529 API overloaded")
                lastError = LLMError.apiError("API overloaded (529)")
                if attempt < maxRetries { continue }
                
            case 500, 502, 503:
                // Server errors — retry
                lastError = LLMError.apiError("Server error (HTTP \(http.statusCode))")
                if attempt < maxRetries { continue }
                
            default:
                // Non-retryable error — fail immediately
                if let err = try? JSONDecoder().decode(AnthropicError.self, from: data) {
                    throw LLMError.apiError(err.error.message)
                }
                throw LLMError.apiError("HTTP \(http.statusCode)")
            }
        }
        
        // All retries exhausted
        throw lastError ?? LLMError.apiError("Request failed after \(maxRetries + 1) attempts")
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
                    // Convert AnyCodable input to [String: String] for Sendable
                    var args: [String: String] = [:]
                    if let input = block.input {
                        for (key, val) in input {
                            if let s = val.stringValue { args[key] = s }
                            else if let i = val.intValue { args[key] = String(i) }
                            else if let b = val.boolValue { args[key] = String(b) }
                            else { args[key] = "\(val.value)" }
                        }
                    }
                    toolCalls.append(ToolCall(id: id, toolName: name, arguments: args))
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

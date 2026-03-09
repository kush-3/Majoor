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
    private let maxTokens = 4096
    
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
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        
        if let http = httpResponse as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 401: throw LLMError.invalidAPIKey
            case 429:
                let retry = http.value(forHTTPHeaderField: "retry-after").flatMap(Int.init)
                throw LLMError.rateLimited(retryAfter: retry)
            default:
                if let err = try? JSONDecoder().decode(AnthropicError.self, from: data) {
                    throw LLMError.apiError(err.error.message)
                }
                throw LLMError.apiError("HTTP \(http.statusCode)")
            }
        }
        
        let response: AnthropicResponse
        do {
            response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        } catch {
            MajoorLogger.error("Decode failed: \(error)")
            throw LLMError.decodingError(error.localizedDescription)
        }
        
        let llmResponse = parseResponse(response)
        MajoorLogger.log("✅ API: \(response.stopReason ?? "?"), tokens: \(response.usage?.inputTokens ?? 0)in/\(response.usage?.outputTokens ?? 0)out")
        
        return (llmResponse, response.usage)
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

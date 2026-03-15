// LLMProvider.swift
// Majoor — LLM Provider Protocol

import Foundation

// Nonisolated — LLM calls happen off the main thread
nonisolated enum LLMResponse: Sendable {
    case text(String)
    case toolCalls([ToolCall])
    case mixed(text: String, toolCalls: [ToolCall])
}

nonisolated struct ToolCall: Identifiable, Sendable {
    let id: String
    let toolName: String
    let arguments: [String: String] // Simplified to String values for native tools
    let rawInputJSON: Data?         // Raw JSON input for MCP tools (preserves arrays, objects, etc.)
}

// MARK: - Streaming Delta

nonisolated enum StreamDelta: Sendable {
    case textDelta(String)                              // Incremental text chunk
    case toolUseStart(id: String, name: String)         // Tool call starting
    case toolUseInputDelta(String)                      // Tool input JSON chunk
    case contentBlockStop                               // A content block finished
    case messageDelta(stopReason: String?)              // Message ending with usage
}

protocol LLMProvider: Sendable {
    var name: String { get }
    var model: String { get }

    func complete(
        systemPrompt: String,
        messages: [AnthropicMessage],
        tools: [AnthropicTool]
    ) async throws -> (response: LLMResponse, usage: AnthropicUsage?)

    /// Streaming variant — calls onDelta for each incremental chunk.
    /// Returns the fully accumulated response when the stream completes.
    func stream(
        systemPrompt: String,
        messages: [AnthropicMessage],
        tools: [AnthropicTool],
        onDelta: @Sendable @escaping (StreamDelta) -> Void
    ) async throws -> (response: LLMResponse, usage: AnthropicUsage?)
}

// Default implementation: falls back to complete() for providers that don't support streaming
extension LLMProvider {
    func stream(
        systemPrompt: String,
        messages: [AnthropicMessage],
        tools: [AnthropicTool],
        onDelta: @Sendable @escaping (StreamDelta) -> Void
    ) async throws -> (response: LLMResponse, usage: AnthropicUsage?) {
        let result = try await complete(systemPrompt: systemPrompt, messages: messages, tools: tools)
        if case .text(let text) = result.response {
            onDelta(.textDelta(text))
        }
        return result
    }
}

enum LLMError: LocalizedError, Sendable {
    case invalidAPIKey
    case networkError(String)
    case noInternet
    case apiError(String)
    case decodingError(String)
    case rateLimited(retryAfter: Int?)
    case contextOverflow
    case serverOverloaded

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Invalid or missing API key. Update it in Settings."
        case .networkError(let msg): return "Network error: \(msg)"
        case .noInternet: return "No internet connection. Check your network and try again."
        case .apiError(let msg): return "API error: \(msg)"
        case .decodingError(let msg): return "Failed to parse response: \(msg)"
        case .rateLimited(let retry):
            return retry.map { "Rate limited. Retry in \($0)s." } ?? "Rate limited."
        case .contextOverflow: return "Task too complex — conversation exceeded context limit. Try breaking it into smaller steps."
        case .serverOverloaded: return "Claude API is overloaded. Try again in a few minutes."
        }
    }

    /// Whether this error is transient and worth retrying
    nonisolated var isTransient: Bool {
        switch self {
        case .rateLimited, .serverOverloaded, .networkError: return true
        case .invalidAPIKey, .noInternet, .contextOverflow, .apiError, .decodingError: return false
        }
    }

    /// Whether this error should prompt the user to open Settings
    nonisolated var shouldOpenSettings: Bool {
        switch self {
        case .invalidAPIKey: return true
        default: return false
        }
    }
}

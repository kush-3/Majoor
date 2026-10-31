// LLMProvider.swift
// Majoor — LLM Provider Protocol

import Foundation

// Nonisolated — LLM calls happen off the main thread
nonisolated enum LLMResponse: Sendable {
    case text(String)
    /// `rawContent` is the model's response content blocks verbatim. The agent loop
    /// echoes it back as the assistant turn so `thinking` / `redacted_thinking`
    /// blocks survive the tool loop — the API 400s a tool-loop continuation whose
    /// assistant turn is missing or has edited them.
    case toolCalls([ToolCall], rawContent: [AnthropicContentBlock])
    case mixed(text: String, toolCalls: [ToolCall], rawContent: [AnthropicContentBlock])
    /// The model stopped at the output limit mid-turn. This is never a final answer.
    /// `toolCalls` were parsed but their input JSON may be cut mid-object, so they
    /// must be answered and never executed. `rawContent` is the turn verbatim.
    ///
    /// This is a case rather than a thrown error on purpose: the agent loop's switch
    /// over `LLMResponse` is the only exhaustive one in the app, so adding it here
    /// makes handling truncation a compile error rather than a convention someone
    /// can quietly drop later.
    case truncated(partialText: String, toolCalls: [ToolCall], rawContent: [AnthropicContentBlock])
}

/// Why a run ended without producing an answer. Every one of these used to be
/// reported as a completed task.
nonisolated enum IncompleteReason: String, Sendable {
    case truncated, emptyResponse, iterationLimit, cancelled, toolPhaseFailure, budgetExceeded

    var userFacing: String {
        switch self {
        case .truncated:        return "Claude's response was cut off by the output limit and couldn't be recovered."
        case .emptyResponse:    return "Claude finished without producing an answer."
        case .iterationLimit:   return "Stopped after hitting the step limit without finishing."
        case .cancelled:        return "Stopped by user."
        case .toolPhaseFailure: return "Stopped while running tools."
        case .budgetExceeded:   return "Stopped: the session token budget was reached."
        }
    }
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
    /// The run stopped without finishing. Distinct from a hard failure so the UI can
    /// say so, and so `AppDelegate` can't render it as a green "Task Complete".
    case incomplete(reason: IncompleteReason)
    /// Safety classifiers declined the request (HTTP 200, `stop_reason: "refusal"`).
    /// Its own case so the message isn't prefixed "API error:" — a model policy
    /// decision must not be recorded in history as an infrastructure fault.
    case refused(category: String?)

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
        case .incomplete(let reason): return reason.userFacing
        case .refused(let category):
            return category.map { "Claude declined this request (\($0))." } ?? "Claude declined this request."
        }
    }

    /// Whether this error is transient and worth retrying
    nonisolated var isTransient: Bool {
        switch self {
        case .rateLimited, .serverOverloaded, .networkError: return true
        case .invalidAPIKey, .noInternet, .contextOverflow, .apiError, .decodingError,
             .incomplete, .refused: return false
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

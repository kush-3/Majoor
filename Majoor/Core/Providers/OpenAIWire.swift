// OpenAIWire.swift
// Majoor — Translation between the agent loop's Anthropic shapes and the OpenAI
// chat-completions wire format
//
// `LLMProvider` is Anthropic-shaped on purpose: the loop echoes the model's
// content blocks back verbatim as the assistant turn, which is what keeps
// `thinking` blocks valid on Claude. An OpenAI-compatible server therefore gets
// a translation in both directions, and the loop never knows. Everything here is
// pure and tested; `OpenAICompatibleProvider` owns the HTTP.
//
//   AnthropicMessage ──► chat messages   (tool_use → tool_calls, tool_result → role "tool")
//   AnthropicTool    ──► function tools  (input_schema → parameters)
//   chat reply       ──► LLMResponse     (tool_calls → ToolCall + synthesized tool_use blocks,
//                                          finish_reason "length" → .truncated)

import Foundation

nonisolated enum OpenAIWire {

    // MARK: - Request types

    nonisolated struct Request: Encodable, Sendable {
        var model: String
        var messages: [Message]
        var tools: [ToolDefinition]?
        var maxTokens: Int
        var stream: Bool?
        var streamOptions: StreamOptions?
        var responseFormat: ResponseFormat?

        enum CodingKeys: String, CodingKey {
            case model, messages, tools, stream
            case maxTokens = "max_tokens"
            case streamOptions = "stream_options"
            case responseFormat = "response_format"
        }
    }

    nonisolated struct StreamOptions: Codable, Sendable, Equatable {
        var includeUsage: Bool
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    nonisolated struct ResponseFormat: Codable, Sendable, Equatable {
        var type: String
        static let jsonObject = ResponseFormat(type: "json_object")
    }

    nonisolated struct Message: Codable, Sendable, Equatable {
        var role: String
        var content: String?
        var toolCalls: [ToolCallWire]?
        var toolCallId: String?

        init(role: String, content: String? = nil, toolCalls: [ToolCallWire]? = nil, toolCallId: String? = nil) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallId = toolCallId
        }

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallId = "tool_call_id"
        }
    }

    nonisolated struct ToolCallWire: Codable, Sendable, Equatable {
        var id: String?
        var type: String?
        var function: FunctionCall
    }

    nonisolated struct FunctionCall: Codable, Sendable, Equatable {
        var name: String?
        var arguments: String?
    }

    nonisolated struct ToolDefinition: Encodable, Sendable {
        var type: String = "function"
        var function: FunctionDefinition
    }

    nonisolated struct FunctionDefinition: Encodable, Sendable {
        var name: String
        var description: String
        var parameters: JSONValue
    }

    // MARK: - Response types

    nonisolated struct Response: Decodable, Sendable {
        var id: String?
        var model: String?
        var choices: [Choice]
        var usage: Usage?
    }

    nonisolated struct Choice: Decodable, Sendable {
        var index: Int?
        var message: Message
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    nonisolated struct Usage: Decodable, Sendable {
        var promptTokens: Int?
        var completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    nonisolated struct Chunk: Decodable, Sendable {
        var choices: [ChunkChoice]?
        var usage: Usage?
    }

    nonisolated struct ChunkChoice: Decodable, Sendable {
        var index: Int?
        var delta: Delta?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    nonisolated struct Delta: Decodable, Sendable {
        var role: String?
        var content: String?
        var toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
        }
    }

    nonisolated struct ToolCallDelta: Decodable, Sendable {
        var index: Int?
        var id: String?
        var type: String?
        var function: FunctionCall?
    }

    nonisolated struct ModelList: Decodable, Sendable {
        nonisolated struct Entry: Decodable, Sendable { var id: String }
        var data: [Entry]
    }

    // MARK: - Request translation

    static func request(model: String, systemPrompt: String, messages: [AnthropicMessage], tools: [AnthropicTool],
                        maxTokens: Int, stream: Bool, responseFormat: ResponseFormat? = nil) -> Request {
        Request(model: model,
                messages: self.messages(systemPrompt: systemPrompt, messages: messages),
                tools: tools.isEmpty ? nil : self.tools(tools),
                maxTokens: maxTokens,
                stream: stream ? true : nil,
                streamOptions: stream ? StreamOptions(includeUsage: true) : nil,
                responseFormat: responseFormat)
    }

    /// The system prompt becomes the first message. A user turn made of
    /// `tool_result` blocks becomes one `tool` message per result (they must
    /// directly follow the assistant turn that called them, so any text in that
    /// turn comes after). An assistant turn's `tool_use` blocks become
    /// `tool_calls`; its reasoning blocks have no counterpart and are dropped,
    /// and a turn left with neither text nor calls is skipped.
    static func messages(systemPrompt: String, messages: [AnthropicMessage]) -> [Message] {
        var out: [Message] = []
        if !systemPrompt.isEmpty { out.append(Message(role: "system", content: systemPrompt)) }
        for message in messages {
            switch message.content {
            case .string(let text):
                if message.role == "assistant" && text.isEmpty { continue }
                out.append(Message(role: message.role, content: text))
            case .blocks(let blocks):
                if message.role == "assistant" {
                    if let translated = assistantMessage(blocks) { out.append(translated) }
                } else {
                    out.append(contentsOf: userMessages(role: message.role, blocks: blocks))
                }
            }
        }
        return out
    }

    private static func assistantMessage(_ blocks: [AnthropicContentBlock]) -> Message? {
        var textParts: [String] = []
        var calls: [ToolCallWire] = []
        for block in blocks {
            switch block.type {
            case "text":
                if let text = block.text, !text.isEmpty { textParts.append(text) }
            case "tool_use":
                // Mirror AnthropicProvider.parseResponse, which needs both.
                guard let id = block.id, let name = block.name else { continue }
                calls.append(ToolCallWire(id: id, type: "function",
                                          function: FunctionCall(name: name, arguments: argumentsJSON(block.input))))
            default:
                break   // thinking, redacted_thinking: nothing to say on this side
            }
        }
        let text = textParts.joined(separator: "\n")
        if text.isEmpty && calls.isEmpty { return nil }
        return Message(role: "assistant", content: text.isEmpty ? nil : text, toolCalls: calls.isEmpty ? nil : calls)
    }

    private static func userMessages(role: String, blocks: [AnthropicContentBlock]) -> [Message] {
        var out: [Message] = []
        var textParts: [String] = []
        for block in blocks {
            switch block.type {
            case "tool_result":
                guard let id = block.toolUseId else { continue }
                var content = block.content ?? ""
                if block.isError == true && !content.hasPrefix("ERROR") { content = "ERROR: " + content }
                out.append(Message(role: "tool", content: content, toolCallId: id))
            case "text":
                if let text = block.text, !text.isEmpty { textParts.append(text) }
            default:
                break
            }
        }
        if !textParts.isEmpty { out.append(Message(role: role, content: textParts.joined(separator: "\n"))) }
        return out
    }

    /// `tool_use.input` as the JSON string OpenAI expects. Sorted keys, so a
    /// round trip is byte-stable.
    static func argumentsJSON(_ input: [String: AnyCodable]?) -> String {
        guard let input, !input.isEmpty, let data = try? JSONEncoder.wire.encode(input),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func tools(_ tools: [AnthropicTool]) -> [ToolDefinition] {
        tools.map { tool in
            let parameters = (try? JSONValue.encoding(tool.inputSchema)) ?? .object(["type": .string("object"), "properties": .object([:])])
            return ToolDefinition(function: FunctionDefinition(name: tool.name, description: tool.description, parameters: parameters))
        }
    }

    // MARK: - Response translation

    /// `choices[0]` as the loop's `LLMResponse`. Tool calls come back both as
    /// `ToolCall`s and as synthesized `tool_use` blocks, so the loop's
    /// echo-back and argument normalization work exactly as they do for Claude.
    static func response(_ response: Response) throws -> (response: LLMResponse, usage: AnthropicUsage?) {
        guard let choice = response.choices.first else {
            throw LLMError.decodingError("The reply had no choices")
        }
        let usage = response.usage.map { AnthropicUsage(inputTokens: $0.promptTokens ?? 0, outputTokens: $0.completionTokens ?? 0) }
        return (try llmResponse(text: choice.message.content ?? "", toolCalls: choice.message.toolCalls ?? [],
                                finishReason: choice.finishReason), usage)
    }

    static func llmResponse(text rawText: String, toolCalls wires: [ToolCallWire], finishReason: String?) throws -> LLMResponse {
        let text = stripReasoning(rawText)
        var calls: [ToolCall] = []
        var blocks: [AnthropicContentBlock] = []
        if !text.isEmpty {
            blocks.append(AnthropicContentBlock(type: "text", text: text, id: nil, name: nil, input: nil, toolUseId: nil, content: nil))
        }
        for (index, wire) in wires.enumerated() {
            guard let name = wire.function.name, !name.isEmpty else { continue }
            let (call, block) = toolCall(id: wire.id, index: index, name: name, arguments: wire.function.arguments)
            calls.append(call)
            blocks.append(block)
        }

        switch finishReason {
        case "length":
            return .truncated(partialText: text, toolCalls: calls, rawContent: blocks)
        case "content_filter":
            throw LLMError.apiError("The model declined this request (content_filter).")
        default:
            break
        }
        if !calls.isEmpty && !text.isEmpty { return .mixed(text: text, toolCalls: calls, rawContent: blocks) }
        if !calls.isEmpty { return .toolCalls(calls, rawContent: blocks) }
        return .text(text)
    }

    /// One tool call in both shapes. A missing id is synthesized so the
    /// `tool_result` the loop sends back can still name it. Arguments that are
    /// not a JSON object (a model mid-sentence, or garbage) become an empty
    /// argument list: the tool then fails on its missing parameter and the model
    /// gets to try again, which beats guessing.
    static func toolCall(id: String?, index: Int, name: String, arguments: String?) -> (ToolCall, AnthropicContentBlock) {
        let callId = (id?.isEmpty == false) ? id! : "call_\(index)_\(UUID().uuidString.prefix(8))"
        var object: [String: JSONValue] = [:]
        if let arguments, let data = arguments.data(using: .utf8), let value = try? JSONValue(data: data), let parsed = value.objectValue {
            object = parsed
        } else if let arguments, !arguments.trimmingCharacters(in: .whitespaces).isEmpty, arguments != "{}" {
            MajoorLogger.error("Tool call \(name) arrived with non-object arguments: \(arguments.prefix(200))")
        }
        let rawJSON = object.isEmpty ? nil : try? JSONValue.object(object).data()
        let call = ToolCall(id: callId, toolName: name, arguments: argumentStrings(object), rawInputJSON: rawJSON)
        let block = AnthropicContentBlock(type: "tool_use", text: nil, id: callId, name: name,
                                          input: object.mapValues(anyCodable), toolUseId: nil, content: nil)
        return (call, block)
    }

    /// The loop's `[String: String]` view of arguments. Scalars print as they
    /// would in JSON; nested values are JSON text (native tools have none).
    static func argumentStrings(_ object: [String: JSONValue]) -> [String: String] {
        object.mapValues { value in
            switch value {
            case .string(let s): return s
            case .bool(let b): return String(b)
            case .null: return ""
            case .number(let n):
                if n == n.rounded(), abs(n) < 9_007_199_254_740_992 { return String(Int64(n)) }
                return String(n)
            case .array, .object:
                return (try? value.data()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            }
        }
    }

    static func anyCodable(_ value: JSONValue) -> AnyCodable {
        switch value {
        case .string(let s): return AnyCodable(s)
        case .bool(let b): return AnyCodable(b)
        case .null: return AnyCodable("")   // AnyCodable decodes JSON null as "" too
        case .number(let n):
            if n == n.rounded(), abs(n) < 9_007_199_254_740_992 { return AnyCodable(Int(n)) }
            return AnyCodable(n)
        case .array(let items): return AnyCodable(items.map(anyCodable))
        case .object(let dict): return AnyCodable(dict.mapValues(anyCodable))
        }
    }

    /// Local reasoning models (Qwen 3, DeepSeek R1 distils) may inline their
    /// thinking as a leading `<think>…</think>` block when the server does not
    /// split it out. It is reasoning, never the answer.
    static func stripReasoning(_ text: String) -> String {
        var out = text
        while out.hasPrefix("<think>") {
            guard let close = out.range(of: "</think>") else { return "" }   // cut mid-thought: nothing visible yet
            out = String(out[close.upperBound...])
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    // MARK: - Errors

    /// HTTP status plus body to the loop's error. Server-side wording is kept
    /// generic: `LLMError`'s own strings for overload and refusal name Claude,
    /// which would be wrong for a local or private endpoint.
    static func error(status: Int, body: Data, retryAfter: Int?, host: String, model: String) -> LLMError {
        let message = errorMessage(from: body)
        switch status {
        case 401, 403:
            return .invalidAPIKey
        case 404:
            return .apiError(message ?? "\(host) has no model named '\(model)' (HTTP 404)")
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 400, 422:
            if let message, isContextOverflow(message) { return .contextOverflow }
            return .apiError(message ?? "\(host) rejected the request (HTTP \(status))")
        case 500...599:
            return .apiError("\(host) returned HTTP \(status)" + (message.map { ": \($0)" } ?? ""))
        default:
            return .apiError(message ?? "\(host) returned HTTP \(status)")
        }
    }

    static func isContextOverflow(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("context length") || lower.contains("context window") || lower.contains("maximum context")
            || lower.contains("too many tokens") || lower.contains("prompt is too long") || lower.contains("token limit")
            || (lower.contains("tokens") && lower.contains("exceed"))
    }

    /// Whatever the server put in its error body: `{"error": {"message": …}}`
    /// (OpenAI, vLLM), `{"error": "…"}` (Ollama), `{"detail": …}` (FastAPI),
    /// `{"message": …}`, or plain text. Capped so a stack trace never becomes a
    /// toast.
    static func errorMessage(from body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        if let value = try? JSONValue(data: body) {
            if let message = value["error"]?["message"]?.stringValue { return cap(message) }
            if let message = value["error"]?.stringValue { return cap(message) }
            if let message = value["detail"]?.stringValue { return cap(message) }
            if let first = value["detail"]?.arrayValue?.first, let message = first["msg"]?.stringValue { return cap(message) }
            if let message = value["message"]?.stringValue { return cap(message) }
            return nil
        }
        guard let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.hasPrefix("<") else { return nil }
        return cap(text)
    }

    private static func cap(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
    }

    /// A transport failure to the loop's error. Stop is `CancellationError` (the
    /// loop records it as stopped); a refused connection to a loopback server
    /// says the server is not running instead of blaming the network.
    static func networkError(_ error: URLError, isLocal: Bool, host: String) -> any Error {
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .secureConnectionFailed:
            if isLocal { return LLMError.networkError(localServerDown(host)) }
            return LLMError.networkError("Cannot reach \(host): \(error.localizedDescription)")
        case .notConnectedToInternet, .dataNotAllowed:
            return isLocal ? LLMError.networkError(localServerDown(host)) : LLMError.noInternet
        case .timedOut:
            return LLMError.networkError("Request to \(host) timed out")
        default:
            return LLMError.networkError(error.localizedDescription)
        }
    }

    static func localServerDown(_ host: String) -> String {
        "The local model server at \(host) is not running. Start it (for Ollama: `ollama serve`) and try again."
    }

    // MARK: - Streaming

    /// Folds `data:` lines of a chat-completions SSE stream into deltas for the
    /// UI and, at the end, the same `LLMResponse` the non-streaming path yields.
    /// Tool-call arguments arrive in fragments keyed by `index`; text arrives in
    /// fragments too. One JSON payload spanning several `data:` lines is
    /// buffered until it parses or a blank line ends the event.
    nonisolated struct SSEAccumulator: Sendable {
        private(set) var text = ""
        private(set) var finishReason: String?
        private(set) var usage: AnthropicUsage?
        private(set) var isDone = false
        private var calls: [Int: ToolCallWire] = [:]
        private var order: [Int] = []
        private var pending: [String] = []

        init() {}

        mutating func feed(line rawLine: String) -> [StreamDelta] {
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty {
                return flushPending()
            }
            guard line.hasPrefix("data:") else { return [] }   // comments, event:, id:, retry:
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            if payload == "[DONE]" {
                isDone = true
                return flushPending()
            }
            if let chunk = Self.decode(payload) {
                pending.removeAll()
                return apply(chunk)
            }
            pending.append(payload)
            let joined = pending.joined(separator: "\n")
            if let chunk = Self.decode(joined) {
                pending.removeAll()
                return apply(chunk)
            }
            return []
        }

        private mutating func flushPending() -> [StreamDelta] {
            guard !pending.isEmpty else { return [] }
            let joined = pending.joined(separator: "\n")
            pending.removeAll()
            guard let chunk = Self.decode(joined) else {
                MajoorLogger.error("Dropped an unparseable SSE event (\(joined.count) chars)")
                return []
            }
            return apply(chunk)
        }

        private static func decode(_ payload: String) -> Chunk? {
            guard let data = payload.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Chunk.self, from: data)
        }

        private mutating func apply(_ chunk: Chunk) -> [StreamDelta] {
            var deltas: [StreamDelta] = []
            if let usage = chunk.usage {
                self.usage = AnthropicUsage(inputTokens: usage.promptTokens ?? 0, outputTokens: usage.completionTokens ?? 0)
            }
            for choice in chunk.choices ?? [] {
                if let content = choice.delta?.content, !content.isEmpty {
                    text += content
                    deltas.append(.textDelta(content))
                }
                for fragment in choice.delta?.toolCalls ?? [] {
                    let index = fragment.index ?? (order.last.map { $0 + 1 } ?? 0)
                    if var existing = calls[index] {
                        if let id = fragment.id, !id.isEmpty { existing.id = id }
                        if let name = fragment.function?.name, !name.isEmpty { existing.function.name = (existing.function.name ?? "") + name }
                        if let args = fragment.function?.arguments, !args.isEmpty {
                            existing.function.arguments = (existing.function.arguments ?? "") + args
                            deltas.append(.toolUseInputDelta(args))
                        }
                        calls[index] = existing
                    } else {
                        let call = ToolCallWire(id: fragment.id, type: fragment.type,
                                                function: FunctionCall(name: fragment.function?.name, arguments: fragment.function?.arguments))
                        calls[index] = call
                        order.append(index)
                        deltas.append(.toolUseStart(id: call.id ?? "", name: call.function.name ?? ""))
                        if let args = call.function.arguments, !args.isEmpty { deltas.append(.toolUseInputDelta(args)) }
                    }
                }
                if let reason = choice.finishReason {
                    finishReason = reason
                    deltas.append(.contentBlockStop)
                    deltas.append(.messageDelta(stopReason: reason))
                }
            }
            return deltas
        }

        /// The accumulated turn, exactly as `response(_:)` would have returned it.
        func finish() throws -> (response: LLMResponse, usage: AnthropicUsage?) {
            let wires = order.compactMap { calls[$0] }
            return (try llmResponse(text: text, toolCalls: wires, finishReason: finishReason), usage)
        }
    }
}

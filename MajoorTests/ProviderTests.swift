// ProviderTests.swift
// MajoorTests — OpenAI-compatible provider: the pure translation layer, the
// SSE accumulator, error mapping, tier settings, and the HTTP path against a
// loopback server. No real network, no real UserDefaults, no real Keychain.

import Foundation
import Network
import Testing
@testable import Majoor

// MARK: - Helpers

nonisolated func block(_ type: String, text: String? = nil, id: String? = nil, name: String? = nil,
                       input: [String: AnyCodable]? = nil, toolUseId: String? = nil, content: String? = nil,
                       isError: Bool? = nil) -> AnthropicContentBlock {
    AnthropicContentBlock(type: type, text: text, id: id, name: name, input: input, toolUseId: toolUseId, content: content, isError: isError)
}

nonisolated func decodeResponse(_ text: String) -> OpenAIWire.Response {
    try! JSONDecoder().decode(OpenAIWire.Response.self, from: Data(text.utf8))
}

/// Runs `body`, expecting it to throw an `LLMError` that satisfies `check`.
func expectLLMError(_ label: String = "", _ check: (LLMError) -> Bool, _ body: () async throws -> some Any) async {
    do {
        _ = try await body()
        Issue.record("\(label): expected an LLMError, got a value")
    } catch let error as LLMError {
        #expect(check(error), "\(label): unexpected LLMError \(error)")
    } catch {
        Issue.record("\(label): expected an LLMError, got \(error)")
    }
}

nonisolated final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func secret(for key: String) -> String? { lock.withLock { values[key] } }
    func setSecret(_ value: String, for key: String) { lock.withLock { values[key] = value } }
    func removeSecret(for key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// A one-request-per-connection HTTP/1.1 responder on 127.0.0.1, enough for
/// URLSession: reads the head plus `Content-Length` bytes, answers, closes.
nonisolated final class FakeHTTPServer: @unchecked Sendable {
    nonisolated struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        var json: JSONValue? { try? JSONValue(data: body) }
    }
    nonisolated struct Reply: Sendable {
        var status = 200
        var contentType = "application/json"
        var body: Data
        var headers: [String: String] = [:]
        init(status: Int = 200, contentType: String = "application/json", body: String, headers: [String: String] = [:]) {
            self.status = status
            self.contentType = contentType
            self.body = Data(body.utf8)
            self.headers = headers
        }
    }
    typealias Handler = @Sendable (Request) -> Reply

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MajoorTests.FakeHTTPServer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var recorded: [Request] = []
    private let handler: Handler
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    var requests: [Request] { lock.withLock { recorded } }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    func start() async throws {
        let resumed = LockedFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard resumed.set(), let self else { return }
                    self.port = self.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.withLock { self.recorded.append(request) }
                let reply = self.handler(request)
                var head = "HTTP/1.1 \(reply.status) \(reply.status == 200 ? "OK" : "Error")\r\n"
                head += "Content-Type: \(reply.contentType)\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n"
                for (key, value) in reply.headers { head += "\(key): \(value)\r\n" }
                head += "\r\n"
                var out = Data(head.utf8)
                out.append(reply.body)
                connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if isComplete || error != nil { connection.cancel(); return }
            self.receive(connection, buffer: buffer)
        }
    }

    private static func parse(_ buffer: Data) -> Request? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body.prefix(length)))
    }
}

nonisolated final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// True the first time only.
    func set() -> Bool { lock.withLock { if value { return false }; value = true; return true } }
}

nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// A port nothing listens on: bind, read the number, close.
func closedPort() async throws -> UInt16 {
    let server = try FakeHTTPServer { _ in Reply200 }
    try await server.start()
    let port = server.port
    server.stop()
    try await Task.sleep(for: .milliseconds(50))
    return port
}

nonisolated let Reply200 = FakeHTTPServer.Reply(body: "{}")

nonisolated let textReply = """
{"id":"chatcmpl-1","model":"qwen3:8b","choices":[{"index":0,"message":{"role":"assistant","content":"Hello there"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}
"""

nonisolated let toolReply = """
{"id":"chatcmpl-2","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_abc","type":"function","function":{"name":"read_file","arguments":"{\\"path\\": \\"~/notes.txt\\", \\"lines\\": 20, \\"all\\": true, \\"ratio\\": 0.5, \\"tags\\": [\\"a\\",\\"b\\"]}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":40,"completion_tokens":20}}
"""

// MARK: - Messages

@Suite("OpenAIWire: messages")
struct OpenAIWireMessageTests {

    @Test("the system prompt comes first; string turns pass through")
    func systemAndStrings() {
        let out = OpenAIWire.messages(systemPrompt: "Be brief.", messages: [
            AnthropicMessage(role: "user", content: .string("hi")),
            AnthropicMessage(role: "assistant", content: .string("hello")),
            AnthropicMessage(role: "user", content: .string("more")),
        ])
        #expect(out.map(\.role) == ["system", "user", "assistant", "user"])
        #expect(out[0].content == "Be brief.")
        #expect(out[2].content == "hello")
        #expect(OpenAIWire.messages(systemPrompt: "", messages: []).isEmpty)
    }

    @Test("an assistant turn's tool_use blocks become tool_calls with JSON arguments; text is kept")
    func assistantToolUse() {
        let input: [String: AnyCodable] = ["path": AnyCodable("~/x"), "lines": AnyCodable(20), "all": AnyCodable(true)]
        let out = OpenAIWire.messages(systemPrompt: "", messages: [
            AnthropicMessage(role: "assistant", content: .blocks([
                block("thinking", text: nil),
                block("text", text: "Reading it."),
                block("tool_use", id: "call_1", name: "read_file", input: input),
                block("tool_use", id: "call_2", name: "list_files"),
                block("tool_use", id: nil, name: "dropped"),
            ])),
        ])
        #expect(out.count == 1)
        let message = out[0]
        #expect(message.role == "assistant")
        #expect(message.content == "Reading it.")
        #expect(message.toolCalls?.count == 2)
        #expect(message.toolCalls?[0].id == "call_1")
        #expect(message.toolCalls?[0].type == "function")
        #expect(message.toolCalls?[0].function.name == "read_file")
        #expect(message.toolCalls?[0].function.arguments == #"{"all":true,"lines":20,"path":"~/x"}"#)
        #expect(message.toolCalls?[1].function.arguments == "{}")
    }

    @Test("tool_result blocks become one tool message each, errors flagged, text after them")
    func toolResults() {
        let out = OpenAIWire.messages(systemPrompt: "", messages: [
            AnthropicMessage(role: "user", content: .blocks([
                block("text", text: "By the way"),
                block("tool_result", toolUseId: "call_1", content: "file contents"),
                block("tool_result", toolUseId: "call_2", content: "Permission denied", isError: true),
                block("tool_result", toolUseId: nil, content: "orphan"),
            ])),
        ])
        #expect(out.map(\.role) == ["tool", "tool", "user"])
        #expect(out[0].toolCallId == "call_1")
        #expect(out[0].content == "file contents")
        #expect(out[1].toolCallId == "call_2")
        #expect(out[1].content == "ERROR: Permission denied")
        #expect(out[2].content == "By the way")
    }

    @Test("a thinking-only assistant turn and an empty assistant string are skipped")
    func emptyAssistantSkipped() {
        let out = OpenAIWire.messages(systemPrompt: "", messages: [
            AnthropicMessage(role: "assistant", content: .blocks([block("thinking"), block("redacted_thinking")])),
            AnthropicMessage(role: "assistant", content: .string("")),
            AnthropicMessage(role: "user", content: .string("still here")),
        ])
        #expect(out.map(\.role) == ["user"])
    }

    @Test("a tool's input schema becomes function parameters")
    func tools() throws {
        let tool = AnthropicTool(name: "read_file", description: "Reads a file",
                                 inputSchema: AnthropicToolSchema(type: "object",
                                                                  properties: ["path": AnthropicProperty(type: "string", description: "Path", enumValues: nil),
                                                                               "mode": AnthropicProperty(type: "string", description: "Mode", enumValues: ["head", "tail"])],
                                                                  required: ["path"]))
        let defs = OpenAIWire.tools([tool])
        #expect(defs.count == 1)
        #expect(defs[0].type == "function")
        #expect(defs[0].function.name == "read_file")
        #expect(defs[0].function.description == "Reads a file")
        let parameters = defs[0].function.parameters
        #expect(parameters["type"]?.stringValue == "object")
        #expect(parameters["required"]?.arrayValue?.first?.stringValue == "path")
        #expect(parameters["properties"]?["path"]?["type"]?.stringValue == "string")
        #expect(parameters["properties"]?["mode"]?["enum"]?.arrayValue?.count == 2)

        let data = try JSONEncoder().encode(OpenAIWire.request(model: "m", systemPrompt: "s", messages: [], tools: [tool], maxTokens: 10, stream: false))
        let body = try JSONValue(data: data)
        #expect(body["tools"]?.arrayValue?.count == 1)
        #expect(body["max_tokens"]?.intValue == 10)
        #expect(body["stream"] == nil)
        #expect(body["stream_options"] == nil)
        #expect(body["response_format"] == nil)
        let noTools = try JSONValue(data: JSONEncoder().encode(OpenAIWire.request(model: "m", systemPrompt: "s", messages: [], tools: [], maxTokens: 10, stream: true, responseFormat: .jsonObject)))
        #expect(noTools["tools"] == nil)
        #expect(noTools["stream"]?.boolValue == true)
        #expect(noTools["stream_options"]?["include_usage"]?.boolValue == true)
        #expect(noTools["response_format"]?["type"]?.stringValue == "json_object")
    }
}

// MARK: - Responses

@Suite("OpenAIWire: responses")
struct OpenAIWireResponseTests {

    @Test("plain text and usage")
    func text() throws {
        let (response, usage) = try OpenAIWire.response(decodeResponse(textReply))
        guard case .text(let text) = response else { Issue.record("expected .text"); return }
        #expect(text == "Hello there")
        #expect(usage?.inputTokens == 12)
        #expect(usage?.outputTokens == 3)
    }

    @Test("tool_calls become ToolCalls with stringified scalars, raw JSON, and synthesized tool_use blocks")
    func toolCalls() throws {
        let (response, _) = try OpenAIWire.response(decodeResponse(toolReply))
        guard case .toolCalls(let calls, let raw) = response else { Issue.record("expected .toolCalls"); return }
        #expect(calls.count == 1)
        let call = calls[0]
        #expect(call.id == "call_abc")
        #expect(call.toolName == "read_file")
        #expect(call.arguments["path"] == "~/notes.txt")
        #expect(call.arguments["lines"] == "20")
        #expect(call.arguments["all"] == "true")
        #expect(call.arguments["ratio"] == "0.5")
        #expect(call.arguments["tags"] == #"["a","b"]"#)
        let rawInput = try JSONValue(data: #require(call.rawInputJSON))
        #expect(rawInput["lines"]?.intValue == 20)
        #expect(rawInput["tags"]?.arrayValue?.count == 2)

        #expect(raw.count == 1)
        #expect(raw[0].type == "tool_use")
        #expect(raw[0].id == "call_abc")
        #expect(raw[0].name == "read_file")
        #expect(raw[0].input?["lines"]?.intValue == 20)
        #expect(raw[0].input?["all"]?.boolValue == true)
        #expect(raw[0].input?["path"]?.stringValue == "~/notes.txt")
    }

    @Test("text plus tool calls is .mixed with the text block first")
    func mixed() throws {
        let (response, _) = try OpenAIWire.response(decodeResponse("""
        {"choices":[{"index":0,"message":{"role":"assistant","content":"Let me look.","tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{\\"text\\":\\"hi\\"}"}}]},"finish_reason":"tool_calls"}]}
        """))
        guard case .mixed(let text, let calls, let raw) = response else { Issue.record("expected .mixed"); return }
        #expect(text == "Let me look.")
        #expect(calls.map(\.toolName) == ["echo"])
        #expect(raw.map(\.type) == ["text", "tool_use"])
    }

    @Test("finish_reason length is .truncated and never a final answer")
    func truncated() throws {
        let (response, _) = try OpenAIWire.response(decodeResponse("""
        {"choices":[{"index":0,"message":{"role":"assistant","content":"The answer is","tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{\\"text\\": \\"cut mid"}}]},"finish_reason":"length"}]}
        """))
        guard case .truncated(let partial, let calls, let raw) = response else { Issue.record("expected .truncated"); return }
        #expect(partial == "The answer is")
        #expect(calls.count == 1)
        #expect(calls[0].arguments.isEmpty)       // severed JSON is not guessed at
        #expect(calls[0].rawInputJSON == nil)
        #expect(raw.map(\.type) == ["text", "tool_use"])
    }

    @Test("content_filter is a plain API error, not a Claude refusal; no choices is a decoding error")
    func filterAndEmpty() async {
        await expectLLMError("content_filter", { if case .apiError(let m) = $0 { return m.contains("content_filter") }; return false }) {
            try OpenAIWire.response(decodeResponse(#"{"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"content_filter"}]}"#))
        }
        await expectLLMError("no choices", { if case .decodingError = $0 { return true }; return false }) {
            try OpenAIWire.response(decodeResponse(#"{"choices":[]}"#))
        }
    }

    @Test("a missing tool call id is synthesized; a nameless call is dropped")
    func missingIds() throws {
        let (response, _) = try OpenAIWire.response(decodeResponse("""
        {"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"type":"function","function":{"name":"echo","arguments":"{}"}},{"type":"function","function":{"arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
        """))
        guard case .toolCalls(let calls, let raw) = response else { Issue.record("expected .toolCalls"); return }
        #expect(calls.count == 1)
        #expect(calls[0].id.hasPrefix("call_0_"))
        #expect(raw[0].id == calls[0].id)
    }

    @Test("a leading <think> block is reasoning, not the answer")
    func thinkStripped() throws {
        #expect(OpenAIWire.stripReasoning("<think>\nhmm\n</think>\n\nFinal.") == "Final.")
        #expect(OpenAIWire.stripReasoning("<think>cut off") == "")
        #expect(OpenAIWire.stripReasoning("No tags <think>inside</think>") == "No tags <think>inside</think>")
        let (response, _) = try OpenAIWire.response(decodeResponse(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"<think>x</think>Done"},"finish_reason":"stop"}]}"#))
        guard case .text(let text) = response else { Issue.record("expected .text"); return }
        #expect(text == "Done")
    }

    @Test("a three-turn tool loop survives Anthropic → OpenAI → Anthropic → OpenAI")
    func roundTrip() throws {
        // Turn 1: the model calls a tool. The loop echoes rawContent as the assistant turn.
        let (first, _) = try OpenAIWire.response(decodeResponse(toolReply))
        guard case .toolCalls(let calls, let raw) = first else { Issue.record("expected .toolCalls"); return }
        var history: [AnthropicMessage] = [AnthropicMessage(role: "user", content: .string("read my notes"))]
        history.append(AnthropicMessage(role: "assistant", content: .blocks(raw)))
        history.append(AnthropicMessage(role: "user", content: .blocks([block("tool_result", toolUseId: calls[0].id, content: "line 1\nline 2")])))

        // Turn 2: the request we would send. The echoed tool_use must come back as the same tool_call.
        let wire = OpenAIWire.messages(systemPrompt: "sys", messages: history)
        #expect(wire.map(\.role) == ["system", "user", "assistant", "tool"])
        #expect(wire[2].toolCalls?.count == 1)
        #expect(wire[2].toolCalls?[0].id == "call_abc")
        let args = try JSONValue(data: Data(#require(wire[2].toolCalls?[0].function.arguments).utf8))
        #expect(args["path"]?.stringValue == "~/notes.txt")
        #expect(args["lines"]?.intValue == 20)
        #expect(args["tags"]?.arrayValue?.count == 2)
        #expect(wire[3].toolCallId == "call_abc")

        // Turn 3: the model answers in text; the loop appends it and a follow-up question.
        let (second, _) = try OpenAIWire.response(decodeResponse(textReply))
        guard case .text(let answer) = second else { Issue.record("expected .text"); return }
        history.append(AnthropicMessage(role: "assistant", content: .string(answer)))
        history.append(AnthropicMessage(role: "user", content: .string("and the second line?")))
        let wire2 = OpenAIWire.messages(systemPrompt: "sys", messages: history)
        #expect(wire2.map(\.role) == ["system", "user", "assistant", "tool", "assistant", "user"])
        #expect(wire2[4].content == "Hello there")
    }
}

// MARK: - SSE

@Suite("OpenAIWire: SSE")
struct SSEAccumulatorTests {

    private func feed(_ lines: [String]) -> (deltas: [StreamDelta], accumulator: OpenAIWire.SSEAccumulator) {
        var accumulator = OpenAIWire.SSEAccumulator()
        var deltas: [StreamDelta] = []
        for line in lines { deltas.append(contentsOf: accumulator.feed(line: line)) }
        return (deltas, accumulator)
    }

    @Test("text and tool arguments split across chunks reassemble; usage comes from the last chunk")
    func splitChunks() throws {
        let (deltas, accumulator) = feed([
            #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"echo","arguments":"{\"te"}}]}}]}"#,
            "",
            #"data:{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"xt\": \"hi\"}"}}]}}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "",
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#,
            "",
            "data: [DONE]",
            "",
        ])
        var texts: [String] = []
        var argumentDeltas: [String] = []
        var starts: [String] = []
        for delta in deltas {
            switch delta {
            case .textDelta(let t): texts.append(t)
            case .toolUseInputDelta(let a): argumentDeltas.append(a)
            case .toolUseStart(_, let name): starts.append(name)
            default: break
            }
        }
        #expect(texts == ["Hel", "lo"])
        #expect(starts == ["echo"])
        #expect(argumentDeltas.joined() == #"{"text": "hi"}"#)
        #expect(accumulator.isDone)

        let (response, usage) = try accumulator.finish()
        guard case .mixed(let text, let calls, _) = response else { Issue.record("expected .mixed"); return }
        #expect(text == "Hello")
        #expect(calls.count == 1)
        #expect(calls[0].id == "call_1")
        #expect(calls[0].arguments["text"] == "hi")
        #expect(usage?.inputTokens == 10)
        #expect(usage?.outputTokens == 5)
    }

    @Test("a payload split over several data lines is buffered until it parses; comments are ignored")
    func multiLinePayload() throws {
        let (deltas, accumulator) = feed([
            ": keep-alive",
            "event: message",
            #"data: {"choices":[{"index":0,"#,
            #"data: "delta":{"content":"joined"}}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "",
        ])
        #expect(deltas.count == 3)   // textDelta, contentBlockStop, messageDelta
        let (response, _) = try accumulator.finish()
        guard case .text(let text) = response else { Issue.record("expected .text"); return }
        #expect(text == "joined")
    }

    @Test("finish_reason length ends as .truncated; no [DONE] is fine")
    func truncatedStream() throws {
        let (_, accumulator) = feed([
            #"data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#,
        ])
        #expect(!accumulator.isDone)
        let (response, _) = try accumulator.finish()
        guard case .truncated(let partial, _, _) = response else { Issue.record("expected .truncated"); return }
        #expect(partial == "partial")
    }
}

// MARK: - Errors

@Suite("OpenAIWire: errors")
struct OpenAIWireErrorTests {

    private func status(_ code: Int, _ body: String = "", retryAfter: Int? = nil) -> LLMError {
        OpenAIWire.error(status: code, body: Data(body.utf8), retryAfter: retryAfter, host: "127.0.0.1:11434", model: "qwen3:8b")
    }

    @Test("status codes map to the loop's errors with endpoint wording")
    func statuses() {
        if case .invalidAPIKey = status(401) {} else { Issue.record("401") }
        if case .invalidAPIKey = status(403) {} else { Issue.record("403") }
        if case .rateLimited(let after) = status(429, retryAfter: 7) { #expect(after == 7) } else { Issue.record("429") }
        if case .apiError(let m) = status(404, #"{"error":"model 'qwen3:8b' not found"}"#) { #expect(m == "model 'qwen3:8b' not found") } else { Issue.record("404 body") }
        if case .apiError(let m) = status(404) { #expect(m.contains("qwen3:8b")) } else { Issue.record("404") }
        if case .contextOverflow = status(400, #"{"error":{"message":"This model's maximum context length is 8192 tokens"}}"#) {} else { Issue.record("400 overflow") }
        if case .apiError(let m) = status(400, #"{"error":{"message":"invalid tool schema"}}"#) { #expect(m == "invalid tool schema") } else { Issue.record("400") }
        if case .apiError(let m) = status(503, "upstream down") { #expect(m.contains("503") && m.contains("127.0.0.1:11434") && m.contains("upstream down")) } else { Issue.record("503") }
        if case .apiError(let m) = status(500) { #expect(m == "127.0.0.1:11434 returned HTTP 500") } else { Issue.record("500") }
    }

    @Test("error bodies of every common shape yield a message; HTML and empty bodies yield none")
    func bodies() {
        #expect(OpenAIWire.errorMessage(from: Data(#"{"error":{"message":"bad","type":"invalid_request_error"}}"#.utf8)) == "bad")
        #expect(OpenAIWire.errorMessage(from: Data(#"{"error":"plain"}"#.utf8)) == "plain")
        #expect(OpenAIWire.errorMessage(from: Data(#"{"detail":"fastapi"}"#.utf8)) == "fastapi")
        #expect(OpenAIWire.errorMessage(from: Data(#"{"detail":[{"loc":["body"],"msg":"field required"}]}"#.utf8)) == "field required")
        #expect(OpenAIWire.errorMessage(from: Data(#"{"message":"top"}"#.utf8)) == "top")
        #expect(OpenAIWire.errorMessage(from: Data("  plain text  ".utf8)) == "plain text")
        #expect(OpenAIWire.errorMessage(from: Data("<html>502</html>".utf8)) == nil)
        #expect(OpenAIWire.errorMessage(from: Data()) == nil)
        #expect(OpenAIWire.errorMessage(from: Data(#"{"error":{"message":"\#(String(repeating: "x", count: 400))"}}"#.utf8))?.count == 301)
    }

    @Test("transport failures: Stop is cancellation; a refused loopback connection says the server is down")
    func network() {
        #expect(OpenAIWire.networkError(URLError(.cancelled), isLocal: true, host: "h") is CancellationError)
        if case .networkError(let m) = OpenAIWire.networkError(URLError(.cannotConnectToHost), isLocal: true, host: "127.0.0.1:11434") as? LLMError {
            #expect(m.contains("not running") && m.contains("127.0.0.1:11434"))
        } else { Issue.record("local refused") }
        if case .networkError(let m) = OpenAIWire.networkError(URLError(.cannotConnectToHost), isLocal: false, host: "api.fireworks.ai") as? LLMError {
            #expect(m.hasPrefix("Cannot reach api.fireworks.ai"))
        } else { Issue.record("remote refused") }
        if case .noInternet = OpenAIWire.networkError(URLError(.notConnectedToInternet), isLocal: false, host: "h") as? LLMError {} else { Issue.record("remote offline") }
        if case .networkError(let m) = OpenAIWire.networkError(URLError(.notConnectedToInternet), isLocal: true, host: "h") as? LLMError {
            #expect(m.contains("not running"))
        } else { Issue.record("local offline") }
        if case .networkError(let m) = OpenAIWire.networkError(URLError(.timedOut), isLocal: false, host: "h") as? LLMError { #expect(m.contains("timed out")) } else { Issue.record("timeout") }
    }
}

// MARK: - Tier settings

@Suite("Tier endpoints and settings")
struct TierSettingsTests {

    @Test("base URLs are normalized: scheme added, /v1 appended to a bare origin, trailing slash dropped")
    func normalize() {
        #expect(TierEndpoint.normalizedURL("http://127.0.0.1:11434/v1")?.absoluteString == "http://127.0.0.1:11434/v1")
        #expect(TierEndpoint.normalizedURL("http://127.0.0.1:11434/v1/")?.absoluteString == "http://127.0.0.1:11434/v1")
        #expect(TierEndpoint.normalizedURL("127.0.0.1:11434")?.absoluteString == "http://127.0.0.1:11434/v1")
        #expect(TierEndpoint.normalizedURL("localhost:1234/")?.absoluteString == "http://localhost:1234/v1")
        #expect(TierEndpoint.normalizedURL("https://api.fireworks.ai/inference/v1")?.absoluteString == "https://api.fireworks.ai/inference/v1")
        #expect(TierEndpoint.normalizedURL("https://api.together.xyz?x=1")?.absoluteString == "https://api.together.xyz/v1")
        #expect(TierEndpoint.normalizedURL("") == nil)
        #expect(TierEndpoint.normalizedURL("ftp://x") == nil)
        #expect(TierEndpoint.normalizedURL("http://") == nil)
    }

    @Test("loopback detection")
    func loopback() {
        #expect(TierEndpoint(baseURL: "http://127.0.0.1:11434/v1", model: "m").isLocal)
        #expect(TierEndpoint(baseURL: "http://localhost:1234", model: "m").isLocal)
        #expect(TierEndpoint(baseURL: "http://[::1]:8080/v1", model: "m").isLocal)
        #expect(!TierEndpoint(baseURL: "https://api.fireworks.ai/inference/v1", model: "m").isLocal)
        #expect(!TierEndpoint(baseURL: "http://100.101.102.103:11434/v1", model: "m").isLocal)
        #expect(!TierEndpoint(baseURL: "http://127.0.0.1:11434/v1", model: "").isConfigured)
        #expect(TierEndpoint(baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b").isConfigured)
    }

    @Test("the store round-trips both tiers, keeps the P key in the secret store, and never wipes it on an empty save")
    func store() throws {
        let suite = "MajoorTests.TierSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecrets()
        let store = TierSettingsStore(defaults: defaults, secrets: secrets)

        #expect(store.endpoint(for: .frontier) == nil)
        #expect(store.endpoint(for: .local) == TierEndpoint(baseURL: TierSettingsStore.localDefaultBaseURL, model: ""))
        #expect(store.provider(for: .local) == nil)
        #expect(store.routingOverride == nil)

        store.save(TierEndpoint(baseURL: " http://127.0.0.1:1234 ", model: " qwen3:8b "), for: .local)
        let local = try #require(store.provider(for: .local))
        #expect(local.tier == .local)
        #expect(local.model == "qwen3:8b")
        #expect(local.baseURL.absoluteString == "http://127.0.0.1:1234/v1")
        #expect(local.isLocal)
        #expect(local.name == "Local · qwen3:8b")

        store.save(TierEndpoint(baseURL: "https://api.fireworks.ai/inference/v1", model: "accounts/fireworks/models/llama-v3p3-70b", apiKey: "fw-secret"), for: .privateCloud)
        #expect(secrets.secret(for: TierSettingsStore.keychainPrivateKey) == "fw-secret")
        #expect(store.hasPrivateKey)
        #expect(store.endpoint(for: .privateCloud)?.apiKey == "fw-secret")
        store.save(TierEndpoint(baseURL: "https://api.fireworks.ai/inference/v1", model: "other", apiKey: ""), for: .privateCloud)
        #expect(store.endpoint(for: .privateCloud)?.apiKey == "fw-secret")
        #expect(store.endpoint(for: .privateCloud)?.model == "other")
        store.removePrivateKey()
        #expect(!store.hasPrivateKey)

        #expect(!store.privateRetentionVerified)
        store.privateRetentionVerified = true
        #expect(store.privateRetentionVerified)

        store.routingOverride = .frontier
        #expect(store.routingOverride == nil)
        store.routingOverride = .privateCloud
        #expect(store.routingOverride == .privateCloud)
        #expect(store.overrideProvider()?.tier == .privateCloud)
        store.save(TierEndpoint(baseURL: "", model: ""), for: .privateCloud)
        #expect(store.overrideProvider() == nil)   // set but unconfigured: route normally
        store.routingOverride = nil
        #expect(defaults.string(forKey: TierSettingsStore.routingOverrideKey) == nil)
    }

    @Test("non-Claude models carry no price until the tier table exists")
    func cost() {
        #expect(CostConfig.estimateCost(model: "qwen3:8b", inputTokens: 1_000_000, outputTokens: 1_000_000) == 0)
        #expect(CostConfig.estimateCost(model: ModelRouter.sonnetModel, inputTokens: 1_000_000, outputTokens: 0) == CostConfig.sonnetInput)
    }
}

// MARK: - HTTP

@Suite("OpenAICompatibleProvider over loopback HTTP")
struct OpenAICompatibleProviderTests {

    private func provider(_ server: FakeHTTPServer, model: String = "qwen3:8b", apiKey: String = "", tier: ProviderTier = .local) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(tier: tier, baseURL: server.baseURL, model: model, apiKey: apiKey, maxTokens: 512, maxRetries: 2, retryBaseDelay: 0.01)
    }

    @Test("complete posts the translated request and returns the parsed tool call")
    func complete() async throws {
        let server = try FakeHTTPServer { request in
            guard request.method == "POST", request.path == "/v1/chat/completions" else { return FakeHTTPServer.Reply(status: 404, body: "{}") }
            return FakeHTTPServer.Reply(body: toolReply)
        }
        try await server.start()
        defer { server.stop() }

        let tool = EchoTool().toAnthropicTool()
        let (response, usage) = try await provider(server).complete(systemPrompt: "sys", messages: [AnthropicMessage(role: "user", content: .string("read it"))], tools: [tool])
        guard case .toolCalls(let calls, _) = response else { Issue.record("expected .toolCalls"); return }
        #expect(calls[0].toolName == "read_file")
        #expect(usage?.inputTokens == 40)

        let sent = try #require(server.requests.first)
        #expect(sent.headers["authorization"] == nil)
        #expect(sent.headers["content-type"] == "application/json")
        let body = try #require(sent.json)
        #expect(body["model"]?.stringValue == "qwen3:8b")
        #expect(body["max_tokens"]?.intValue == 512)
        #expect(body["stream"] == nil)
        #expect(body["messages"]?.arrayValue?.map { $0["role"]?.stringValue } == ["system", "user"])
        #expect(body["tools"]?.arrayValue?.first?["function"]?["name"]?.stringValue == "echo")
    }

    @Test("a key becomes a bearer token; 401 is invalidAPIKey without retries")
    func unauthorized() async throws {
        let server = try FakeHTTPServer { _ in FakeHTTPServer.Reply(status: 401, body: #"{"error":{"message":"bad key"}}"#) }
        try await server.start()
        defer { server.stop() }
        await expectLLMError("401", { if case .invalidAPIKey = $0 { return true }; return false }) {
            try await provider(server, apiKey: "sk-test", tier: .privateCloud).complete(systemPrompt: "", messages: [AnthropicMessage(role: "user", content: .string("x"))], tools: [])
        }
        #expect(server.requests.count == 1)
        #expect(server.requests.first?.headers["authorization"] == "Bearer sk-test")
    }

    @Test("a 500 is retried and the retry succeeds; three 503s give up with the endpoint's message")
    func retries() async throws {
        let counter = Counter()
        let server = try FakeHTTPServer { _ in
            counter.next() == 1 ? FakeHTTPServer.Reply(status: 500, body: "boom") : FakeHTTPServer.Reply(body: textReply)
        }
        try await server.start()
        defer { server.stop() }
        let (response, _) = try await provider(server).complete(systemPrompt: "", messages: [AnthropicMessage(role: "user", content: .string("x"))], tools: [])
        guard case .text(let text) = response else { Issue.record("expected .text"); return }
        #expect(text == "Hello there")
        #expect(server.requests.count == 2)

        let down = try FakeHTTPServer { _ in FakeHTTPServer.Reply(status: 503, body: "overloaded") }
        try await down.start()
        defer { down.stop() }
        await expectLLMError("503", { if case .apiError(let m) = $0 { return m.contains("503") && m.contains("overloaded") }; return false }) {
            try await provider(down).complete(systemPrompt: "", messages: [AnthropicMessage(role: "user", content: .string("x"))], tools: [])
        }
        #expect(down.requests.count == 3)
    }

    @Test("a loopback server that is not running is reported as such, immediately")
    func notRunning() async throws {
        let port = try await closedPort()
        let provider = OpenAICompatibleProvider(tier: .local, baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!, model: "m", retryBaseDelay: 0.01)
        let started = ContinuousClock.now
        await expectLLMError("refused", { if case .networkError(let m) = $0 { return m.contains("not running") && m.contains("127.0.0.1:\(port)") }; return false }) {
            try await provider.complete(systemPrompt: "", messages: [AnthropicMessage(role: "user", content: .string("x"))], tools: [])
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("stream asks for SSE, forwards text deltas, and returns the assembled turn with usage")
    func stream() async throws {
        let sse = """
        data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}

        data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"echo","arguments":"{\\"te"}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"xt\\": \\"hi\\"}"}}]}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}

        data: [DONE]

        """
        let server = try FakeHTTPServer { _ in FakeHTTPServer.Reply(contentType: "text/event-stream", body: sse) }
        try await server.start()
        defer { server.stop() }

        let texts = LockedStrings()
        let (response, usage) = try await provider(server).stream(systemPrompt: "sys", messages: [AnthropicMessage(role: "user", content: .string("hi"))], tools: []) { delta in
            if case .textDelta(let t) = delta { texts.append(t) }
        }
        #expect(texts.all == ["Hel", "lo"])
        guard case .mixed(let text, let calls, _) = response else { Issue.record("expected .mixed"); return }
        #expect(text == "Hello")
        #expect(calls[0].arguments["text"] == "hi")
        #expect(usage?.outputTokens == 5)
        let body = try #require(server.requests.first?.json)
        #expect(body["stream"]?.boolValue == true)
        #expect(body["stream_options"]?["include_usage"]?.boolValue == true)
        #expect(server.requests.first?.headers["accept"] == "text/event-stream")
    }

    @Test("listModels and probe read GET /v1/models")
    func models() async throws {
        let server = try FakeHTTPServer { request in
            guard request.method == "GET", request.path == "/v1/models" else { return FakeHTTPServer.Reply(status: 404, body: "{}") }
            return FakeHTTPServer.Reply(body: #"{"object":"list","data":[{"id":"qwen3:8b","object":"model"},{"id":"gemma3:12b","object":"model"}]}"#)
        }
        try await server.start()
        defer { server.stop() }
        #expect(try await provider(server).listModels() == ["gemma3:12b", "qwen3:8b"])
        let probe = try await OpenAICompatibleProvider.probe(baseURL: server.baseURL, apiKey: "")
        #expect(probe.models.count == 2)
        #expect(probe.latency >= 0 && probe.latency < 5)
    }

    @Test("completeJSON asks for json_object, retries once on prose, and sums usage")
    func structured() async throws {
        let counter = Counter()
        let server = try FakeHTTPServer { _ in
            let content = counter.next() == 1 ? "Sure! Here you go." : #"```json\n{\"urgency\": 2, \"reason\": \"deadline\"}\n```"#
            return FakeHTTPServer.Reply(body: #"{"choices":[{"index":0,"message":{"role":"assistant","content":"\#(content)"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":5}}"#)
        }
        try await server.start()
        defer { server.stop() }
        let (value, usage) = try await provider(server).completeJSON(systemPrompt: "Classify.", messages: [AnthropicMessage(role: "user", content: .string("The server is down!"))])
        #expect(value["urgency"]?.intValue == 2)
        #expect(usage?.inputTokens == 10)
        #expect(server.requests.count == 2)
        let first = try #require(server.requests.first?.json)
        #expect(first["response_format"]?["type"]?.stringValue == "json_object")
        let second = try #require(server.requests.last?.json)
        #expect(second["messages"]?.arrayValue?.count == 4)   // system, user, the prose, the nudge
        #expect(second["messages"]?.arrayValue?.last?["content"]?.stringValue?.contains("exactly one JSON object") == true)
    }

    @Test("parseJSONObject tolerates fences and prose, rejects non-objects")
    func parse() {
        #expect(OpenAICompatibleProvider.parseJSONObject(#"{"a":1}"#)?["a"]?.intValue == 1)
        #expect(OpenAICompatibleProvider.parseJSONObject("```json\n{\"a\": [1,2]}\n```")?["a"]?.arrayValue?.count == 2)
        #expect(OpenAICompatibleProvider.parseJSONObject("Here: {\"a\":{\"b\":true}} done")?["a"]?["b"]?.boolValue == true)
        #expect(OpenAICompatibleProvider.parseJSONObject("[1,2]") == nil)
        #expect(OpenAICompatibleProvider.parseJSONObject("nothing") == nil)
        #expect(OpenAICompatibleProvider.parseJSONObject("{broken") == nil)
    }
}

nonisolated final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

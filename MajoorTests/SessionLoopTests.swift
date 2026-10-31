// SessionLoopTests.swift
// MajoorTests — the session runtime end to end with a scripted provider.
//
// AgentLoop runs for real (routing, memory injection, tool dispatch,
// approvals, budget, iteration cap); only the model is scripted.

import Foundation
import Testing
@testable import Majoor

/// Returns canned responses in order; the last one repeats.
nonisolated final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let name = "Scripted"
    let model = "scripted-model"
    private let lock = NSLock()
    private var script: [LLMResponse]
    private let usage: AnthropicUsage?
    private let delay: Duration?
    private var callCount = 0

    init(_ script: [LLMResponse], usage: AnthropicUsage? = nil, delay: Duration? = nil) {
        self.script = script
        self.usage = usage
        self.delay = delay
    }

    var calls: Int { lock.withLock { callCount } }

    func complete(systemPrompt: String, messages: [AnthropicMessage], tools: [AnthropicTool]) async throws -> (response: LLMResponse, usage: AnthropicUsage?) {
        if let delay { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        return lock.withLock {
            callCount += 1
            let response = script.count > 1 ? script.removeFirst() : (script.first ?? .text("done"))
            return (response, usage)
        }
    }
}

nonisolated struct EchoTool: AgentTool {
    let name = "echo"
    let description = "Echoes text"
    let parameters = [ToolParameter(name: "text", description: "Text to echo")]
    let requiredParameters = ["text"]
    let requiresConfirmation: Bool
    let isReadOnly: Bool

    init(requiresConfirmation: Bool = false) {
        self.requiresConfirmation = requiresConfirmation
        self.isReadOnly = !requiresConfirmation
    }

    func execute(arguments: [String: String]) async throws -> ToolResult {
        ToolResult(success: true, output: "echo: \(arguments["text"] ?? "")")
    }
}

nonisolated func echoCall(_ text: String) -> LLMResponse {
    let id = "call-" + UUID().uuidString
    return .toolCalls(
        [ToolCall(id: id, toolName: "echo", arguments: ["text": text], rawInputJSON: nil)],
        rawContent: [AnthropicContentBlock(type: "tool_use", text: nil, id: id, name: "echo", input: nil, toolUseId: nil, content: nil, isError: nil)])
}

nonisolated final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TaskSnapshot] = []
    func append(_ snapshot: TaskSnapshot) { lock.withLock { items.append(snapshot) } }
    var all: [TaskSnapshot] { lock.withLock { items } }
}

/// Polls until the condition holds or the timeout passes.
func waitUntil(timeout: Duration = .seconds(15), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return await condition()
}

@MainActor
func withPermissionMode<T>(_ mode: PermissionMode, _ body: () async throws -> T) async rethrows -> T {
    let previous = UserDefaults.standard.string(forKey: PermissionMode.defaultsKey)
    UserDefaults.standard.set(mode.rawValue, forKey: PermissionMode.defaultsKey)
    defer { UserDefaults.standard.set(previous, forKey: PermissionMode.defaultsKey) }
    return try await body()
}

func makeManager(route: @escaping ProviderRouter, tool: EchoTool = EchoTool(), maxConcurrent: Int = 3,
                 approvalTimeout: TimeInterval = 600, persist: SnapshotBox? = nil) async -> SessionManager {
    let manager = SessionManager()
    let loop = AgentLoop(tools: [tool], route: route)
    var persistClosure: (@Sendable (TaskSnapshot) -> Void)? = nil
    if let persist {
        persistClosure = { snapshot in persist.append(snapshot) }
    }
    await manager.configure(loop: loop, store: nil, persistTask: persistClosure,
                            notify: nil, maxConcurrent: maxConcurrent, approvalTimeout: approvalTimeout)
    return manager
}

func terminal(_ manager: SessionManager, _ id: SessionID) async -> SessionInfo? {
    let done = await waitUntil { (await manager.list().first { $0.id == id })?.state.isTerminal == true }
    return done ? await manager.list().first { $0.id == id } : nil
}

@Suite("Session runtime", .serialized)
struct SessionLoopTests {

    @Test("a plain answer completes the session, persists a snapshot, and seeds thread history")
    func completes() async throws {
        try await withPermissionMode(.standard) {
            let box = SnapshotBox()
            let provider = ScriptedProvider([.text("Hello world. Longer explanation follows.")])
            let manager = await makeManager(route: { _ in (provider, []) }, persist: box)
            let info = try #require(await manager.submit(input: "say hello", origin: .panel, trust: .local))
            let final = try #require(await terminal(manager, info.id))
            #expect(final.state == .completed)
            #expect(final.summary == "Hello world")
            #expect(provider.calls == 1)
            #expect(box.all.count == 1)
            #expect(box.all.first?.status == .completed)
            #expect(manager.history.snapshot(thread: "panel").map(\.userInput) == ["say hello"])
        }
    }

    @Test("a tool call runs and its result feeds the next turn")
    func toolThenAnswer() async throws {
        try await withPermissionMode(.standard) {
            let box = SnapshotBox()
            let provider = ScriptedProvider([echoCall("ping"), .text("Echoed.")])
            let manager = await makeManager(route: { _ in (provider, []) }, persist: box)
            let info = try #require(await manager.submit(input: "echo ping", origin: .panel, trust: .local))
            let final = try #require(await terminal(manager, info.id))
            #expect(final.state == .completed)
            #expect(provider.calls == 2)
            let types = box.all.first?.steps.map(\.type) ?? []
            #expect(types.contains("toolCall"))
            #expect(types.contains("toolResult"))
            #expect(box.all.first?.steps.first { $0.type == "toolResult" }?.detail == "echo: ping")
        }
    }

    @Test("two sessions wait for approval independently; answering one leaves the other pending")
    func concurrentApprovals() async throws {
        try await withPermissionMode(.standard) {
            let a = ScriptedProvider([echoCall("a"), .text("A done")])
            let b = ScriptedProvider([echoCall("b"), .text("B done")])
            let manager = await makeManager(route: { input in input.hasPrefix("A") ? (a, []) : (b, []) },
                                            tool: EchoTool(requiresConfirmation: true))
            let infoA = try #require(await manager.submit(input: "A task", origin: .panel, trust: .local))
            let infoB = try #require(await manager.submit(input: "B task", origin: .panel, trust: .local))
            #expect(await waitUntil { await manager.pendingApprovals().count == 2 })
            let pending = await manager.pendingApprovals()
            let requestA = try #require(pending.first { $0.sessionId == infoA.id })
            #expect(requestA.riskClass == .r3)
            #expect(requestA.nonce.count == 4)

            let result = await manager.answerApproval(id: requestA.id, nonce: requestA.nonce, decision: ApprovalDecision(approved: true), byChannel: "test")
            #expect(result == .ok)
            let finalA = try #require(await terminal(manager, infoA.id))
            #expect(finalA.state == .completed)
            #expect(await manager.pendingApprovals().map(\.sessionId) == [infoB.id])

            let requestB = try #require(await manager.pendingApprovals().first)
            _ = await manager.answerApproval(id: requestB.id, nonce: requestB.nonce.lowercased(), decision: ApprovalDecision(approved: false, feedback: "no"), byChannel: "test")
            let finalB = try #require(await terminal(manager, infoB.id))
            #expect(finalB.state == .completed)
        }
    }

    @Test("a wrong code does not resolve; five wrong codes deny; a resolved approval is unknown afterwards")
    func nonces() async throws {
        try await withPermissionMode(.standard) {
            let provider = ScriptedProvider([echoCall("x"), .text("after")])
            let manager = await makeManager(route: { _ in (provider, []) }, tool: EchoTool(requiresConfirmation: true))
            let info = try #require(await manager.submit(input: "guarded", origin: .panel, trust: .local))
            #expect(await waitUntil { await manager.pendingApprovals().count == 1 })
            let request = try #require(await manager.pendingApprovals().first)

            #expect(await manager.answerApproval(id: request.id, nonce: "ZZZZ", decision: ApprovalDecision(approved: true), byChannel: "t") == .badNonce)
            #expect(await manager.pendingApprovals().count == 1)
            #expect(await manager.answerApproval(id: "nope", nonce: request.nonce, decision: ApprovalDecision(approved: true), byChannel: "t") == .unknownId)
            for _ in 0..<3 {
                #expect(await manager.answerApproval(id: request.id, nonce: "0000", decision: ApprovalDecision(approved: true), byChannel: "t") == .badNonce)
            }
            #expect(await manager.answerApproval(id: request.id, nonce: "0000", decision: ApprovalDecision(approved: true), byChannel: "t") == .tooManyAttempts)
            #expect(await manager.pendingApprovals().isEmpty)
            #expect(await manager.answerApproval(id: request.id, nonce: request.nonce, decision: ApprovalDecision(approved: true), byChannel: "t") == .unknownId)

            let final = try #require(await terminal(manager, info.id))
            #expect(final.state == .completed)   // denied tool result, then the scripted answer
            #expect(provider.calls == 2)
        }
    }

    @Test("an approval that expires is denied and the loop continues")
    func expiry() async throws {
        try await withPermissionMode(.standard) {
            let box = SnapshotBox()
            let provider = ScriptedProvider([echoCall("x"), .text("moved on")])
            let manager = await makeManager(route: { _ in (provider, []) }, tool: EchoTool(requiresConfirmation: true),
                                            approvalTimeout: 0.3, persist: box)
            let info = try #require(await manager.submit(input: "slow approver", origin: .panel, trust: .local))
            let final = try #require(await terminal(manager, info.id))
            #expect(final.state == .completed)
            let declined = box.all.first?.steps.first { $0.description == "Declined: echo" }
            #expect(declined?.detail == "Approval expired")
        }
    }

    @Test("STOP ends a running, a waiting and a queued session without leaving anything pending")
    func stopAll() async throws {
        try await withPermissionMode(.standard) {
            let slow = ScriptedProvider([.text("never")], delay: .seconds(30))
            let waiting = ScriptedProvider([echoCall("w"), .text("w done")])
            let queued = ScriptedProvider([.text("q")])
            let manager = await makeManager(
                route: { input in input.hasPrefix("slow") ? (slow, []) : input.hasPrefix("wait") ? (waiting, []) : (queued, []) },
                tool: EchoTool(requiresConfirmation: true), maxConcurrent: 2)
            let a = try #require(await manager.submit(input: "slow one", origin: .panel, trust: .local))
            let b = try #require(await manager.submit(input: "wait one", origin: .panel, trust: .local))
            let c = try #require(await manager.submit(input: "queued one", origin: .panel, trust: .local))
            #expect(await waitUntil { await manager.pendingApprovals().count == 1 })
            #expect(await manager.list().first { $0.id == c.id }?.state == .queued)

            await manager.stopAll()
            for id in [a.id, b.id, c.id] {
                let final = try #require(await terminal(manager, id))
                #expect(final.state == .stopped, "session \(final.shortId) ended \(final.state)")
            }
            #expect(await manager.pendingApprovals().isEmpty)
            #expect(queued.calls == 0)
        }
    }

    @Test("crossing the session token budget fails the run honestly")
    func budget() async throws {
        try await withPermissionMode(.standard) {
            let previous = UserDefaults.standard.integer(forKey: TokenBudget.sessionTokensKey)
            UserDefaults.standard.set(5_000, forKey: TokenBudget.sessionTokensKey)
            defer { UserDefaults.standard.set(previous, forKey: TokenBudget.sessionTokensKey) }
            let provider = ScriptedProvider([echoCall("loop")], usage: AnthropicUsage(inputTokens: 3_000, outputTokens: 0))
            let manager = await makeManager(route: { _ in (provider, []) })
            let info = try #require(await manager.submit(input: "burn", origin: .panel, trust: .local))
            let final = try #require(await terminal(manager, info.id))
            #expect(final.state == .failed)
            #expect(final.summary == IncompleteReason.budgetExceeded.userFacing)
            #expect(provider.calls == 2)
        }
    }

    @Test("the iteration cap still ends as a failure, never a success")
    func iterationCap() async throws {
        try await withPermissionMode(.standard) {
            let provider = ScriptedProvider([echoCall("again")])
            let manager = await makeManager(route: { _ in (provider, []) })
            let info = try #require(await manager.submit(input: "forever", origin: .panel, trust: .local))
            let final = try #require(await terminal(manager, info.id))
            #expect(final.state == .failed)
            #expect(final.summary == IncompleteReason.iterationLimit.userFacing)
            #expect(provider.calls == 75)
            #expect(manager.history.snapshot(thread: "panel").first?.responseText.contains("stopped after 75 iterations") == true)
        }
    }

    @Test("inbound commands: stop, /status, /stop N; everything else is a task")
    func inbound() async throws {
        try await withPermissionMode(.standard) {
            let provider = ScriptedProvider([.text("ok")])
            let manager = await makeManager(route: { _ in (provider, []) })
            if case .status(let text) = await manager.handleInbound("/status", origin: .panel, trust: .local) {
                #expect(text == "Nothing running.")
            } else { Issue.record("expected status") }
            if case .nothingToStop = await manager.handleInbound("/stop 9", origin: .panel, trust: .local) {} else { Issue.record("expected nothingToStop") }
            if case .submitted(let info) = await manager.handleInbound("stop the build and tell me", origin: .panel, trust: .local) {
                _ = await terminal(manager, info.id)
            } else { Issue.record("expected a task") }
            if case .stopped(let count) = await manager.handleInbound("STOP", origin: .panel, trust: .local) {
                #expect(count == 0)
            } else { Issue.record("expected stopped") }
        }
    }

    @Test("remote text never runs in Auto mode")
    func remoteTrustDowngrade() async throws {
        try await withPermissionMode(.auto) {
            let provider = ScriptedProvider([.text("ok")])
            let manager = await makeManager(route: { _ in (provider, []) })
            let remote = try #require(await manager.submit(input: "from phone", origin: ChannelRef(channelId: "imessage", threadKey: "imessage:x"), trust: .remoteText))
            let local = try #require(await manager.submit(input: "from panel", origin: .panel, trust: .local))
            #expect(await manager.session(shortId: remote.shortId)?.effectiveMode == .standard)
            #expect(await manager.session(shortId: local.shortId)?.effectiveMode == .auto)
            _ = await terminal(manager, remote.id)
            _ = await terminal(manager, local.id)
        }
    }
}

@Suite("InboundCommand")
struct InboundCommandTests {
    @Test("exact forms only", arguments: [
        ("stop", InboundCommand.stopAll), ("STOP", .stopAll), ("  stop \n", .stopAll),
        ("/status", .status), ("/stop", .stop(nil)), ("/stop 3", .stop(3)), ("/STOP 12", .stop(12)),
        ("stop the build", .none), ("/stop abc", .none), ("/stop 0", .none), ("/stop 3 now", .none),
        ("/etc/hosts", .none), ("please stop", .none), ("status", .none),
    ] as [(String, InboundCommand)])
    func parse(input: String, expected: InboundCommand) {
        #expect(InboundCommand.parse(input) == expected)
    }
}

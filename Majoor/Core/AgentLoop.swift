// AgentLoop.swift
// Majoor — The Agent Loop (THE BRAIN)
//
// Cycle: Send to Claude → Claude returns tool calls → Execute locally → Send results back → Repeat
// Now with: memory injection, model routing, task persistence, usage tracking.
// Nonisolated — the loop runs off the main thread. UI updates go through MainActor.run.

import Foundation

final nonisolated class AgentLoop: @unchecked Sendable {

    private let tools: [any AgentTool]
    private let taskManager: TaskManager
    private let maxIterations = 25
    private let conversationTimeoutSeconds: TimeInterval = 600 // 10 minutes

    /// Stores conversation history for continuity
    private struct ConversationContext: @unchecked Sendable {
        let userInput: String
        let responseText: String
        let toolSummaries: [String]
        let timestamp: Date
    }
    private var conversationHistory: [ConversationContext] = []

    private let systemPrompt = """
    You are Majoor, an autonomous AI agent running as a native macOS menu bar app. \
    You perform tasks on the user's computer using your tools — silently, efficiently, and safely.

    YOUR CAPABILITIES:
    - File management: list, read, write, move, copy, delete, search files and create directories
    - Shell execution: run any shell command or script (Python, Node, Ruby, Bash) on the user's machine
    - Git & GitHub: check status, view diffs/logs, create branches, commit, push, and open PRs via gh CLI
    - Web research: search the web (Tavily), fetch and extract text from webpages, batch-fetch URLs for comparison
    - Project analysis: read project structure trees, run test suites with auto-detection
    - Calendar: read, create, update, and delete calendar events via Apple Calendar (EventKit)
    - Email: fetch, read, search, draft, send, and reply to emails via Gmail API

    RULES:
    1. Be autonomous — complete the full task without asking unnecessary questions. Break complex tasks into steps and execute them.
    2. Be efficient — use the minimum tool calls needed. Combine steps when possible (e.g., don't list a directory just to read a file you already know the path to).
    3. Be safe — never delete files without stating what will be deleted. Destructive shell commands are blocked. Never access files outside ~/ unless explicitly asked.
    4. Be clear — when done, give a concise summary of what you did and the outcome. Don't be verbose.
    5. Use the right tool — prefer specific tools over shell commands (e.g., use read_file instead of execute_shell with cat). Use execute_shell for build tools, package managers, and commands that don't have a dedicated tool.
    6. Handle errors gracefully — if a tool fails, try an alternative approach before giving up. Report what went wrong clearly.
    7. Git safety — always create an agent/ prefixed branch for changes. Never commit directly to main, master, or develop. Write clear commit messages.
    8. Web research — when searching, synthesize results into a useful answer. Don't just dump raw search results. Fetch specific pages when you need deeper detail.
    9. Code changes — read the existing code first before modifying. Make minimal, focused changes. Run tests if a test command is available.
    10. File paths — support ~ for home directory. When the user mentions a relative path, assume it's relative to their home directory.
    11. Email safety — NEVER send an email without using the send_email or reply_to_email tools, which trigger user confirmation via notification. Always show the user what you're about to send. If only drafting, use draft_email which saves but doesn't send.
    12. Calendar — when the user asks about their schedule, use read_calendar_events. For creating events, always confirm the date/time before calling create_calendar_event.
    """

    init(tools: [any AgentTool], taskManager: TaskManager) {
        self.tools = tools
        self.taskManager = taskManager
    }

    func execute(userInput: String) async throws -> TaskResult {
        MajoorLogger.log("🚀 Task: \(userInput)")

        // 1. Classify task and route to the right model
        let category = TaskClassifier.classify(userInput)
        let provider = ModelRouter.provider(for: category)

        // 2. Retrieve relevant memories
        let memoryContext = MemoryRetriever.relevantContext(for: userInput)
        let fullSystemPrompt = systemPrompt + memoryContext

        // 3. Create task and add to UI
        let task = AgentTask(userInput: userInput)
        await MainActor.run { taskManager.addTask(task) }

        // 4. Build messages — inject all conversations from the last 10 minutes
        var messages: [AnthropicMessage] = []
        let now = Date()
        let recentConversations = conversationHistory.filter {
            now.timeIntervalSince($0.timestamp) < conversationTimeoutSeconds
        }
        if !recentConversations.isEmpty {
            MajoorLogger.log("📎 Injecting \(recentConversations.count) recent conversation(s) as context")
            for prev in recentConversations {
                messages.append(AnthropicMessage(role: "user", content: .string(prev.userInput)))
                var recap = prev.responseText
                if !prev.toolSummaries.isEmpty {
                    let toolContext = prev.toolSummaries.prefix(10).joined(separator: "\n")
                    recap = "Actions taken:\n\(toolContext)\n\nResponse: \(prev.responseText)"
                }
                messages.append(AnthropicMessage(role: "assistant", content: .string(recap)))
            }
        }
        messages.append(AnthropicMessage(role: "user", content: .string(userInput)))
        let anthropicTools = tools.map { $0.toAnthropicTool() }

        var totalInputTokens = 0
        var totalOutputTokens = 0
        var iteration = 0
        var finalText = ""
        var toolSummaries: [String] = []

        // 5. Agent loop
        while iteration < maxIterations {
            iteration += 1
            MajoorLogger.log("🔄 Iteration \(iteration)/\(maxIterations) [\(provider.name)]")

            let thinkStep = TaskStep(timestamp: Date(), type: .thinking, description: "Thinking... (\(iteration))", detail: nil)
            await MainActor.run { task.steps.append(thinkStep) }

            // API call with error recovery — provider handles retries internally,
            // but if all retries are exhausted, we catch it here so the task
            // gets marked as failed instead of hanging forever.
            let response: LLMResponse
            let usage: AnthropicUsage?
            do {
                (response, usage) = try await provider.complete(
                    systemPrompt: fullSystemPrompt,
                    messages: messages,
                    tools: anthropicTools
                )
            } catch let error as LLMError {
                MajoorLogger.error("❌ API call failed after retries: \(error.localizedDescription ?? "unknown")")
                let errorStep = TaskStep(timestamp: Date(), type: .error, description: error.localizedDescription ?? "API error", detail: nil)
                let totalTokens = totalInputTokens + totalOutputTokens
                await MainActor.run {
                    task.steps.append(errorStep)
                    task.status = .failed
                    task.summary = error.localizedDescription ?? "Task failed"
                    task.completedAt = Date()
                    task.tokensUsed = totalTokens
                    task.modelUsed = provider.name
                }
                await MainActor.run { taskManager.persistTask(task) }
                throw error
            } catch {
                MajoorLogger.error("❌ Unexpected error: \(error.localizedDescription)")
                let errorStep = TaskStep(timestamp: Date(), type: .error, description: error.localizedDescription, detail: nil)
                let totalTokens = totalInputTokens + totalOutputTokens
                await MainActor.run {
                    task.steps.append(errorStep)
                    task.status = .failed
                    task.summary = error.localizedDescription
                    task.completedAt = Date()
                    task.tokensUsed = totalTokens
                    task.modelUsed = provider.name
                }
                await MainActor.run { taskManager.persistTask(task) }
                throw error
            }

            if let usage {
                totalInputTokens += usage.inputTokens
                totalOutputTokens += usage.outputTokens

                // Track usage per API call
                UsageStore.shared.recordUsage(
                    model: provider.model,
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens
                )
            }

            let totalTokens = totalInputTokens + totalOutputTokens

            switch response {
            case .text(let text):
                MajoorLogger.log("✅ Done after \(iteration) iterations")
                finalText = text
                let step = TaskStep(timestamp: Date(), type: .response, description: text, detail: nil)
                await MainActor.run {
                    task.steps.append(step)
                    task.status = .completed
                    task.summary = summarize(text)
                    task.completedAt = Date()
                    task.tokensUsed = totalTokens
                    task.modelUsed = provider.name
                }

                // 5. Persist task and extract memories
                await MainActor.run { taskManager.persistTask(task) }
                MemoryRetriever.extractAndSaveMemories(from: text, userInput: userInput, taskId: task.id.uuidString)

                // 6. Store conversation for continuity and prune stale entries
                let completedAt = Date()
                conversationHistory.removeAll { completedAt.timeIntervalSince($0.timestamp) >= conversationTimeoutSeconds }
                conversationHistory.append(ConversationContext(
                    userInput: userInput,
                    responseText: String(text.prefix(2000)),
                    toolSummaries: toolSummaries,
                    timestamp: completedAt
                ))

                return TaskResult(summary: summarize(text), steps: task.steps, tokensUsed: totalTokens)

            case .toolCalls(let calls):
                let (aMsg, rMsg, summaries) = try await handleToolCalls(calls, task: task)
                messages.append(aMsg)
                messages.append(rMsg)
                toolSummaries.append(contentsOf: summaries)

            case .mixed(let text, let calls):
                MajoorLogger.log("📝 \(text.prefix(100))...")
                let (aMsg, rMsg, summaries) = try await handleToolCalls(calls, task: task, precedingText: text)
                messages.append(aMsg)
                messages.append(rMsg)
                toolSummaries.append(contentsOf: summaries)
            }
        }

        let totalTokens = totalInputTokens + totalOutputTokens
        MajoorLogger.log("⚠️ Max iterations reached")
        await MainActor.run {
            task.status = .completed
            task.summary = finalText.isEmpty ? "Completed (max iterations)" : summarize(finalText)
            task.completedAt = Date()
            task.tokensUsed = totalTokens
            task.modelUsed = provider.name
        }
        await MainActor.run { taskManager.persistTask(task) }

        // Store conversation for continuity and prune stale entries
        let completedAt = Date()
        conversationHistory.removeAll { completedAt.timeIntervalSince($0.timestamp) >= conversationTimeoutSeconds }
        conversationHistory.append(ConversationContext(
            userInput: userInput,
            responseText: finalText.isEmpty ? "Completed (max iterations)" : String(finalText.prefix(2000)),
            toolSummaries: toolSummaries,
            timestamp: completedAt
        ))

        return TaskResult(summary: task.summary, steps: task.steps, tokensUsed: totalTokens)
    }

    // MARK: - Tool Execution

    private func handleToolCalls(
        _ toolCalls: [ToolCall],
        task: AgentTask,
        precedingText: String? = nil
    ) async throws -> (assistant: AnthropicMessage, result: AnthropicMessage, toolSummaries: [String]) {

        var assistantBlocks: [AnthropicContentBlock] = []
        if let text = precedingText {
            assistantBlocks.append(AnthropicContentBlock(type: "text", text: text, id: nil, name: nil, input: nil, toolUseId: nil, content: nil))
        }
        for call in toolCalls {
            let inputDict = call.arguments.mapValues { AnyCodable($0) }
            assistantBlocks.append(AnthropicContentBlock(type: "tool_use", text: nil, id: call.id, name: call.toolName, input: inputDict, toolUseId: nil, content: nil))
        }
        let assistantMsg = AnthropicMessage(role: "assistant", content: .blocks(assistantBlocks))

        var resultBlocks: [AnthropicContentBlock] = []
        var summaries: [String] = []
        for call in toolCalls {
            MajoorLogger.log("🔧 Tool: \(call.toolName)")
            let callStep = TaskStep(timestamp: Date(), type: .toolCall, description: "Calling \(call.toolName)", detail: call.arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
            await MainActor.run { task.steps.append(callStep) }

            let output: String
            if let tool = tools.first(where: { $0.name == call.toolName }) {
                let normalizedArgs = normalizeArguments(call.arguments, for: tool)
                if normalizedArgs != call.arguments {
                    MajoorLogger.log("🔄 Normalized args for \(call.toolName): \(call.arguments.keys.sorted()) → \(normalizedArgs.keys.sorted())")
                }
                do {
                    let result = try await tool.execute(arguments: normalizedArgs)
                    output = result.output
                } catch {
                    output = "Error: \(error.localizedDescription)"
                }
            } else {
                output = "Error: Tool '\(call.toolName)' not found"
            }

            // Collect brief summary for conversation continuity
            let argsPreview = call.arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            summaries.append("• \(call.toolName)(\(String(argsPreview.prefix(100)))) → \(String(output.prefix(150)))")

            let resultStep = TaskStep(timestamp: Date(), type: .toolResult, description: "Result from \(call.toolName)", detail: String(output.prefix(500)))
            await MainActor.run { task.steps.append(resultStep) }

            resultBlocks.append(AnthropicContentBlock(type: "tool_result", text: nil, id: nil, name: nil, input: nil, toolUseId: call.id, content: output))
        }

        return (assistantMsg, AnthropicMessage(role: "user", content: .blocks(resultBlocks)), summaries)
    }

    /// Normalizes argument keys so that common LLM aliases map to the tool's expected parameter names.
    /// e.g. "file_path" → "path", "file_content" → "content"
    private func normalizeArguments(_ args: [String: String], for tool: any AgentTool) -> [String: String] {
        let expectedKeys = Set(tool.parameters.map(\.name))
        var normalized = args

        // Common aliases the LLM might use instead of the declared parameter name
        let aliases: [String: [String]] = [
            "path": ["file_path", "filepath", "filename", "file_name", "file"],
            "content": ["file_content", "text", "data", "body"],
            "directory": ["dir", "dir_path", "directory_path", "folder", "folder_path"],
            "source": ["source_path", "src", "src_path", "from", "from_path"],
            "destination": ["destination_path", "dest", "dest_path", "to", "to_path"],
            "query": ["search_query", "search", "pattern", "keyword"],
            "command": ["cmd", "shell_command"],
            "message": ["commit_message", "msg"],
            "url": ["webpage_url", "link", "page_url"],
        ]

        for (canonical, alts) in aliases {
            // Only remap if the tool expects this key and it's missing from args
            guard expectedKeys.contains(canonical), normalized[canonical] == nil else { continue }
            for alt in alts {
                if let value = normalized[alt] {
                    normalized[canonical] = value
                    normalized.removeValue(forKey: alt)
                    break
                }
            }
        }

        return normalized
    }

    private func summarize(_ text: String) -> String {
        let first = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? text
        return first.count <= 150 ? first.trimmingCharacters(in: .whitespacesAndNewlines) : String(text.prefix(147)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

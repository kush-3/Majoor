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
    private let maxIterations = 75
    private let conversationTimeoutSeconds: TimeInterval = 600 // 10 minutes
    private let maxConversationEntries = 5
    private let maxResponseTextLength = 1000

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
    13. Batch operations — when performing repetitive actions on many files (move, rename, copy, delete), prefer using execute_shell or execute_script to handle them in a single command rather than calling individual file tools dozens of times. For example, use a bash loop or a short Python script to move 30 files instead of 30 separate move_file calls.

    PIPELINE BEHAVIOR:
    When the user describes a completed action, decision, or status change that implies work across 3 or more tools/services, DO NOT immediately start executing. Instead:
    1. Silently gather context first (git status, search Linear, check Slack, etc.)
    2. Present a specific, numbered plan based on real data — not generic placeholders
    3. End with: "Want me to go ahead? %%PIPELINE_CONFIRM%%"
    4. WAIT for the user to respond before executing anything
    5. Once approved, execute ALL steps without per-step confirmations
    6. Report a summary when complete
    For simple single-tool or two-tool tasks, just execute normally without the pipeline flow.

    CONTEXT GATHERING:
    Before proposing a pipeline plan, silently gather context to make your plan specific:
    - If the user mentions finishing code work → run git_status and git_diff first to know what actually changed, which branch, how many files
    - If the user mentions a ticket/issue → search for it to get the ID and status
    - If the user mentions a person → check recent messages for context
    - If the user mentions a project → check for the project page
    Use this context to make your plan specific. Instead of "Create a PR on GitHub", show "Create a PR 'Add JWT auth middleware' on kush/majoor (3 files, +142 -28)".
    """

    init(tools: [any AgentTool], taskManager: TaskManager) {
        self.tools = tools
        self.taskManager = taskManager
    }

    func execute(userInput: String) async throws -> TaskResult {
        MajoorLogger.log("🚀 Task: \(userInput)")

        // 1. Hybrid routing: keyword fast-path or LLM classification
        let (provider, toolSets) = await ModelRouter.routeHybrid(userInput)

        // 2. Retrieve relevant memories, inject current date, and MCP summary
        let memoryContext = MemoryRetriever.relevantContext(for: userInput)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let dateContext = "\n\nCurrent date and time: \(dateFormatter.string(from: Date()))"
        var fullSystemPrompt = systemPrompt + dateContext + memoryContext

        // Inject MCP server summary if any are running
        if let mcpSummary = await MCPServerManager.shared.serverSummary() {
            fullSystemPrompt += "\n\n" + mcpSummary
        }

        // 3. Build the tool list: local tools + filtered MCP tools based on routing
        var activeTools: [any AgentTool] = Array(tools)
        let allMcpTools = await MCPServerManager.shared.allAvailableTools()
        if !allMcpTools.isEmpty {
            // Filter MCP tools by the tool sets the router selected
            let includeAll = toolSets.isEmpty || toolSets.contains("all")
            let filteredMcpTools: [MCPToolBridge]
            if includeAll {
                filteredMcpTools = allMcpTools
            } else {
                filteredMcpTools = allMcpTools.filter { tool in
                    toolSets.contains(tool.serverName)
                }
            }
            if !filteredMcpTools.isEmpty {
                activeTools.append(contentsOf: filteredMcpTools)
                MajoorLogger.log("🔌 Loaded \(filteredMcpTools.count)/\(allMcpTools.count) MCP tool(s) [sets: \(toolSets)]")
            }
        }
        let anthropicTools = activeTools.map { $0.toAnthropicTool() }

        // 4. Create task and add to UI
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

        var totalInputTokens = 0
        var totalOutputTokens = 0
        var iteration = 0
        var finalText = ""
        var toolSummaries: [String] = []
        var pipelineApproved = false

        // 5. Agent loop
        while iteration < maxIterations {
            iteration += 1
            MajoorLogger.log("🔄 Iteration \(iteration)/\(maxIterations) [\(provider.name)]")

            let thinkStep = TaskStep(timestamp: Date(), type: .thinking, description: "Thinking... (\(iteration))", detail: nil)
            await MainActor.run { task.steps.append(thinkStep) }

            // API call with structured error recovery
            let response: LLMResponse
            let usage: AnthropicUsage?
            do {
                (response, usage) = try await provider.complete(
                    systemPrompt: fullSystemPrompt,
                    messages: messages,
                    tools: anthropicTools
                )
            } catch let error as LLMError {
                // Context overflow: try to recover by trimming history
                if case .contextOverflow = error {
                    MajoorLogger.log("⚠️ Context overflow — attempting recovery by trimming history")
                    let trimmed = trimConversationForRecovery(&messages)
                    if trimmed {
                        let recoveryStep = TaskStep(timestamp: Date(), type: .thinking, description: "Context too large — trimming history and retrying...", detail: nil)
                        await MainActor.run { task.steps.append(recoveryStep) }
                        continue // Retry with trimmed messages
                    }
                    // If we can't trim further, fall through to failure
                    MajoorLogger.error("❌ Context overflow — cannot recover, conversation too complex")
                }

                // Auth errors: fail fast with actionable message
                if case .invalidAPIKey = error {
                    MajoorLogger.error("❌ Invalid API key — failing immediately")
                }

                // All other errors: mark task failed
                let errorDesc = error.errorDescription ?? "API error"
                MajoorLogger.error("❌ API error: \(errorDesc)")
                let errorStep = TaskStep(timestamp: Date(), type: .error, description: errorDesc, detail: nil)
                let totalTokens = totalInputTokens + totalOutputTokens
                await MainActor.run {
                    task.steps.append(errorStep)
                    task.status = .failed
                    task.summary = errorDesc
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
                // Check for pipeline confirmation marker
                if text.contains("%%PIPELINE_CONFIRM%%") {
                    let planText = text.replacingOccurrences(of: "%%PIPELINE_CONFIRM%%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    MajoorLogger.log("🔄 Pipeline plan proposed, waiting for approval...")

                    // Parse numbered steps from plan text
                    let parsedSteps = parsePipelineSteps(from: planText)

                    let planStep = TaskStep(timestamp: Date(), type: .response, description: planText, detail: nil)
                    await MainActor.run {
                        task.steps.append(planStep)
                        taskManager.showPipelinePlan(planText, taskId: task.id)
                        taskManager.setPipelineSteps(parsedSteps)
                    }

                    // Send notification with approve/deny and wait for response
                    let approved = await ConfirmationManager.shared.requestConfirmation(
                        title: "Majoor Pipeline",
                        body: String(planText.prefix(200)),
                        category: NotificationManager.pipelineConfirmCategory
                    )

                    await MainActor.run { taskManager.pipelineExecuting = approved }

                    if approved {
                        pipelineApproved = true
                        // Build approval message including which steps are disabled
                        let skippedSteps = await MainActor.run { taskManager.pipelineSteps.enumerated().filter { !$0.element.enabled }.map { $0.offset + 1 } }
                        var approvalMsg = "User approved. Execute all steps now."
                        if !skippedSteps.isEmpty {
                            let skippedList = skippedSteps.map(String.init).joined(separator: ", ")
                            approvalMsg = "User approved but wants to SKIP step(s): \(skippedList). Execute the remaining steps only."
                            // Mark skipped steps
                            await MainActor.run {
                                for idx in skippedSteps {
                                    taskManager.updatePipelineStep(at: idx - 1, status: .skipped)
                                }
                            }
                        }
                        messages.append(AnthropicMessage(role: "assistant", content: .string(planText)))
                        messages.append(AnthropicMessage(role: "user", content: .string(approvalMsg)))
                        MajoorLogger.log("✅ Pipeline approved — executing")
                        continue
                    } else {
                        pipelineApproved = false
                        messages.append(AnthropicMessage(role: "assistant", content: .string(planText)))
                        messages.append(AnthropicMessage(role: "user", content: .string("User declined. Ask what they'd like to do differently.")))
                        MajoorLogger.log("❌ Pipeline declined — asking follow-up")
                        await MainActor.run { taskManager.clearPipelinePlan() }
                        continue
                    }
                }

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
                    taskManager.clearPipelinePlan()
                }

                // 5. Persist task and extract memories
                await MainActor.run { taskManager.persistTask(task) }
                MemoryRetriever.extractAndSaveMemories(from: text, userInput: userInput, taskId: task.id.uuidString)

                // 6. Store conversation for continuity and prune stale/excess entries
                let completedAt = Date()
                conversationHistory.removeAll { completedAt.timeIntervalSince($0.timestamp) >= conversationTimeoutSeconds }
                conversationHistory.append(ConversationContext(
                    userInput: userInput,
                    responseText: String(text.prefix(maxResponseTextLength)),
                    toolSummaries: Array(toolSummaries.suffix(10)),
                    timestamp: completedAt
                ))
                // Cap at maxConversationEntries
                if conversationHistory.count > maxConversationEntries {
                    conversationHistory.removeFirst(conversationHistory.count - maxConversationEntries)
                }

                return TaskResult(summary: summarize(text), steps: task.steps, tokensUsed: totalTokens)

            case .toolCalls(let calls):
                let (aMsg, rMsg, summaries) = try await handleToolCalls(calls, task: task, activeTools: activeTools, pipelineApproved: pipelineApproved)
                messages.append(aMsg)
                messages.append(rMsg)
                toolSummaries.append(contentsOf: summaries)

            case .mixed(let text, let calls):
                // Check for pipeline confirmation in mixed responses too
                if text.contains("%%PIPELINE_CONFIRM%%") {
                    let planText = text.replacingOccurrences(of: "%%PIPELINE_CONFIRM%%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    MajoorLogger.log("🔄 Pipeline plan proposed (mixed), waiting for approval...")

                    let parsedSteps = parsePipelineSteps(from: planText)

                    let planStep = TaskStep(timestamp: Date(), type: .response, description: planText, detail: nil)
                    await MainActor.run {
                        task.steps.append(planStep)
                        taskManager.showPipelinePlan(planText, taskId: task.id)
                        taskManager.setPipelineSteps(parsedSteps)
                    }

                    let approved = await ConfirmationManager.shared.requestConfirmation(
                        title: "Majoor Pipeline",
                        body: String(planText.prefix(200)),
                        category: NotificationManager.pipelineConfirmCategory
                    )

                    await MainActor.run { taskManager.pipelineExecuting = approved }

                    if approved {
                        pipelineApproved = true
                        let skippedSteps = await MainActor.run { taskManager.pipelineSteps.enumerated().filter { !$0.element.enabled }.map { $0.offset + 1 } }
                        var approvalMsg = "User approved. Execute all steps now."
                        if !skippedSteps.isEmpty {
                            let skippedList = skippedSteps.map(String.init).joined(separator: ", ")
                            approvalMsg = "User approved but wants to SKIP step(s): \(skippedList). Execute the remaining steps only."
                            await MainActor.run {
                                for idx in skippedSteps {
                                    taskManager.updatePipelineStep(at: idx - 1, status: .skipped)
                                }
                            }
                        }
                        messages.append(AnthropicMessage(role: "assistant", content: .string(planText)))
                        messages.append(AnthropicMessage(role: "user", content: .string(approvalMsg)))
                        continue
                    } else {
                        pipelineApproved = false
                        messages.append(AnthropicMessage(role: "assistant", content: .string(planText)))
                        messages.append(AnthropicMessage(role: "user", content: .string("User declined. Ask what they'd like to do differently.")))
                        await MainActor.run { taskManager.clearPipelinePlan() }
                        continue
                    }
                }

                MajoorLogger.log("📝 \(text.prefix(100))...")
                let (aMsg, rMsg, summaries) = try await handleToolCalls(calls, task: task, precedingText: text, activeTools: activeTools, pipelineApproved: pipelineApproved)
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

        // Store conversation for continuity and prune stale/excess entries
        let completedAt = Date()
        conversationHistory.removeAll { completedAt.timeIntervalSince($0.timestamp) >= conversationTimeoutSeconds }
        conversationHistory.append(ConversationContext(
            userInput: userInput,
            responseText: finalText.isEmpty ? "Completed (max iterations)" : String(finalText.prefix(maxResponseTextLength)),
            toolSummaries: Array(toolSummaries.suffix(10)),
            timestamp: completedAt
        ))
        if conversationHistory.count > maxConversationEntries {
            conversationHistory.removeFirst(conversationHistory.count - maxConversationEntries)
        }

        return TaskResult(summary: task.summary, steps: task.steps, tokensUsed: totalTokens)
    }

    // MARK: - Tool Execution

    private func handleToolCalls(
        _ toolCalls: [ToolCall],
        task: AgentTask,
        precedingText: String? = nil,
        activeTools: [any AgentTool],
        pipelineApproved: Bool = false
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
            await MainActor.run {
                task.steps.append(callStep)
                // Update pipeline step tracking if executing a pipeline
                if let matchedIndex = matchToolToPipelineStep(call.toolName, arguments: call.arguments) {
                    taskManager.addToolCallToPipelineStep(at: matchedIndex, toolName: call.toolName)
                    taskManager.updatePipelineStep(at: matchedIndex, status: .running)
                }
            }

            let output: String
            if let tool = activeTools.first(where: { $0.name == call.toolName }) {
                // Skip per-tool confirmation if pipeline is approved
                if tool.requiresConfirmation && !pipelineApproved {
                    let approved = await ConfirmationManager.shared.requestConfirmation(
                        title: "Majoor — Confirm Action",
                        body: "\(call.toolName): \(call.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))",
                        category: NotificationManager.confirmGenericCategory
                    )
                    if !approved {
                        output = "User declined to execute \(call.toolName)."
                        let resultStep = TaskStep(timestamp: Date(), type: .toolResult, description: "Declined: \(call.toolName)", detail: nil)
                        await MainActor.run { task.steps.append(resultStep) }
                        resultBlocks.append(AnthropicContentBlock(type: "tool_result", text: nil, id: nil, name: nil, input: nil, toolUseId: call.id, content: output))
                        summaries.append("• \(call.toolName) → declined by user")
                        continue
                    }
                }

                do {
                    if let mcpTool = tool as? MCPToolBridge {
                        // MCP tools: pass raw JSON to preserve complex types, skip arg normalization
                        let result = try await mcpTool.executeWithRawJSON(call.rawInputJSON, stringArgs: call.arguments)
                        output = result.output
                    } else {
                        // Native tools: normalize argument aliases
                        let normalizedArgs = normalizeArguments(call.arguments, for: tool)
                        if normalizedArgs != call.arguments {
                            MajoorLogger.log("🔄 Normalized args for \(call.toolName): \(call.arguments.keys.sorted()) → \(normalizedArgs.keys.sorted())")
                        }
                        let result = try await tool.execute(arguments: normalizedArgs)
                        output = result.output
                    }
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
            await MainActor.run {
                task.steps.append(resultStep)
                // Update pipeline step status based on result
                if let matchedIndex = matchToolToPipelineStep(call.toolName, arguments: call.arguments) {
                    let isError = output.lowercased().hasPrefix("error")
                    if isError {
                        taskManager.updatePipelineStep(at: matchedIndex, status: .failed, error: String(output.prefix(200)))
                    } else {
                        taskManager.updatePipelineStep(at: matchedIndex, status: .completed, result: String(output.prefix(100)))
                    }
                }
            }

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

    // MARK: - Pipeline Step Parsing

    /// Parse numbered plan text into PipelineStep objects
    private func parsePipelineSteps(from planText: String) -> [PipelineStep] {
        let lines = planText.components(separatedBy: "\n")
        var steps: [PipelineStep] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match numbered lines: "1. Do something" or "1) Do something" or "- Do something"
            let cleaned: String?
            if let range = trimmed.range(of: #"^\d+[\.\)]\s*"#, options: .regularExpression) {
                cleaned = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("- ") {
                cleaned = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else {
                cleaned = nil
            }

            if let desc = cleaned, !desc.isEmpty {
                steps.append(PipelineStep(planDescription: desc))
            }
        }

        return steps
    }

    /// Step-to-tool mapping heuristic
    private static let stepToolMapping: [String: [String]] = [
        "commit": ["git_commit"],
        "push": ["git_push"],
        "pr": ["github__create_pull_request", "git_create_pr", "github__create-pull-request"],
        "pull request": ["github__create_pull_request", "git_create_pr"],
        "issue": ["linear__create_issue", "linear__update_issue", "github__create_issue", "linear__create-issue", "linear__update-issue"],
        "ticket": ["linear__create_issue", "linear__update_issue", "linear__create-issue", "linear__update-issue"],
        "slack": ["slack__"],
        "post": ["slack__slack_post_message", "slack__post-message"],
        "message": ["slack__slack_post_message", "slack__post-message"],
        "notion": ["notion__"],
        "page": ["notion__create_page", "notion__create-page"],
        "email": ["send_email", "draft_email", "reply_to_email"],
        "calendar": ["create_calendar_event", "update_calendar_event"],
        "branch": ["git_create_branch"],
        "merge": ["github__merge_pull_request", "github__merge-pull-request"],
        "status": ["git_status"],
        "diff": ["git_diff"],
    ]

    /// Match a tool call to the best pipeline step.
    /// Returns the index into taskManager.pipelineSteps, or nil if no match.
    private func matchToolToPipelineStep(_ toolName: String, arguments: [String: String]) -> Int? {
        let steps = taskManager.pipelineSteps
        guard !steps.isEmpty else { return nil }

        // First: find steps that are currently running (already matched to this tool)
        if let runningIdx = steps.firstIndex(where: { $0.status == .running && $0.toolCalls.contains(toolName) }) {
            return runningIdx
        }

        // Second: keyword match between step description and tool name
        for (index, step) in steps.enumerated() {
            guard step.enabled, step.status == .pending || step.status == .running else { continue }
            let desc = step.planDescription.lowercased()

            // Check the mapping table
            for (keyword, toolPrefixes) in Self.stepToolMapping {
                if desc.contains(keyword) {
                    for prefix in toolPrefixes {
                        if toolName.hasPrefix(prefix) || toolName == prefix {
                            return index
                        }
                    }
                }
            }

            // Direct tool name match (e.g., step says "git_push" literally)
            if desc.contains(toolName.replacingOccurrences(of: "_", with: " ")) {
                return index
            }
        }

        // Third: if there's exactly one pending step, it's probably the next one
        let pendingSteps = steps.enumerated().filter { $0.element.status == .pending && $0.element.enabled }
        if pendingSteps.count == 1 {
            return pendingSteps[0].offset
        }

        // Fourth: find first pending step (sequential assumption)
        return steps.firstIndex { $0.status == .pending && $0.enabled }
    }

    // MARK: - Context Overflow Recovery

    /// Attempts to reduce conversation size when context overflows.
    /// Returns true if messages were trimmed (caller should retry), false if no further trimming possible.
    private func trimConversationForRecovery(_ messages: inout [AnthropicMessage]) -> Bool {
        // Strategy 1: Remove oldest conversation history pairs (keep at least the latest user message)
        guard messages.count > 1 else { return false }

        // Find tool_result blocks and truncate their content to 500 chars
        var didTruncate = false
        for i in 0..<messages.count {
            if case .blocks(var blocks) = messages[i].content {
                var modified = false
                for j in 0..<blocks.count {
                    if blocks[j].type == "tool_result",
                       let content = blocks[j].content,
                       content.count > 500 {
                        blocks[j] = AnthropicContentBlock(
                            type: "tool_result", text: nil, id: nil, name: nil,
                            input: nil, toolUseId: blocks[j].toolUseId,
                            content: String(content.prefix(500)) + "\n[... truncated ...]"
                        )
                        modified = true
                        didTruncate = true
                    }
                }
                if modified {
                    messages[i] = AnthropicMessage(role: messages[i].role, content: .blocks(blocks))
                }
            }
        }
        if didTruncate {
            MajoorLogger.log("✂️ Truncated tool results to 500 chars")
            return true
        }

        // Strategy 2: Remove the oldest pair of messages (user + assistant) if there are conversation history pairs
        if messages.count > 3 {
            messages.removeFirst(2) // Remove oldest user+assistant pair
            MajoorLogger.log("✂️ Removed oldest conversation pair, \(messages.count) messages remain")
            return true
        }

        return false
    }
}

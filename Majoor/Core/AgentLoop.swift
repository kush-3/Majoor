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
    /// Cap on any single tool result entering the conversation (chars, ≈7.5k tokens)
    private let maxToolResultChars = 30_000
    private let conversationTimeoutSeconds: TimeInterval = 600 // 10 minutes
    private let maxConversationEntries = 5
    private let maxResponseTextLength = 1000

    /// Stores conversation history for continuity
    private struct ConversationContext: @unchecked Sendable {
        let userInput: String
        let responseText: String
        let toolSummaries: [String]
        let toolSets: [String]  // Which MCP services were used (for follow-up routing)
        let timestamp: Date
    }
    private var conversationHistory: [ConversationContext] = []
    private let historyLock = NSLock()

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
    - Long-term memory: save and search durable facts, preferences, and project context across sessions

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
    11. Email safety — to send or reply, call send_email/reply_to_email directly with the complete final draft. The app itself shows the user a confirmation containing what will be sent, and they can approve, deny, or attach corrections. NEVER pause to ask permission in a text response and never end your turn waiting for a "yes" — call the tool and let the app ask. If the user only wants a draft, use draft_email which saves without sending. Write emails in the user's own voice with their natural sign-off — never sign as an assistant or add "on behalf of" phrasing unless asked.
    12. Calendar — when the user asks about their schedule, use read_calendar_events. For creating events, always confirm the date/time before calling create_calendar_event.
    13. Batch operations — when performing repetitive actions on many files (move, rename, copy, delete), prefer using execute_shell or execute_script to handle them in a single command rather than calling individual file tools dozens of times. For example, use a bash loop or a short Python script to move 30 files instead of 30 separate move_file calls.
    14. Memory — when the user tells you something durable about themselves (a preference, a correction, a personal fact, a project detail) or explicitly asks you to remember something, save it with save_memory. First use search_memory to check for an existing memory on the topic and update it via supersedes_id instead of saving a duplicate. Use search_memory when a task likely depends on personal context that is not already in CONTEXT FROM MEMORY. Do not save task minutiae or transient state.
    15. Confirmations — sensitive tools (sending email, deleting files or events, git push/PR, running scripts) automatically show the user an approve/deny prompt when their settings require it. Never ask for permission in a text response before calling a tool: call it, and the app will ask the user if needed. If the user denies, the tool result says so (often with feedback) — adapt and continue rather than retrying the same call.

    PIPELINE BEHAVIOR:
    When the user describes a completed action, decision, or status change that implies work across 3 or more tools/services, DO NOT immediately start executing. Instead:
    1. Silently gather context first (git status, search Linear, check Slack, etc.)
    2. Present a specific, numbered plan based on real data — not generic placeholders
    3. End with: "Want me to go ahead? %%PIPELINE_CONFIRM%%"
    4. WAIT for the user to respond before executing anything
    5. Once approved, execute ALL steps. Sensitive actions (sending email, deletions, pushes) may still ask the user directly — that is expected, continue after they respond
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
        // Include recent conversation context so the router understands follow-ups
        let historySnapshot = historyLock.withLock { conversationHistory }
        let recentContext = historySnapshot.suffix(3).map { $0.userInput }.joined(separator: " | ")
        let routingInput = recentContext.isEmpty ? userInput : "\(userInput) [recent context: \(recentContext)]"
        let (provider, routedToolSets) = await ModelRouter.routeHybrid(routingInput)

        // Merge tool sets from recent conversations so follow-ups retain access
        var toolSets = routedToolSets
        let now = Date()
        let recentToolSets = historySnapshot
            .filter { now.timeIntervalSince($0.timestamp) < conversationTimeoutSeconds }
            .flatMap { $0.toolSets }
        for ts in recentToolSets {
            if !toolSets.contains(ts) {
                toolSets.append(ts)
            }
        }

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

        // 3. Build the tool list: local tools + MCP tools (live or cached)
        let includeAllMCP = toolSets.isEmpty || toolSets.contains("all")
        var activeTools: [any AgentTool] = Array(tools)
        let allMcpTools = await MCPServerManager.shared.allAvailableTools()
        if !allMcpTools.isEmpty {
            let filteredMcpTools: [MCPToolBridge]
            if includeAllMCP {
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

        // 5. Build messages — inject all conversations from the last 10 minutes
        var messages: [AnthropicMessage] = []
        let recentConversations = historySnapshot.filter {
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
        // Overflow recovery may drop seeded history pairs from the front, but
        // only as many as were actually seeded — string pairs further in (a
        // pipeline plan + approval) contain the task and must survive.
        var seededHistoryPairs = recentConversations.count

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
                    let trimmed = trimConversationForRecovery(&messages, seededHistoryPairs: &seededHistoryPairs)
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
                    task.modelUsed = provider.model
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
                    task.modelUsed = provider.model
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
                        // Auto-open the panel so user can see the plan and toggle steps
                        NotificationCenter.default.post(name: .majoorOpenPanel, object: nil)
                    }

                    // Show in-app confirmation + notification fallback
                    let confirmResult = await ConfirmationManager.shared.requestConfirmation(
                        title: "Majoor Pipeline",
                        body: String(planText.prefix(200)),
                        category: NotificationManager.pipelineConfirmCategory,
                        onPending: { [taskManager] confirmId in
                            Task { @MainActor in
                                taskManager.showConfirmation(id: confirmId, title: "Majoor Pipeline", body: planText, category: NotificationManager.pipelineConfirmCategory)
                            }
                        }
                    )
                    await MainActor.run {
                        taskManager.clearConfirmation()
                        taskManager.pipelineExecuting = confirmResult.approved
                    }

                    if confirmResult.approved {
                        // Build approval message including which steps are disabled and user feedback
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
                        // Inject user feedback if provided
                        if let feedback = confirmResult.feedback {
                            approvalMsg += " User note: \(feedback)"
                        }
                        messages.append(AnthropicMessage(role: "assistant", content: .string(planText)))
                        messages.append(AnthropicMessage(role: "user", content: .string(approvalMsg)))
                        MajoorLogger.log("✅ Pipeline approved — executing")
                        continue
                    } else {
                        var denialMsg = "User declined."
                        if let feedback = confirmResult.feedback {
                            denialMsg += " User feedback: \(feedback)"
                        } else {
                            denialMsg += " Ask what they'd like to do differently."
                        }
                        messages.append(AnthropicMessage(role: "assistant", content: .string(planText)))
                        messages.append(AnthropicMessage(role: "user", content: .string(denialMsg)))
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
                    task.modelUsed = provider.model
                    taskManager.clearPipelinePlan()
                }

                // 5. Persist task (memories are saved by the model via save_memory)
                await MainActor.run { taskManager.persistTask(task) }

                // 6. Store conversation for continuity and prune stale/excess entries
                let completedAt = Date()
                historyLock.withLock {
                    conversationHistory.removeAll { completedAt.timeIntervalSince($0.timestamp) >= conversationTimeoutSeconds }
                    conversationHistory.append(ConversationContext(
                        userInput: userInput,
                        responseText: String(text.prefix(maxResponseTextLength)),
                        toolSummaries: Array(toolSummaries.suffix(10)),
                        toolSets: toolSets,
                        timestamp: completedAt
                    ))
                    if conversationHistory.count > maxConversationEntries {
                        conversationHistory.removeFirst(conversationHistory.count - maxConversationEntries)
                    }
                }

                return TaskResult(summary: summarize(text), steps: task.steps, tokensUsed: totalTokens)

            case .toolCalls(let calls, let rawContent):
                let (aMsg, rMsg, summaries) = try await handleToolCalls(calls, task: task, assistantContent: rawContent, activeTools: activeTools, userInput: userInput)
                messages.append(aMsg)
                messages.append(rMsg)
                toolSummaries.append(contentsOf: summaries)

            case .mixed(let text, let calls, let rawContent):
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
                        // Auto-open the panel so user can see the plan and toggle steps
                        NotificationCenter.default.post(name: .majoorOpenPanel, object: nil)
                    }

                    let confirmResult = await ConfirmationManager.shared.requestConfirmation(
                        title: "Majoor Pipeline",
                        body: String(planText.prefix(200)),
                        category: NotificationManager.pipelineConfirmCategory,
                        onPending: { [taskManager] confirmId in
                            Task { @MainActor in
                                taskManager.showConfirmation(id: confirmId, title: "Majoor Pipeline", body: planText, category: NotificationManager.pipelineConfirmCategory)
                            }
                        }
                    )
                    await MainActor.run {
                        taskManager.clearConfirmation()
                        taskManager.pipelineExecuting = confirmResult.approved
                    }

                    if confirmResult.approved {
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
                        if let feedback = confirmResult.feedback {
                            approvalMsg += " User note: \(feedback)"
                        }
                        messages.append(AnthropicMessage(role: "assistant", content: .string(planText)))
                        messages.append(AnthropicMessage(role: "user", content: .string(approvalMsg)))
                        continue
                    } else {
                        var denialMsg = "User declined."
                        if let feedback = confirmResult.feedback {
                            denialMsg += " User feedback: \(feedback)"
                        } else {
                            denialMsg += " Ask what they'd like to do differently."
                        }
                        messages.append(AnthropicMessage(role: "assistant", content: .string(planText)))
                        messages.append(AnthropicMessage(role: "user", content: .string(denialMsg)))
                        await MainActor.run { taskManager.clearPipelinePlan() }
                        continue
                    }
                }

                MajoorLogger.log("📝 \(text.prefix(100))...")
                let (aMsg, rMsg, summaries) = try await handleToolCalls(calls, task: task, assistantContent: rawContent, activeTools: activeTools, userInput: userInput)
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
            task.modelUsed = provider.model
        }
        await MainActor.run { taskManager.persistTask(task) }

        // Store conversation for continuity and prune stale/excess entries
        let completedAt = Date()
        historyLock.withLock {
            conversationHistory.removeAll { completedAt.timeIntervalSince($0.timestamp) >= conversationTimeoutSeconds }
            conversationHistory.append(ConversationContext(
                userInput: userInput,
                responseText: finalText.isEmpty ? "Completed (max iterations)" : String(finalText.prefix(maxResponseTextLength)),
                toolSummaries: Array(toolSummaries.suffix(10)),
                toolSets: toolSets,
                timestamp: completedAt
            ))
            if conversationHistory.count > maxConversationEntries {
                conversationHistory.removeFirst(conversationHistory.count - maxConversationEntries)
            }
        }

        return TaskResult(summary: task.summary, steps: task.steps, tokensUsed: totalTokens)
    }

    // MARK: - Tool Execution

    /// `assistantContent` is the model's response content blocks verbatim.
    private func handleToolCalls(
        _ toolCalls: [ToolCall],
        task: AgentTask,
        assistantContent: [AnthropicContentBlock],
        activeTools: [any AgentTool],
        userInput: String
    ) async throws -> (assistant: AnthropicMessage, result: AnthropicMessage, toolSummaries: [String]) {

        // Echo the response blocks back unchanged rather than rebuilding them from
        // the parsed text + tool calls. This keeps `thinking` / `redacted_thinking`
        // blocks (and their signatures) intact, which the API requires on the
        // assistant turn that precedes tool_result, and preserves tool_use input
        // types instead of the stringified copies in ToolCall.arguments.
        let assistantMsg = AnthropicMessage(role: "assistant", content: .blocks(assistantContent))

        var resultBlocks: [AnthropicContentBlock] = []
        var summaries: [String] = []

        for call in toolCalls {
            // A stopped task must not execute the remaining tools in a batch —
            // a denied mid-batch confirmation would otherwise fall through to
            // the next (uncancellable, synchronous) tool call.
            try Task.checkCancellation()
            MajoorLogger.log("🔧 Tool: \(call.toolName)")
            let callStep = TaskStep(timestamp: Date(), type: .toolCall, description: "Calling \(call.toolName)", detail: String(call.arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", ").prefix(1000)))
            await MainActor.run {
                task.steps.append(callStep)
                // Update pipeline step tracking if executing a pipeline
                let pipelineSteps = taskManager.pipelineSteps
                if let matchedIndex = matchToolToPipelineStep(call.toolName, arguments: call.arguments, steps: pipelineSteps) {
                    taskManager.addToolCallToPipelineStep(at: matchedIndex, toolName: call.toolName)
                    taskManager.updatePipelineStep(at: matchedIndex, status: .running)
                }
            }

            let output: String
            var confirmFeedback: String? = nil  // User feedback from confirmation (if any)
            if let tool = activeTools.first(where: { $0.name == call.toolName }) {
                // Normalize aliases BEFORE the policy gate — the model emits
                // keys like "cmd" for "command", and gating on raw keys would
                // let an aliased interpreter invocation dodge the prompt.
                let normalizedArgs: [String: String]
                if tool is MCPToolBridge {
                    normalizedArgs = call.arguments
                } else {
                    normalizedArgs = normalizeArguments(call.arguments, for: tool)
                    if normalizedArgs != call.arguments {
                        MajoorLogger.log("🔄 Normalized args for \(call.toolName): \(call.arguments.keys.sorted()) → \(normalizedArgs.keys.sorted())")
                    }
                }

                // Permission-mode policy. Sensitive actions prompt even inside
                // an approved pipeline — one approval must not blanket-authorize
                // outbound email or deletions.
                if await ConfirmationPolicy.shouldConfirm(
                    mode: PermissionMode.current,
                    toolName: call.toolName,
                    requiresConfirmation: tool.requiresConfirmation,
                    isReadOnly: tool.isReadOnly,
                    arguments: normalizedArgs,
                    userInput: userInput
                ) {
                    let confirmTitle = "Majoor — Confirm Action"
                    // Deterministic body: identity-bearing keys first, values
                    // capped individually — a long email body must never crowd
                    // the recipient out of the approval prompt.
                    let priorityKeys = ["to", "subject", "recipient", "path", "source", "destination", "event_id", "language", "command", "branch", "title", "query", "message"]
                    // Identity-bearing values (who/where the action lands) get a
                    // generous cap — a truncated recipient list would mean the
                    // user approves an email without seeing all its recipients
                    let identityKeys: Set<String> = ["to", "recipient", "cc", "bcc", "path", "source", "destination", "event_id"]
                    let orderedArgs = normalizedArgs.sorted { a, b in
                        let ia = priorityKeys.firstIndex(of: a.key) ?? Int.max
                        let ib = priorityKeys.firstIndex(of: b.key) ?? Int.max
                        return ia == ib ? a.key < b.key : ia < ib
                    }
                    // Content keys get a mid-size cap: the user is approving an
                    // email/message partly on its body, so 160 chars is too blind
                    let contentKeys: Set<String> = ["body", "subject", "message", "code"]
                    let argsSummary = orderedArgs
                        .map { arg -> String in
                            let cap = identityKeys.contains(arg.key) ? 500 : (contentKeys.contains(arg.key) ? 400 : 160)
                            return "\(arg.key)=\(String(arg.value.prefix(cap)))\(arg.value.count > cap ? "…" : "")"
                        }
                        .joined(separator: ", ")
                    let preview = await tool.confirmationPreview(arguments: normalizedArgs)
                    let confirmBody = preview ?? "\(call.toolName): \(String(argsSummary.prefix(1200)))\(argsSummary.count > 1200 ? " …" : "")"
                    let confirmCategory: String
                    if call.toolName.hasPrefix("delete_") {
                        confirmCategory = NotificationManager.confirmDeleteCategory
                    } else if call.toolName == "send_email" || call.toolName == "reply_to_email" {
                        confirmCategory = NotificationManager.confirmEmailCategory
                    } else {
                        confirmCategory = NotificationManager.confirmGenericCategory
                    }
                    let confirmResult = await ConfirmationManager.shared.requestConfirmation(
                        title: confirmTitle,
                        body: confirmBody,
                        category: confirmCategory,
                        onPending: { [taskManager] confirmId in
                            Task { @MainActor in
                                taskManager.showConfirmation(id: confirmId, title: confirmTitle, body: confirmBody, category: confirmCategory)
                                NotificationCenter.default.post(name: .majoorOpenPanel, object: nil)
                            }
                        }
                    )
                    await MainActor.run { taskManager.clearConfirmation() }
                    if !confirmResult.approved {
                        let feedbackNote = confirmResult.feedback.map { " User feedback: \($0)" } ?? ""
                        output = "User declined to execute \(call.toolName).\(feedbackNote)"
                        let resultStep = TaskStep(timestamp: Date(), type: .toolResult, description: "Declined: \(call.toolName)", detail: confirmResult.feedback)
                        await MainActor.run {
                            task.steps.append(resultStep)
                            // Don't leave a matched pipeline step spinning at
                            // .running forever after a mid-pipeline decline
                            let pipelineSteps = taskManager.pipelineSteps
                            if let matchedIndex = matchToolToPipelineStep(call.toolName, arguments: call.arguments, steps: pipelineSteps) {
                                taskManager.updatePipelineStep(at: matchedIndex, status: .skipped)
                            }
                        }
                        resultBlocks.append(AnthropicContentBlock(type: "tool_result", text: nil, id: nil, name: nil, input: nil, toolUseId: call.id, content: output))
                        summaries.append("• \(call.toolName) → declined by user\(feedbackNote)")
                        continue
                    }

                    // If user approved with feedback, store it to append to the tool result
                    confirmFeedback = confirmResult.feedback
                }

                // An approval that resumed after the task was stopped must not
                // execute — the tools themselves are synchronous and ignore
                // cancellation.
                try Task.checkCancellation()

                do {
                    if let mcpTool = tool as? MCPToolBridge {
                        // MCP tools: pass raw JSON to preserve complex types, skip arg normalization
                        let result = try await mcpTool.executeWithRawJSON(call.rawInputJSON, stringArgs: call.arguments)
                        output = result.output
                    } else {
                        let result = try await tool.execute(arguments: normalizedArgs)
                        output = result.output
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    output = "Error: \(error.localizedDescription)"
                }
            } else {
                output = "Error: Tool '\(call.toolName)' not found"
            }

            // Defense-in-depth: no single tool result may balloon the conversation.
            // MCP servers and some tools return unbounded payloads, and every
            // character kept here is re-sent to the API on every remaining iteration.
            var boundedOutput = output
            if boundedOutput.count > maxToolResultChars {
                let head = String(boundedOutput.prefix(maxToolResultChars * 3 / 4))
                let tail = String(boundedOutput.suffix(maxToolResultChars / 4))
                boundedOutput = "\(head)\n\n... [tool output truncated: \(output.count - maxToolResultChars) of \(output.count) characters omitted] ...\n\n\(tail)"
                MajoorLogger.log("✂️ \(call.toolName) output capped at \(maxToolResultChars) chars (was \(output.count))")
            }

            // Collect brief summary for conversation continuity
            let argsPreview = call.arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            summaries.append("• \(call.toolName)(\(String(argsPreview.prefix(100)))) → \(String(output.prefix(150)))")

            let resultStep = TaskStep(timestamp: Date(), type: .toolResult, description: "Result from \(call.toolName)", detail: String(output.prefix(500)))
            await MainActor.run {
                task.steps.append(resultStep)
                // Update pipeline step status based on result
                let pipelineSteps = taskManager.pipelineSteps
                if let matchedIndex = matchToolToPipelineStep(call.toolName, arguments: call.arguments, steps: pipelineSteps) {
                    let isError = output.lowercased().hasPrefix("error")
                    if isError {
                        taskManager.updatePipelineStep(at: matchedIndex, status: .failed, error: String(output.prefix(200)))
                    } else {
                        taskManager.updatePipelineStep(at: matchedIndex, status: .completed, result: String(output.prefix(100)))
                    }
                }
            }

            // Append user's confirmation feedback to the tool result so the LLM can adapt
            var finalOutput = boundedOutput
            if let feedback = confirmFeedback {
                finalOutput += "\n[User note: \(feedback)]"
            }
            resultBlocks.append(AnthropicContentBlock(type: "tool_result", text: nil, id: nil, name: nil, input: nil, toolUseId: call.id, content: finalOutput))
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
    private func matchToolToPipelineStep(_ toolName: String, arguments: [String: String], steps: [PipelineStep]) -> Int? {
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

    private static let recoveryTruncationMarker = "\n[... truncated for context recovery ...]"

    /// Attempts to reduce conversation size when context overflows.
    /// Returns true only if the conversation actually shrank (caller should retry),
    /// false if no further trimming is possible.
    private func trimConversationForRecovery(_ messages: inout [AnthropicMessage], seededHistoryPairs: inout Int) -> Bool {
        guard messages.count > 1 else { return false }

        // Strategy 1: truncate large tool_result blocks to 500 chars. Only blocks
        // that actually shrink count as progress: an already-truncated block is
        // 500 chars + marker, and re-"truncating" it to the identical string must
        // not report success, or recovery livelocks — retrying an unchanged
        // payload until the iteration budget is gone.
        var didShrink = false
        for i in 0..<messages.count {
            if case .blocks(var blocks) = messages[i].content {
                var modified = false
                for j in 0..<blocks.count {
                    if blocks[j].type == "tool_result",
                       let content = blocks[j].content,
                       content.count > 500 + Self.recoveryTruncationMarker.count {
                        blocks[j] = AnthropicContentBlock(
                            type: "tool_result", text: nil, id: nil, name: nil,
                            input: nil, toolUseId: blocks[j].toolUseId,
                            content: String(content.prefix(500)) + Self.recoveryTruncationMarker
                        )
                        modified = true
                        didShrink = true
                    }
                }
                if modified {
                    messages[i] = AnthropicMessage(role: messages[i].role, content: .blocks(blocks))
                }
            }
        }
        if didShrink {
            MajoorLogger.log("✂️ Truncated tool results to 500 chars")
            return true
        }

        // Strategy 2: drop the oldest exchange without losing the task goal or
        // orphaning a tool_result. The loop maintains strict user/assistant
        // alternation; string turns are seeded history / plan-approval text,
        // while .blocks turns are tool_use/tool_result exchanges.
        guard messages.count > 3 else { return false }
        if seededHistoryPairs > 0, isStringContent(messages[0]), isStringContent(messages[1]),
           lastStringUserIndex(messages) >= 2 {
            // Front pair is genuinely seeded conversation history (the counter
            // distinguishes it from a structurally identical task + pipeline
            // plan/approval string pair, which must survive) and a later string
            // user turn still anchors the goal — drop the oldest history pair.
            messages.removeFirst(2)
            seededHistoryPairs -= 1
        } else if messages[1].role == "assistant", messages[2].role == "user" {
            // Otherwise remove the exchange at [1, 2], preserving messages[0]
            // (the goal). An adjacent assistant+user pair is self-contained
            // (a tool_use turn plus its tool_result answer), so removing it
            // keeps both alternation and tool pairing intact. The old code
            // removed [0, 1] instead, which lost the task statement AND left a
            // leading orphaned tool_result the API rejects with a 400.
            messages.removeSubrange(1...2)
        } else {
            return false
        }
        MajoorLogger.log("✂️ Removed oldest exchange, \(messages.count) messages remain")
        return true
    }

    private func isStringContent(_ message: AnthropicMessage) -> Bool {
        if case .string = message.content { return true }
        return false
    }

    private func lastStringUserIndex(_ messages: [AnthropicMessage]) -> Int {
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            if messages[i].role == "user" && isStringContent(messages[i]) { return i }
        }
        return -1
    }
}

// AgentLoop.swift
// Majoor — The Agent Loop (THE BRAIN)
//
// Cycle: Send to Claude → Claude returns tool calls → Execute locally → Send results back → Repeat
// With: memory injection, model routing, task persistence, usage tracking.
// Nonisolated — the loop runs off the main thread. It knows nothing about the
// UI: it records through its host's TaskRecorder, publishes SessionEvents,
// reads and writes thread history, and asks its host for approvals.

import Foundation
import CryptoKit

/// Picks the provider and MCP tool sets for a task. Tests inject a scripted
/// provider through it; the app itself routes through `TierRoutingRouter`
/// (`Core/Router/TierRouter.swift`), which also carries the tier and the tool
/// gate.
typealias ProviderRouter = @Sendable (String) async -> (provider: any LLMProvider, toolSets: [String])

/// Pipeline plan state for one run: which numbered step each tool call
/// belongs to, and how each step is going. Shared between the run frame and
/// the tool phase, hence a locked class rather than an inout array.
nonisolated final class PipelineState: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [PipelineStep] = []

    var count: Int { lock.withLock { steps.count } }
    var isEmpty: Bool { count == 0 }

    func replace(_ newSteps: [PipelineStep]) { lock.withLock { steps = newSteps } }
    func clear() { lock.withLock { steps = [] } }
    func snapshot() -> [PipelineStep] { lock.withLock { steps } }
    func dtos() -> [PipelineStepDTO] { snapshot().enumerated().map { PipelineStepDTO(index: $0.offset, $0.element) } }

    func update(at index: Int, status: PipelineStepStatus, result: String? = nil, error: String? = nil) {
        lock.withLock {
            guard index < steps.count else { return }
            steps[index].status = status
            if let result { steps[index].result = result }
            if let error { steps[index].error = error }
        }
    }

    func addToolCall(at index: Int, name: String) {
        lock.withLock {
            guard index < steps.count else { return }
            steps[index].toolCalls.append(name)
        }
    }

    func setEnabled(_ index: Int, _ enabled: Bool) {
        lock.withLock {
            guard index < steps.count else { return }
            steps[index].enabled = enabled
        }
    }
}

final nonisolated class AgentLoop: @unchecked Sendable {

    private let tools: [any AgentTool]
    private let route: TierRoutingRouter
    private let maxIterations = 75
    /// How many times one run may recover from an output-limit cut before giving up
    /// honestly. Bounded because each attempt costs a full turn.
    private let maxTruncationRecoveries = 3
    /// Cap on any single tool result entering the conversation (chars, ≈7.5k tokens)
    private let maxToolResultChars = 30_000
    private let maxResponseTextLength = 1000

    /// Router v2 (Phase 2 step 3): tier, provider and tool gate from the
    /// privacy preset.
    static let defaultRouter: TierRoutingRouter = { input in
        await TierRouter.shared.route(input)
    }

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
    16. Reminders — for "remind me …" use create_reminder. Prefer delay_minutes for relative times ("in 20 minutes", "in 2 hours"); use 'when' only for an absolute local time, computed from the current date and time zone given below. Never create a calendar event for a reminder unless the user asks for a calendar event. Use list_reminders / cancel_reminder to show or cancel them.
    17. Questions — when you are genuinely blocked on a decision only the user can make, call ask_owner once for that blocker, with concrete options when there are a few; it waits for their reply. Never use it to ask permission (the app asks for permission itself) and never ask in a text response.

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

    init(tools: [any AgentTool], routing: @escaping TierRoutingRouter = AgentLoop.defaultRouter) {
        self.tools = tools
        self.route = routing
    }

    /// Tests: a provider and tool sets, with no tier and no tool gate.
    init(tools: [any AgentTool], route: @escaping ProviderRouter) {
        self.tools = tools
        self.route = { input in
            let routed = await route(input)
            return RoutingDecision(provider: routed.provider, toolSets: routed.toolSets)
        }
    }

    // MARK: - Run

    func run(userInput: String, host: any AgentLoopHost) async throws -> TaskResult {
        MajoorLogger.log("🚀 Task: \(userInput)")
        let thread = host.threadKey

        // 1. Hybrid routing: keyword fast-path or LLM classification
        // Include recent conversation context so the router understands follow-ups
        let historySnapshot = host.history.snapshot(thread: thread)
        let recentContext = historySnapshot.suffix(3).map { $0.userInput }.joined(separator: " | ")
        let routingInput = recentContext.isEmpty ? userInput : "\(userInput) [recent context: \(recentContext)]"
        let decision = await route(routingInput)
        let provider = decision.provider
        let routedToolSets = decision.toolSets
        let usageTier = decision.tier ?? .frontier

        // Merge tool sets from recent conversations so follow-ups retain access
        var toolSets = routedToolSets
        for ts in historySnapshot.flatMap({ $0.toolSets }) where !toolSets.contains(ts) {
            toolSets.append(ts)
        }

        // 2. Retrieve relevant memories, inject current date, and MCP summary
        // Memories are Majoor's own state (PRD §6). When the privacy preset
        // keeps that class off this tier they stay out of the prompt, not only
        // out of the tool list.
        let memoryAllowed = decision.gate?.allows(.majoorState) ?? true
        let memoryContext = memoryAllowed ? MemoryRetriever.relevantContext(for: userInput) : ""
        if !memoryAllowed { MajoorLogger.log("🔒 Memory context withheld on tier \(usageTier.letter)") }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let dateContext = "\n\nCurrent date and time: \(dateFormatter.string(from: Date())) (\(TimeZone.current.identifier))"
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
        // Router v2: offer only the tools whose data class the privacy preset
        // allows on this tier. A call to anything else is answered, never run.
        var withheldTools: [String: String] = [:]
        if let gate = decision.gate {
            // ask_owner is exempt: it sends nothing anywhere but the owner's own
            // thread, and the owner decides what to answer.
            for tool in activeTools where !gate.allows(tool) && tool.name != AskOwnerTool.toolName {
                withheldTools[tool.name] = gate.refusal(toolName: tool.name, dataClass: tool.dataClass)
            }
            if !withheldTools.isEmpty {
                activeTools.removeAll { withheldTools[$0.name] != nil }
                MajoorLogger.log("🔒 \(withheldTools.count) tool(s) withheld on tier \(gate.tier.letter): \(withheldTools.keys.sorted().joined(separator: ", "))")
            }
        }
        let anthropicTools = activeTools.map { $0.toAnthropicTool() }

        // 4. Build messages — inject all conversations from the last 10 minutes
        var messages: [AnthropicMessage] = []
        if !historySnapshot.isEmpty {
            MajoorLogger.log("📎 Injecting \(historySnapshot.count) recent conversation(s) as context")
            for prev in historySnapshot {
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
        var seededHistoryPairs = historySnapshot.count

        var totalInputTokens = 0
        var totalOutputTokens = 0
        var iteration = 0
        var toolSummaries: [String] = []
        var truncationRecoveries = 0
        /// Text salvaged from turns cut off at the output limit, prepended to the
        /// eventual answer. Consumed exactly once and cleared whenever the model
        /// moves on to something else — a stale prefix would otherwise be glued
        /// onto an unrelated later answer and become that task's summary.
        var truncatedPrefix = ""
        let pipeline = PipelineState()

        // 5. Agent loop
        while iteration < maxIterations {
            iteration += 1
            MajoorLogger.log("🔄 Iteration \(iteration)/\(maxIterations) [\(provider.name)]")
            await record(TaskStep(timestamp: Date(), type: .thinking, description: "Thinking... (\(iteration))", detail: nil), host: host)

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
                        // Trimming can drop the assistant turn a salvaged partial came
                        // from, which voids the continuation contract — the model no
                        // longer has any record of having written it. Discard rather
                        // than risk gluing an abandoned draft onto a later answer.
                        truncatedPrefix = ""
                        await record(TaskStep(timestamp: Date(), type: .thinking, description: "Context too large — trimming history and retrying...", detail: nil), host: host)
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
                await record(TaskStep(timestamp: Date(), type: .error, description: errorDesc, detail: nil), host: host)
                await host.recorder.fail(message: errorDesc)
                throw error
            } catch is CancellationError {
                // URLSession surfaces Stop as URLError(.cancelled), which the provider
                // maps to CancellationError. Record it as stopped and rethrow so the
                // session reports "stopped" rather than a failure.
                _ = await fail(host, .cancelled)
                throw CancellationError()
            } catch {
                MajoorLogger.error("❌ Unexpected error: \(error.localizedDescription)")
                await record(TaskStep(timestamp: Date(), type: .error, description: error.localizedDescription, detail: nil), host: host)
                await host.recorder.fail(message: error.localizedDescription)
                throw error
            }

            if let usage {
                totalInputTokens += usage.inputTokens
                totalOutputTokens += usage.outputTokens

                // Track usage per API call
                UsageStore.shared.recordUsage(
                    model: provider.model,
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    tier: usageTier
                )
                // Keep attribution current every iteration, not only on the success path.
                await host.recorder.addUsage(input: usage.inputTokens, output: usage.outputTokens, model: provider.model)
            }

            let totalTokens = totalInputTokens + totalOutputTokens
            let sessionUSD = CostConfig.estimateCost(model: provider.model, inputTokens: totalInputTokens, outputTokens: totalOutputTokens, tier: usageTier)
            await host.emit(.cost(id: host.sessionId, tokensIn: totalInputTokens, tokensOut: totalOutputTokens,
                                  sessionUSD: sessionUSD, dayUSD: UsageStore.shared.todayUsage().totalCost))
            if host.budget.isExceeded(by: totalTokens) || TokenBudget.dailyCapExceeded() {
                MajoorLogger.error("❌ Budget exceeded: \(totalTokens) tokens this session")
                throw await fail(host, .budgetExceeded)
            }

            switch response {
            case .text(let rawText):
                // Check for pipeline confirmation marker. Tested against the raw turn,
                // not the salvaged-prefix concatenation: a plan is a fresh proposal
                // rather than the continuation of an interrupted answer, so any
                // partial is dropped here instead of being glued onto the plan the
                // user is shown and asked to approve.
                if rawText.contains("%%PIPELINE_CONFIRM%%") {
                    truncatedPrefix = ""
                    let planText = rawText.replacingOccurrences(of: "%%PIPELINE_CONFIRM%%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    await proposePlan(planText, pipeline: pipeline, host: host, messages: &messages)
                    continue
                }

                // A turn with no text is not an answer — thinking may have eaten the
                // whole budget, or the content was entirely block types parseResponse
                // skips. Completing here is how a blank "Task Complete" got shipped.
                //
                // Tested against THIS turn's text, not the salvaged concatenation: a
                // prefix left over from an earlier cut would otherwise stand in for an
                // answer that never arrived, and the run would complete on a fragment.
                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    if !truncatedPrefix.isEmpty {
                        await record(TaskStep(timestamp: Date(), type: .response, description: truncatedPrefix,
                                              detail: "Partial answer — cut off at the output limit"), host: host)
                    }
                    throw await fail(host, .emptyResponse)
                }

                // This turn is the answer, so fold in anything salvaged from an earlier
                // output-limit cut and clear it — the prefix belongs to exactly one
                // answer, and a stale one would end up as an unrelated task's summary.
                let text = truncatedPrefix + rawText
                truncatedPrefix = ""

                MajoorLogger.log("✅ Done after \(iteration) iterations")
                await record(TaskStep(timestamp: Date(), type: .response, description: text, detail: nil), host: host)
                let summary = summarize(text)
                // The recorder serializes finishing: if a stop already failed this
                // run, complete() returns false and the success must not be reported.
                guard !Task.isCancelled, await host.recorder.complete(summary: summary) else {
                    _ = await fail(host, .cancelled)
                    throw CancellationError()
                }

                // 6. Store conversation for continuity
                host.history.append(thread: thread, ConversationEntry(
                    userInput: userInput,
                    responseText: String(text.prefix(maxResponseTextLength)),
                    toolSummaries: Array(toolSummaries.suffix(10)),
                    toolSets: toolSets,
                    timestamp: Date()
                ))

                let finalSteps = await host.recorder.steps.map(\.taskStep)
                return TaskResult(summary: summary, steps: finalSteps, tokensUsed: totalTokens)

            case .truncated(let partialText, let calls, let rawContent):
                guard truncationRecoveries < maxTruncationRecoveries else {
                    // Don't throw away what was already paid for: the accumulator may
                    // hold several full turns of real output, and the frame is about
                    // to unwind. Put it in the trail so it survives into SQLite.
                    if !truncatedPrefix.isEmpty {
                        await record(TaskStep(timestamp: Date(), type: .response, description: truncatedPrefix,
                                              detail: "Partial answer — cut off at the output limit"), host: host)
                    }
                    throw await fail(host, .truncated)
                }
                truncationRecoveries += 1
                MajoorLogger.log("✂️ Output limit hit — recovery \(truncationRecoveries)/\(maxTruncationRecoveries)")

                if calls.isEmpty {
                    // Text-only cut. Echo *only* completed text blocks: a turn severed
                    // mid-thinking carries a thinking block whose signature was never
                    // emitted, and the API rejects those; max_tokens can also return an
                    // empty content array, which is rejected outright. Dropping
                    // reasoning blocks is safe here precisely because this branch sends
                    // a plain user turn rather than a tool_result continuation.
                    let echo = rawContent.filter { $0.type == "text" && !($0.text ?? "").isEmpty }
                    guard !echo.isEmpty else {
                        // The cut landed before any visible text — usually inside
                        // thinking, which is the *common* shape because `display`
                        // defaults to "omitted". There is nothing legal to echo (an
                        // unsigned thinking block is rejected, an empty content array
                        // outright), so don't append an assistant turn at all. A user
                        // nudge still changes the prompt, so the retry isn't a
                        // byte-identical resend and the run keeps making progress
                        // instead of burning the whole recovery budget on nothing.
                        await record(TaskStep(timestamp: Date(), type: .thinking,
                                              description: "Output limit reached before any answer — retrying more concisely", detail: nil), host: host)
                        messages.append(AnthropicMessage(role: "user", content: .string(
                            "Your previous attempt hit the output limit before producing any answer. Be more concise and answer directly.")))
                        continue
                    }
                    truncatedPrefix += partialText
                    await record(TaskStep(timestamp: Date(), type: .thinking,
                                          description: "Response hit the output limit — asking Claude to continue", detail: nil), host: host)
                    messages.append(AnthropicMessage(role: "assistant", content: .blocks(echo)))
                    messages.append(AnthropicMessage(role: "user", content: .string(
                        "Your previous message was cut off at the output limit. Continue exactly where it stopped — do not repeat any text you already wrote and do not start over.")))
                    continue
                }

                // Truncated tool_use: the input JSON may be severed mid-object, so
                // nothing here is executed — the calls are only answered.
                guard let turn = unexecutedTurn(rawContent: rawContent, note:
                    "Your response hit the output limit before this tool call was complete, so it was NOT executed. Split the work into smaller steps and call again with smaller arguments.")
                else { throw await fail(host, .truncated) }

                await record(TaskStep(timestamp: Date(), type: .error,
                                      description: "Response truncated — \(calls.count) tool call(s) not executed",
                                      detail: partialText.isEmpty ? nil : String(partialText.prefix(500))), host: host)
                messages.append(turn.assistant)
                messages.append(turn.reply)
                continue

            case .toolCalls(let calls, let rawContent):
                // The model moved on to tool work, so any salvaged partial belongs to
                // an abandoned draft — dropping it keeps it out of the final summary.
                truncatedPrefix = ""
                let (aMsg, rMsg, summaries) = try await handleToolCalls(calls, host: host, pipeline: pipeline, assistantContent: rawContent, activeTools: activeTools, withheld: withheldTools, userInput: userInput)
                messages.append(aMsg)
                messages.append(rMsg)
                toolSummaries.append(contentsOf: summaries)

            case .mixed(let text, let calls, let rawContent):
                truncatedPrefix = ""
                // Check for pipeline confirmation in mixed responses too
                if text.contains("%%PIPELINE_CONFIRM%%") {
                    let planText = text.replacingOccurrences(of: "%%PIPELINE_CONFIRM%%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    await proposePlan(planText, pipeline: pipeline, host: host, messages: &messages)
                    continue
                }

                MajoorLogger.log("📝 \(text.prefix(100))...")
                let (aMsg, rMsg, summaries) = try await handleToolCalls(calls, host: host, pipeline: pipeline, assistantContent: rawContent, activeTools: activeTools, withheld: withheldTools, userInput: userInput)
                messages.append(aMsg)
                messages.append(rMsg)
                toolSummaries.append(contentsOf: summaries)
            }
        }

        // Running out of iterations is not success. This used to write `.completed`
        // with "Completed (max iterations)", which meant the hardest tasks — exactly
        // the ones that exhaust the budget — were the ones most likely to be filed
        // as wins. Attribution is already current from the per-iteration write above.
        MajoorLogger.log("⚠️ Max iterations reached")

        // Keep the history entry so a follow-up task still has the tool context, but
        // tell the truth in it — a false "completed" here trains the next task on a lie.
        host.history.append(thread: thread, ConversationEntry(
            userInput: userInput,
            responseText: "(the previous task was stopped after \(maxIterations) iterations without finishing)",
            toolSummaries: Array(toolSummaries.suffix(10)),
            toolSets: toolSets,
            timestamp: Date()
        ))

        throw await fail(host, .iterationLimit)
    }

    // MARK: - Recording

    private func record(_ step: TaskStep, host: any AgentLoopHost) async {
        await host.recorder.append(StepDTO(step))
    }

    /// The one place a run becomes `.failed` for a non-transport reason. The
    /// recorder writes status and persists atomically; the returned error is
    /// thrown by the caller so the session sees a failure instead of a return.
    private func fail(_ host: any AgentLoopHost, _ reason: IncompleteReason) async -> LLMError {
        MajoorLogger.error("❌ \(reason.userFacing)")
        await record(TaskStep(timestamp: Date(), type: .error, description: reason.userFacing, detail: nil), host: host)
        await host.recorder.fail(reason)
        return LLMError.incomplete(reason: reason)
    }

    // MARK: - Pipeline plan

    /// Shows a proposed plan, asks the session for approval, and appends the
    /// resulting assistant/user turns. The approval and denial strings are
    /// prompt text and must not change.
    private func proposePlan(_ planText: String, pipeline: PipelineState, host: any AgentLoopHost,
                             messages: inout [AnthropicMessage]) async {
        MajoorLogger.log("🔄 Pipeline plan proposed, waiting for approval...")
        pipeline.replace(parsePipelineSteps(from: planText))
        await record(TaskStep(timestamp: Date(), type: .response, description: planText, detail: nil), host: host)
        await host.emit(.pipelinePlan(id: host.sessionId, text: planText, steps: pipeline.dtos()))

        let decision = await host.requestApproval(ApprovalDraft(
            title: "Majoor Pipeline", body: planText, category: NotificationManager.pipelineConfirmCategory,
            riskClass: .r1, actionSignature: "pipeline", isPipelinePlan: true, pipelineSteps: pipeline.dtos()))

        messages.append(AnthropicMessage(role: "assistant", content: .string(planText)))
        if decision.approved {
            let skipped = Set(decision.skippedStepIndices).filter { $0 >= 0 && $0 < pipeline.count }.sorted()
            var approvalMsg = "User approved. Execute all steps now."
            if !skipped.isEmpty {
                let skippedList = skipped.map { String($0 + 1) }.joined(separator: ", ")
                approvalMsg = "User approved but wants to SKIP step(s): \(skippedList). Execute the remaining steps only."
                for index in skipped {
                    pipeline.setEnabled(index, false)
                    pipeline.update(at: index, status: .skipped)
                    await host.emit(.pipelineStep(id: host.sessionId, index: index, status: PipelineStepStatus.skipped.rawValue, result: nil, error: nil))
                }
            }
            if let feedback = decision.feedback {
                approvalMsg += " User note: \(feedback)"
            }
            messages.append(AnthropicMessage(role: "user", content: .string(approvalMsg)))
            MajoorLogger.log("✅ Pipeline approved — executing")
        } else {
            var denialMsg = "User declined."
            if let feedback = decision.feedback {
                denialMsg += " User feedback: \(feedback)"
            } else {
                denialMsg += " Ask what they'd like to do differently."
            }
            messages.append(AnthropicMessage(role: "user", content: .string(denialMsg)))
            MajoorLogger.log("❌ Pipeline declined — asking follow-up")
            pipeline.clear()
            await host.emit(.pipelinePlan(id: host.sessionId, text: "", steps: []))
        }
    }

    private func updatePipeline(_ pipeline: PipelineState, host: any AgentLoopHost, toolName: String, arguments: [String: String],
                                status: PipelineStepStatus, result: String? = nil, error: String? = nil, addCall: Bool = false) async {
        guard !pipeline.isEmpty,
              let index = matchToolToPipelineStep(toolName, arguments: arguments, steps: pipeline.snapshot()) else { return }
        if addCall { pipeline.addToolCall(at: index, name: toolName) }
        pipeline.update(at: index, status: status, result: result, error: error)
        await host.emit(.pipelineStep(id: host.sessionId, index: index, status: status.rawValue, result: result, error: error))
    }

    /// Builds an API-legal assistant echo plus paired `tool_result` answers for a turn
    /// whose tool calls must NOT run. Drops `tool_use` blocks that arrived without an
    /// id: `parseResponse` skips those when building `ToolCall`s, so echoing the raw
    /// content while answering only the parsed calls would leave a `tool_use` with no
    /// `tool_result` — an immediate 400 on the very request meant to recover. Returns
    /// nil when nothing answerable survives.
    private func unexecutedTurn(rawContent: [AnthropicContentBlock], note: String)
        -> (assistant: AnthropicMessage, reply: AnthropicMessage)? {
        // Mirror exactly what parseResponse accepts (it requires BOTH id and name), and
        // drop empty text blocks, which the API also rejects in an assistant turn. A
        // looser filter here would 400 the very request that exists to recover.
        let echo = rawContent.filter {
            switch $0.type {
            case "tool_use": return $0.id != nil && $0.name != nil
            case "text":     return !($0.text ?? "").isEmpty
            default:         return true
            }
        }
        let ids = echo.compactMap { $0.type == "tool_use" ? $0.id : nil }
        guard !echo.isEmpty, !ids.isEmpty else { return nil }
        let blocks = ids.map {
            AnthropicContentBlock(type: "tool_result", text: nil, id: nil, name: nil,
                                  input: nil, toolUseId: $0, content: note, isError: true)
        }
        return (AnthropicMessage(role: "assistant", content: .blocks(echo)),
                AnthropicMessage(role: "user", content: .blocks(blocks)))
    }

    // MARK: - Tool Execution

    /// Wraps the tool phase so a throw from inside it cannot strand the task in
    /// `.running`. `performToolCalls` throws on cancellation, and that unwinds past
    /// `run()`'s do/catch — which covers only `provider.complete` — so without this
    /// the row is never persisted and a stopped task simply vanishes on restart.
    private func handleToolCalls(
        _ toolCalls: [ToolCall],
        host: any AgentLoopHost,
        pipeline: PipelineState,
        assistantContent: [AnthropicContentBlock],
        activeTools: [any AgentTool],
        withheld: [String: String],
        userInput: String
    ) async throws -> (assistant: AnthropicMessage, result: AnthropicMessage, toolSummaries: [String]) {
        do {
            return try await performToolCalls(toolCalls, host: host, pipeline: pipeline, assistantContent: assistantContent,
                                              activeTools: activeTools, withheld: withheld, userInput: userInput)
        } catch {
            _ = await fail(host, error is CancellationError ? .cancelled : .toolPhaseFailure)
            throw error
        }
    }

    /// `assistantContent` is the model's response content blocks verbatim.
    /// `withheld` maps the tools the privacy preset kept off this tier to the
    /// tool result the model gets if it asks for one anyway.
    private func performToolCalls(
        _ toolCalls: [ToolCall],
        host: any AgentLoopHost,
        pipeline: PipelineState,
        assistantContent: [AnthropicContentBlock],
        activeTools: [any AgentTool],
        withheld: [String: String],
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
            // ask_owner is answered by the session's origin channel, not executed.
            let isQuestion = call.toolName == AskOwnerTool.toolName && activeTools.contains { $0.name == AskOwnerTool.toolName }
            let questionText = isQuestion ? AskOwnerTool.question(from: call.arguments) : nil
            await record(TaskStep(timestamp: Date(), type: .toolCall,
                                  description: isQuestion ? "Asked you: \(questionText ?? "(no question)")" : "Calling \(call.toolName)",
                                  detail: String(call.arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", ").prefix(1000))), host: host)
            await updatePipeline(pipeline, host: host, toolName: call.toolName, arguments: call.arguments, status: .running, addCall: true)

            let output: String
            var resultTitle = "Result from \(call.toolName)"
            var confirmFeedback: String? = nil  // User feedback from confirmation (if any)
            if isQuestion {
                if let questionText {
                    let options = AskOwnerTool.options(from: call.arguments["options"])
                    let minutes = AskOwnerTool.timeoutMinutes(from: call.arguments["timeout_minutes"])
                    MajoorLogger.log("❓ Asking the owner (\(minutes) min): \(questionText.prefix(120))")
                    let answer = await host.ask(question: questionText, options: options, timeout: .seconds(minutes * 60))
                    try Task.checkCancellation()
                    (output, resultTitle) = AskOwnerTool.describe(answer, timeoutMinutes: minutes)
                } else {
                    output = "Error: ask_owner needs a non-empty question"
                }
            } else if let tool = activeTools.first(where: { $0.name == call.toolName }) {
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
                    mode: host.effectiveMode,
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
                    let sensitive = ConfirmationPolicy.isSensitive(toolName: call.toolName, requiresConfirmation: tool.requiresConfirmation, arguments: normalizedArgs)
                    let decision = await host.requestApproval(ApprovalDraft(
                        title: confirmTitle, body: confirmBody, category: confirmCategory,
                        riskClass: sensitive ? .r3 : .r1,
                        actionSignature: Self.actionSignature(toolName: call.toolName, arguments: normalizedArgs)))
                    if !decision.approved {
                        let feedbackNote = decision.feedback.map { " User feedback: \($0)" } ?? ""
                        output = "User declined to execute \(call.toolName).\(feedbackNote)"
                        await record(TaskStep(timestamp: Date(), type: .toolResult, description: "Declined: \(call.toolName)", detail: decision.feedback), host: host)
                        // Don't leave a matched pipeline step spinning at .running
                        // forever after a mid-pipeline decline
                        await updatePipeline(pipeline, host: host, toolName: call.toolName, arguments: call.arguments, status: .skipped)
                        resultBlocks.append(AnthropicContentBlock(type: "tool_result", text: nil, id: nil, name: nil, input: nil, toolUseId: call.id, content: output))
                        summaries.append("• \(call.toolName) → declined by user\(feedbackNote)")
                        continue
                    }

                    // If user approved with feedback, store it to append to the tool result
                    confirmFeedback = decision.feedback
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
            } else if let refusal = withheld[call.toolName] {
                // The tool exists but the privacy preset keeps it off this tier.
                MajoorLogger.log("🔒 Withheld: \(call.toolName)")
                output = refusal
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

            await record(TaskStep(timestamp: Date(), type: .toolResult, description: resultTitle, detail: String(output.prefix(500))), host: host)
            let isError = output.lowercased().hasPrefix("error")
            await updatePipeline(pipeline, host: host, toolName: call.toolName, arguments: call.arguments,
                                 status: isError ? .failed : .completed,
                                 result: isError ? nil : String(output.prefix(100)),
                                 error: isError ? String(output.prefix(200)) : nil)

            // Append user's confirmation feedback to the tool result so the LLM can adapt
            var finalOutput = boundedOutput
            if let feedback = confirmFeedback {
                finalOutput += "\n[User note: \(feedback)]"
            }
            resultBlocks.append(AnthropicContentBlock(type: "tool_result", text: nil, id: nil, name: nil, input: nil, toolUseId: call.id, content: finalOutput))
        }

        return (assistantMsg, AnthropicMessage(role: "user", content: .blocks(resultBlocks)), summaries)
    }

    /// Stable identity of an action for the approvals log and the Phase 2 trust
    /// ledger: the tool name plus its sorted, normalized arguments, hashed.
    static func actionSignature(toolName: String, arguments: [String: String]) -> String {
        let canonical = arguments.keys.sorted().map { "\($0)=\(String(arguments[$0]!.prefix(200)))" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data("\(toolName)|\(canonical)".utf8))
        return toolName + ":" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
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
    /// Returns the index into the pipeline steps, or nil if no match.
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

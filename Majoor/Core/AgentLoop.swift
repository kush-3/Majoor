// AgentLoop.swift
// Majoor — The Agent Loop (THE BRAIN)
//
// Cycle: Send to Claude → Claude returns tool calls → Execute locally → Send results back → Repeat
// Nonisolated — the loop runs off the main thread. UI updates go through MainActor.run.

import Foundation

final nonisolated class AgentLoop: @unchecked Sendable {
    
    private let provider: any LLMProvider
    private let tools: [any AgentTool]
    private let taskManager: TaskManager
    private let maxIterations = 25
    
    private let systemPrompt = """
    You are Majoor, an autonomous AI agent running as a native macOS menu bar app. \
    You perform tasks on the user's computer using your tools — silently, efficiently, and safely.

    YOUR CAPABILITIES:
    - File management: list, read, write, move, copy, delete, search files and create directories
    - Shell execution: run any shell command or script (Python, Node, Ruby, Bash) on the user's machine
    - Git & GitHub: check status, view diffs/logs, create branches, commit, push, and open PRs via gh CLI
    - Web research: search the web (Tavily), fetch and extract text from webpages, batch-fetch URLs for comparison
    - Project analysis: read project structure trees, run test suites with auto-detection

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
    """
    
    init(provider: any LLMProvider, tools: [any AgentTool], taskManager: TaskManager) {
        self.provider = provider
        self.tools = tools
        self.taskManager = taskManager
    }
    
    func execute(userInput: String) async throws -> TaskResult {
        MajoorLogger.log("🚀 Task: \(userInput)")
        
        let task = AgentTask(userInput: userInput)
        await MainActor.run { taskManager.addTask(task) }
        
        var messages: [AnthropicMessage] = [
            AnthropicMessage(role: "user", content: .string(userInput))
        ]
        let anthropicTools = tools.map { $0.toAnthropicTool() }
        
        var totalTokens = 0
        var iteration = 0
        var finalText = ""
        
        while iteration < maxIterations {
            iteration += 1
            MajoorLogger.log("🔄 Iteration \(iteration)/\(maxIterations)")
            
            let thinkStep = TaskStep(timestamp: Date(), type: .thinking, description: "Thinking... (\(iteration))", detail: nil)
            await MainActor.run { task.steps.append(thinkStep) }
            
            let (response, usage) = try await provider.complete(
                systemPrompt: systemPrompt,
                messages: messages,
                tools: anthropicTools
            )
            
            if let usage { totalTokens += usage.inputTokens + usage.outputTokens }
            
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
                return TaskResult(summary: summarize(text), steps: task.steps, tokensUsed: totalTokens)
                
            case .toolCalls(let calls):
                let (aMsg, rMsg) = try await handleToolCalls(calls, task: task)
                messages.append(aMsg)
                messages.append(rMsg)
                
            case .mixed(let text, let calls):
                MajoorLogger.log("📝 \(text.prefix(100))...")
                let (aMsg, rMsg) = try await handleToolCalls(calls, task: task, precedingText: text)
                messages.append(aMsg)
                messages.append(rMsg)
            }
        }
        
        MajoorLogger.log("⚠️ Max iterations reached")
        await MainActor.run {
            task.status = .completed
            task.summary = finalText.isEmpty ? "Completed (max iterations)" : summarize(finalText)
            task.completedAt = Date()
            task.tokensUsed = totalTokens
            task.modelUsed = provider.name
        }
        return TaskResult(summary: task.summary, steps: task.steps, tokensUsed: totalTokens)
    }
    
    // MARK: - Tool Execution
    
    private func handleToolCalls(
        _ toolCalls: [ToolCall],
        task: AgentTask,
        precedingText: String? = nil
    ) async throws -> (assistant: AnthropicMessage, result: AnthropicMessage) {
        
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
        for call in toolCalls {
            MajoorLogger.log("🔧 Tool: \(call.toolName)")
            let callStep = TaskStep(timestamp: Date(), type: .toolCall, description: "Calling \(call.toolName)", detail: call.arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
            await MainActor.run { task.steps.append(callStep) }
            
            let output: String
            if let tool = tools.first(where: { $0.name == call.toolName }) {
                do {
                    let result = try await tool.execute(arguments: call.arguments)
                    output = result.output
                } catch {
                    output = "Error: \(error.localizedDescription)"
                }
            } else {
                output = "Error: Tool '\(call.toolName)' not found"
            }
            
            let resultStep = TaskStep(timestamp: Date(), type: .toolResult, description: "Result from \(call.toolName)", detail: String(output.prefix(500)))
            await MainActor.run { task.steps.append(resultStep) }
            
            resultBlocks.append(AnthropicContentBlock(type: "tool_result", text: nil, id: nil, name: nil, input: nil, toolUseId: call.id, content: output))
        }
        
        return (assistantMsg, AnthropicMessage(role: "user", content: .blocks(resultBlocks)))
    }
    
    private func summarize(_ text: String) -> String {
        let first = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? text
        return first.count <= 150 ? first.trimmingCharacters(in: .whitespacesAndNewlines) : String(text.prefix(147)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

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
    You are Majoor, a capable AI assistant running as a native macOS app. \
    You help users by performing tasks on their computer using available tools.
    
    RULES:
    1. Be efficient — minimum tool calls needed.
    2. Be safe — NEVER delete without stating what will be deleted.
    3. Be clear — provide a concise summary when done.
    4. Complete the task fully. If a tool fails, try alternatives.
    5. For file listings, format output readably.
    6. Never run dangerous commands or access files outside ~/ unless asked.
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

// ToolProtocol.swift
// Majoor — Tool Protocol & Registry

import Foundation

nonisolated struct ToolResult: Sendable {
    let success: Bool
    let output: String
}

struct ToolParameter: Sendable {
    let name: String
    let type: String
    let description: String
    let enumValues: [String]?
    
    init(name: String, type: String = "string", description: String, enumValues: [String]? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }
}

// Protocol for all tools — nonisolated since tools do file/network I/O
protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: [ToolParameter] { get }
    var requiredParameters: [String] { get }
    var requiresConfirmation: Bool { get }
    
    func execute(arguments: [String: String]) async throws -> ToolResult
}

extension AgentTool {
    nonisolated func toAnthropicTool() -> AnthropicTool {
        var properties: [String: AnthropicProperty] = [:]
        for param in parameters {
            properties[param.name] = AnthropicProperty(
                type: param.type,
                description: param.description,
                enumValues: param.enumValues
            )
        }
        return AnthropicTool(
            name: name,
            description: description,
            inputSchema: AnthropicToolSchema(
                type: "object",
                properties: properties,
                required: requiredParameters.isEmpty ? nil : requiredParameters
            )
        )
    }
}

// MARK: - Tool Registry

nonisolated struct ToolRegistry: Sendable {
    static func defaultTools() -> [any AgentTool] {
        return [
            // File Management
            ListDirectoryTool(),
            ReadFileTool(),
            WriteFileTool(),
            MoveFileTool(),
            CopyFileTool(),
            DeleteFileTool(),
            SearchFilesTool(),
            GetFileInfoTool(),
            CreateDirectoryTool(),
            // Shell & Code Execution
            ExecuteShellTool(),
            ExecuteScriptTool(),
            ReadProjectStructureTool(),
            RunTestsTool(),
            // Git Operations
            GitStatusTool(),
            GitDiffTool(),
            GitLogTool(),
            GitBranchTool(),
            GitCheckoutTool(),
            GitCommitTool(),
            GitPushTool(),
            GitCreatePRTool(),
            // Web Research
            WebSearchTool(),
            FetchWebpageTool(),
            FetchMultipleURLsTool(),
        ]
    }
}

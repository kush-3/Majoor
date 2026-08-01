// ToolProtocol.swift
// Majoor — Tool Protocol & Registry

import Foundation

nonisolated struct ToolResult: Sendable {
    let success: Bool
    let output: String
}

// nonisolated: constructed off-main (MCPToolBridge builds these on the MCP
// actor's executor when bridging discovered tools) — without this the init is
// MainActor-isolated under default isolation and traps runtime isolation checks
nonisolated struct ToolParameter: Sendable {
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
    /// True for tools that cannot change any state — they never prompt, even
    /// in Manual permission mode. Defaults to false (see extension below).
    var isReadOnly: Bool { get }

    func execute(arguments: [String: String]) async throws -> ToolResult
}

extension AgentTool {
    var isReadOnly: Bool { false }

    /// Optional human-readable preview for confirmation prompts — used when a
    /// raw argument dump would be meaningless to the user (e.g. an opaque
    /// event_id). Return nil to use the default arguments summary.
    func confirmationPreview(arguments: [String: String]) async -> String? { nil }
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
            ReadPDFTool(),
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
            // Calendar (EventKit)
            ReadCalendarEventsTool(),
            CreateCalendarEventTool(),
            UpdateCalendarEventTool(),
            DeleteCalendarEventTool(),
            // Email (Gmail)
            FetchEmailsTool(),
            ReadEmailTool(),
            SearchEmailsTool(),
            DraftEmailTool(),
            SendEmailTool(),
            ReplyToEmailTool(),
            // Long-Term Memory
            SaveMemoryTool(),
            SearchMemoryTool(),
        ]
    }
}

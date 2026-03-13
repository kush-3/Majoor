// MCPToolBridge.swift
// Majoor — Bridges MCP tools into the AgentTool protocol
//
// Wraps an MCPToolDefinition so it looks like a native AgentTool.
// Tool names are prefixed with the server name to avoid collisions.

import Foundation

nonisolated struct MCPToolBridge: AgentTool, Sendable {
    let name: String            // Prefixed: "github__create_issue"
    let originalName: String    // Original MCP name: "create_issue"
    let description: String
    let parameters: [ToolParameter]
    let requiredParameters: [String]
    let requiresConfirmation = false
    let serverName: String

    init(serverName: String, tool: MCPToolDefinition) {
        self.name = "\(serverName)__\(tool.name)"
        self.originalName = tool.name
        self.description = "[\(serverName)] \(tool.description)"
        self.serverName = serverName

        if let schema = tool.inputSchema {
            self.parameters = schema.properties.map { (propName, prop) in
                ToolParameter(
                    name: propName,
                    type: prop.type,
                    description: prop.description,
                    enumValues: prop.enumValues
                )
            }
            self.requiredParameters = schema.required
        } else {
            self.parameters = []
            self.requiredParameters = []
        }
    }

    func execute(arguments: [String: String]) async throws -> ToolResult {
        // Prefer rawInputJSON if available (preserves arrays, objects, numbers).
        // Falls back to string arguments for simple cases.
        return try await executeWithRawJSON(nil, stringArgs: arguments)
    }

    /// Execute with raw JSON arguments (preserves complex types for MCP).
    func executeWithRawJSON(_ rawJSON: Data?, stringArgs: [String: String]) async throws -> ToolResult {
        guard let client = await MCPServerManager.shared.client(for: serverName) else {
            return ToolResult(success: false, output: "MCP server '\(serverName)' is not running.")
        }

        let anyArgs: [String: Any]
        if let rawJSON, let parsed = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] {
            anyArgs = parsed
        } else {
            anyArgs = stringArgs.mapValues { $0 as Any }
        }

        let result = try await client.callTool(name: originalName, arguments: anyArgs)
        return ToolResult(success: !result.isError, output: result.content)
    }
}

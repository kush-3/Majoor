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
        // Safety net: ensure the server is running (handles mid-session crashes)
        do {
            try await MCPServerManager.shared.ensureRunning(serverName)
        } catch {
            return ToolResult(success: false, output: "\(serverName.capitalized) integration failed to start: \(error.localizedDescription). Check your token in Settings > Integrations.")
        }

        guard let client = await MCPServerManager.shared.client(for: serverName) else {
            return ToolResult(success: false, output: "\(serverName.capitalized) integration is not running. Check your token in Settings > Integrations.")
        }

        let anyArgs: [String: Any]
        if let rawJSON, let parsed = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] {
            anyArgs = parsed
        } else {
            anyArgs = stringArgs.mapValues { $0 as Any }
        }

        do {
            let result = try await client.callTool(name: originalName, arguments: anyArgs)
            // Detect auth errors in tool results
            if result.isError {
                let content = result.content.lowercased()
                if content.contains("401") || content.contains("403")
                    || content.contains("unauthorized") || content.contains("forbidden")
                    || content.contains("authentication") || content.contains("invalid token") {
                    return ToolResult(success: false, output: "\(serverName.capitalized): authentication failed. Your token may have expired. Update it in Settings > Integrations.")
                }
            }
            return ToolResult(success: !result.isError, output: result.content)
        } catch {
            return ToolResult(success: false, output: "\(serverName.capitalized) tool '\(originalName)' failed: \(error.localizedDescription)")
        }
    }
}

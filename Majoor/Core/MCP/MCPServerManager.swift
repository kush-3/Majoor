// MCPServerManager.swift
// Majoor — Manages all MCP server connections
//
// Starts configured servers on launch, monitors health, restarts on crash.
// Provides server status and tool summaries for the two-pass loading system.

import Foundation

actor MCPServerManager {

    static let shared = MCPServerManager()

    struct ServerStatus: Sendable {
        let name: String
        let isRunning: Bool
        let toolCount: Int
        let error: String?
    }

    private var clients: [String: MCPClient] = [:]
    private var configs: [String: MCPServerConfig] = [:]
    private var serverErrors: [String: String] = [:]
    private var monitorTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Lifecycle

    /// Load config and start all configured servers.
    func startAll() async {
        configs = MCPConfig.load()
        guard !configs.isEmpty else {
            MajoorLogger.log("MCP: No servers configured")
            return
        }

        MajoorLogger.log("MCP: Starting \(configs.count) server(s)...")
        for (name, config) in configs {
            await startServer(name: name, config: config)
        }
    }

    /// Stop all servers gracefully.
    func stopAll() async {
        for (name, _) in clients {
            monitorTasks[name]?.cancel()
            monitorTasks[name] = nil
        }
        for (_, client) in clients {
            await client.shutdown()
        }
        clients.removeAll()
        serverErrors.removeAll()
        MajoorLogger.log("MCP: All servers stopped")
    }

    // MARK: - Server Management

    func startServer(name: String, config: MCPServerConfig) async {
        // Stop existing instance if any
        if let existing = clients[name] {
            await existing.shutdown()
        }
        monitorTasks[name]?.cancel()

        // Skip servers that have keychain: env vars with missing tokens
        if let envConfig = config.env {
            var missingKeys: [String] = []
            for (envKey, envValue) in envConfig {
                if envValue.hasPrefix("keychain:") {
                    let keychainKey = String(envValue.dropFirst("keychain:".count))
                    if KeychainManager.shared.retrieve(key: keychainKey) == nil {
                        missingKeys.append(envKey)
                    }
                }
            }
            if !missingKeys.isEmpty {
                serverErrors[name] = "Missing token(s). Add via Settings > Integrations."
                MajoorLogger.log("MCP[\(name)] skipped — no token stored for: \(missingKeys.joined(separator: ", "))")
                return
            }
        }

        let resolvedEnv = MCPConfig.resolveEnv(config.env)

        let client = MCPClient(serverName: name)
        clients[name] = client
        serverErrors[name] = nil

        do {
            try await client.start(
                command: config.command,
                args: config.args ?? [],
                env: resolvedEnv
            )
            let tools = await client.discoveredTools
            MajoorLogger.log("MCP[\(name)] ready with \(tools.count) tool(s)")

            // Start health monitor
            monitorTasks[name] = Task { [weak self] in
                await self?.monitorServer(name: name, config: config)
            }
        } catch {
            serverErrors[name] = error.localizedDescription
            MajoorLogger.error("MCP[\(name)] failed to start: \(error)")
        }
    }

    func stopServer(name: String) async {
        monitorTasks[name]?.cancel()
        monitorTasks[name] = nil

        if let client = clients.removeValue(forKey: name) {
            await client.shutdown()
        }
        serverErrors[name] = nil
    }

    // MARK: - Access

    func client(for serverName: String) -> MCPClient? {
        clients[serverName]
    }

    /// Get status of all configured servers.
    func allStatus() async -> [ServerStatus] {
        var statuses: [ServerStatus] = []
        for (name, _) in configs {
            if let client = clients[name] {
                let running = await client.isRunning
                let toolCount = await client.discoveredTools.count
                statuses.append(ServerStatus(
                    name: name,
                    isRunning: running,
                    toolCount: toolCount,
                    error: serverErrors[name]
                ))
            } else {
                statuses.append(ServerStatus(
                    name: name,
                    isRunning: false,
                    toolCount: 0,
                    error: serverErrors[name]
                ))
            }
        }
        return statuses
    }

    /// Get a summary of available MCP servers for system prompt injection.
    func serverSummary() async -> String? {
        var lines: [String] = []
        for (name, _) in configs {
            if let client = clients[name] {
                let running = await client.isRunning
                if running {
                    let tools = await client.discoveredTools
                    let toolNames = tools.prefix(5).map(\.name).joined(separator: ", ")
                    let suffix = tools.count > 5 ? ", ..." : ""
                    lines.append("- \(name): \(tools.count) tools (\(toolNames)\(suffix))")
                }
            }
        }
        guard !lines.isEmpty else { return nil }
        return "MCP INTEGRATIONS AVAILABLE:\n" + lines.joined(separator: "\n") + "\nThese tools are ready to use directly — no setup needed. Call them by name."
    }

    /// Get ALL bridged AgentTools from all running servers.
    func allAvailableTools() async -> [MCPToolBridge] {
        var tools: [MCPToolBridge] = []
        for (name, client) in clients {
            let running = await client.isRunning
            guard running else { continue }
            let mcpTools = await client.discoveredTools
            for tool in mcpTools {
                tools.append(MCPToolBridge(serverName: name, tool: tool))
            }
        }
        return tools
    }

    /// Reload config from disk and restart all servers.
    func reload() async {
        await stopAll()
        await startAll()
    }

    /// Get current server configs.
    func currentConfigs() -> [String: MCPServerConfig] {
        configs
    }

    // MARK: - Health Monitor

    private func monitorServer(name: String, config: MCPServerConfig) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // Check every 10s
            guard !Task.isCancelled else { break }

            if let client = clients[name] {
                let running = await client.isRunning
                if !running {
                    MajoorLogger.log("MCP[\(name)] crashed — restarting...")
                    await startServer(name: name, config: config)
                    break // New monitor will be started by startServer
                }
            }
        }
    }
}

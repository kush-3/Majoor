// MCPServerManager.swift
// Majoor — Manages all MCP server connections
//
// Starts configured servers on launch, monitors health, restarts on crash.
// Servers run for the lifetime of the app — stopped on sleep, restarted on wake.
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
    private var restartCounts: [String: Int] = [:]
    private let maxRestarts = 5

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

    /// Ensure a specific server is running — safety net for crash recovery.
    /// If a server died mid-session, this restarts it before the tool call fails.
    func ensureRunning(_ serverName: String) async throws {
        // Already running
        if let client = clients[serverName], await client.isRunning {
            return
        }
        // Check if configured
        guard let config = configs[serverName] else {
            // Reload config in case it was added after launch
            configs = MCPConfig.load()
            guard let freshConfig = configs[serverName] else {
                throw MCPClient.MCPError.startFailed("\(serverName) is not configured")
            }
            await startServer(name: serverName, config: freshConfig)
            return
        }
        MajoorLogger.log("MCP[\(serverName)] restarting — was not running")
        await startServer(name: serverName, config: config)
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
            clients.removeValue(forKey: name) // Don't leave a dead client in the dict
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

    /// Get names of all configured servers (even if not yet running).
    func configuredServerNames() -> [String] {
        Array(configs.keys)
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

    /// Reset restart count for a server (call after successful manual start/token update)
    func resetRestartCount(for name: String) {
        restartCounts[name] = 0
    }

    // MARK: - Health Monitor

    private func monitorServer(name: String, config: MCPServerConfig) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // Check every 30s
            guard !Task.isCancelled else { break }

            if let client = clients[name] {
                let running = await client.isRunning
                if !running {
                    let count = (restartCounts[name] ?? 0) + 1
                    restartCounts[name] = count

                    if count > maxRestarts {
                        MajoorLogger.error("MCP[\(name)] exceeded max restarts (\(maxRestarts)) — giving up")
                        serverErrors[name] = "Server crashed repeatedly. Check Settings > Integrations."
                        clients.removeValue(forKey: name)
                        // Notify user that the server failed permanently
                        await MainActor.run {
                            NotificationManager.shared.sendSimple(
                                title: "Majoor — \(name.capitalized) Integration Failed",
                                body: "\(name.capitalized) server crashed \(maxRestarts) times. Check your token in Settings > Integrations.",
                                category: NotificationManager.taskFailedCategory
                            )
                        }
                        break
                    }

                    // Exponential backoff: 5s, 10s, 20s, 40s, 80s
                    let backoff = 5.0 * pow(2.0, Double(count - 1))
                    MajoorLogger.log("MCP[\(name)] crashed — restart \(count)/\(maxRestarts) in \(Int(backoff))s")
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    guard !Task.isCancelled else { break }

                    await startServer(name: name, config: config)
                    // Silent recovery — no notification unless it fails permanently
                    break // New monitor will be started by startServer
                }
            }
        }
    }
}

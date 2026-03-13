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
    private var restartCounts: [String: Int] = [:]
    private let maxRestarts = 5

    /// Track last tool call time per server for idle timeout
    private var lastToolCallTime: [String: Date] = [:]
    private let idleTimeoutSeconds: TimeInterval = 600 // 10 minutes
    private var idleMonitorTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Load config only — servers start lazily on first tool use.
    func loadConfigs() {
        configs = MCPConfig.load()
        if configs.isEmpty {
            MajoorLogger.log("MCP: No servers configured")
        } else {
            MajoorLogger.log("MCP: \(configs.count) server(s) configured (lazy start)")
        }
        startIdleMonitor()
    }

    /// Start all configured servers immediately (used by onboarding/settings reload).
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
        startIdleMonitor()
    }

    /// Ensure a specific server is running — starts it on demand if needed.
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
        MajoorLogger.log("MCP[\(serverName)] lazy start — first use")
        await startServer(name: serverName, config: config)
    }

    /// Record that a tool was called on a server (for idle timeout tracking).
    func recordToolCall(for serverName: String) {
        lastToolCallTime[serverName] = Date()
    }

    /// Stop all servers gracefully.
    func stopAll() async {
        idleMonitorTask?.cancel()
        idleMonitorTask = nil
        for (name, _) in clients {
            monitorTasks[name]?.cancel()
            monitorTasks[name] = nil
        }
        for (_, client) in clients {
            await client.shutdown()
        }
        clients.removeAll()
        serverErrors.removeAll()
        lastToolCallTime.removeAll()
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
    /// Includes both running and configured-but-idle servers (they start on demand).
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
                } else {
                    lines.append("- \(name): available (starts on demand)")
                }
            } else if serverErrors[name] == nil {
                // Configured but not yet started — will start on first use
                lines.append("- \(name): available (starts on demand)")
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

    // MARK: - Idle Timeout Monitor

    /// Periodically checks for idle servers and shuts them down.
    private func startIdleMonitor() {
        idleMonitorTask?.cancel()
        idleMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // Check every 60s
                guard !Task.isCancelled else { break }
                await self?.shutdownIdleServers()
            }
        }
    }

    private func shutdownIdleServers() async {
        let now = Date()
        for (name, _) in clients {
            guard let lastCall = lastToolCallTime[name] else {
                // Never used — if it's been running for > idle timeout, shut it down
                // (handles servers started by onboarding/reload but never used)
                continue
            }
            if now.timeIntervalSince(lastCall) >= idleTimeoutSeconds {
                MajoorLogger.log("MCP[\(name)] idle for \(Int(idleTimeoutSeconds))s — shutting down")
                await stopServer(name: name)
                lastToolCallTime.removeValue(forKey: name)
            }
        }
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

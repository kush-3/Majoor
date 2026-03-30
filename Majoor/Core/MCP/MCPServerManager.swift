// MCPServerManager.swift
// Majoor — Manages all MCP server connections
//
// Servers start lazily on first tool use and auto-stop after 5 min idle.
// Tool schemas are cached to disk so Claude sees MCP tools immediately on launch.

import Foundation
import CryptoKit

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
    private var idleTimers: [String: Task<Void, Never>] = [:]
    private let idleTimeoutSeconds: TimeInterval = 300
    private let maxRestarts = 5

    // MARK: - Tool Definition Cache

    private static let cacheURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".majoor/mcp_tool_cache.json")
    }()

    private var cachedToolDefs: [String: [MCPToolDefinition]] = [:]

    private init() {}

    // MARK: - Tool Cache

    /// Loads cache from disk if it exists and its config hash matches the current mcp.json.
    /// Returns true if the cache was loaded successfully.
    private func loadCacheIfValid() -> Bool {
        guard let cacheData = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(MCPToolCache.self, from: cacheData) else {
            return false
        }

        guard cache.configHash == Self.configHash() else {
            MajoorLogger.log("MCP: Cache hash mismatch — invalidating")
            invalidateCache()
            return false
        }

        cachedToolDefs = cache.servers.mapValues { defs in
            defs.map { $0.toToolDefinition() }
        }
        return true
    }

    /// Caches the discovered tools for a server, writing the full cache to disk.
    private func cacheTools(serverName: String, tools: [MCPToolDefinition]) {
        cachedToolDefs[serverName] = tools
        writeCacheToDisk()
    }

    private func writeCacheToDisk() {
        guard let hash = Self.configHash() else { return }

        let servers = cachedToolDefs.mapValues { defs in
            defs.map { CachedToolDef(from: $0) }
        }
        let cache = MCPToolCache(configHash: hash, servers: servers)

        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: Self.cacheURL, options: .atomic)
        } catch {
            MajoorLogger.error("MCP: Failed to write tool cache: \(error)")
        }
    }

    private func invalidateCache() {
        cachedToolDefs.removeAll()
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    /// SHA-256 hash of the raw mcp.json file contents.
    private static func configHash() -> String? {
        guard let data = try? Data(contentsOf: MCPConfig.configURL) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Lifecycle

    /// Load config and populate tool cache. If no valid cache exists, starts all
    /// servers eagerly to discover tools, then caches them for future launches.
    func startAll() async {
        configs = MCPConfig.load()
        guard !configs.isEmpty else {
            MajoorLogger.log("MCP: No servers configured")
            return
        }

        if loadCacheIfValid() {
            MajoorLogger.log("MCP: \(configs.count) server(s) configured, \(cachedToolDefs.values.map(\.count).reduce(0, +)) tool(s) loaded from cache — will start on first use")
            return
        }

        // No valid cache — start all servers eagerly to discover and cache tools
        MajoorLogger.log("MCP: No valid cache — starting all \(configs.count) server(s) for tool discovery")
        for (name, config) in configs {
            await startServer(name: name, config: config)
        }
    }

    /// Lazy start entry point — starts the server if not running, resets idle timer.
    func ensureRunning(_ serverName: String) async throws {
        if let client = clients[serverName], await client.isRunning {
            resetIdleTimer(for: serverName)
            return
        }

        guard let config = configs[serverName] else {
            configs = MCPConfig.load()
            guard let freshConfig = configs[serverName] else {
                throw MCPClient.MCPError.startFailed("\(serverName) is not configured")
            }
            MajoorLogger.log("MCP[\(serverName)] lazy-starting on first use")
            await startServer(name: serverName, config: freshConfig)
            resetIdleTimer(for: serverName)
            return
        }

        MajoorLogger.log("MCP[\(serverName)] lazy-starting on first use")
        await startServer(name: serverName, config: config)
        resetIdleTimer(for: serverName)
    }

    /// Stop all servers gracefully.
    func stopAll() async {
        for (name, _) in clients {
            idleTimers[name]?.cancel()
            monitorTasks[name]?.cancel()
        }
        idleTimers.removeAll()
        monitorTasks.removeAll()
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
            cacheTools(serverName: name, tools: tools)

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
        idleTimers[name]?.cancel()
        idleTimers[name] = nil
        monitorTasks[name]?.cancel()
        monitorTasks[name] = nil

        if let client = clients.removeValue(forKey: name) {
            await client.shutdown()
        }
        serverErrors[name] = nil
        MajoorLogger.log("MCP[\(name)] stopped (idle or manual)")
    }

    private func resetIdleTimer(for name: String) {
        idleTimers[name]?.cancel()
        let timeout = idleTimeoutSeconds
        idleTimers[name] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            MajoorLogger.log("MCP[\(name)] idle for 5 min — shutting down")
            await self?.stopServer(name: name)
        }
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
                    toolCount: cachedToolDefs[name]?.count ?? 0,
                    error: serverErrors[name]
                ))
            }
        }
        return statuses
    }

    /// Get a summary of all configured MCP servers for system prompt injection.
    /// Lists every configured server so Claude knows they exist, even if not yet started.
    func serverSummary() async -> String? {
        guard !configs.isEmpty else { return nil }

        var lines: [String] = []
        for (name, _) in configs {
            if let client = clients[name], await client.isRunning {
                let tools = await client.discoveredTools
                let toolNames = tools.prefix(5).map(\.name).joined(separator: ", ")
                let suffix = tools.count > 5 ? ", ..." : ""
                lines.append("- \(name): \(tools.count) tools (\(toolNames)\(suffix)) [running]")
            } else if let cached = cachedToolDefs[name] {
                let toolNames = cached.prefix(5).map(\.name).joined(separator: ", ")
                let suffix = cached.count > 5 ? ", ..." : ""
                lines.append("- \(name): \(cached.count) tools (\(toolNames)\(suffix)) [idle — starts on first use]")
            } else {
                lines.append("- \(name): available (starts on first use)")
            }
        }
        return "MCP INTEGRATIONS AVAILABLE:\n" + lines.joined(separator: "\n") + "\nUse these integrations by calling their tools by name. Servers start automatically on first use."
    }

    /// Get ALL bridged AgentTools — live tools from running servers, cached tools from idle ones.
    func allAvailableTools() async -> [MCPToolBridge] {
        var tools: [MCPToolBridge] = []
        var servedByClient: Set<String> = []

        for (name, client) in clients {
            let running = await client.isRunning
            guard running else { continue }
            servedByClient.insert(name)
            let mcpTools = await client.discoveredTools
            for tool in mcpTools {
                tools.append(MCPToolBridge(serverName: name, tool: tool))
            }
        }

        // Fill in cached tools for servers that aren't running
        for (name, defs) in cachedToolDefs where !servedByClient.contains(name) {
            for def in defs {
                tools.append(MCPToolBridge(serverName: name, tool: def))
            }
        }

        return tools
    }

    /// Get names of all configured servers (even if not yet running).
    func configuredServerNames() -> [String] {
        Array(configs.keys)
    }

    /// Reload config from disk. Invalidates cache and restarts discovery.
    func reload() async {
        await stopAll()
        invalidateCache()
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

// MARK: - Cache Codable Types

private struct MCPToolCache: Codable {
    let configHash: String
    let servers: [String: [CachedToolDef]]
}

private struct CachedToolDef: Codable {
    let name: String
    let description: String
    let inputSchema: CachedInputSchema?

    init(from def: MCPToolDefinition) {
        self.name = def.name
        self.description = def.description
        self.inputSchema = def.inputSchema.map { CachedInputSchema(from: $0) }
    }

    func toToolDefinition() -> MCPToolDefinition {
        MCPToolDefinition(
            name: name,
            description: description,
            inputSchema: inputSchema?.toInputSchema()
        )
    }
}

private struct CachedInputSchema: Codable {
    let properties: [String: CachedPropertySchema]
    let required: [String]

    init(from schema: MCPInputSchema) {
        self.properties = schema.properties.mapValues { CachedPropertySchema(from: $0) }
        self.required = schema.required
    }

    func toInputSchema() -> MCPInputSchema {
        MCPInputSchema(
            properties: properties.mapValues { $0.toPropertySchema() },
            required: required
        )
    }
}

private struct CachedPropertySchema: Codable {
    let type: String
    let description: String
    let enumValues: [String]?

    init(from prop: MCPPropertySchema) {
        self.type = prop.type
        self.description = prop.description
        self.enumValues = prop.enumValues
    }

    func toPropertySchema() -> MCPPropertySchema {
        MCPPropertySchema(type: type, description: description, enumValues: enumValues)
    }
}

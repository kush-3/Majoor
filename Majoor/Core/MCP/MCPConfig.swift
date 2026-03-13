// MCPConfig.swift
// Majoor — MCP Server Configuration
//
// Loads/saves ~/.majoor/mcp.json. Resolves "keychain:" prefixed env values
// from macOS Keychain at server start time.

import Foundation

// MARK: - Config Models

nonisolated struct MCPServerConfig: Codable, Sendable {
    let command: String
    let args: [String]?
    let env: [String: String]?
}

nonisolated struct MCPConfigFile: Codable, Sendable {
    let mcpServers: [String: MCPServerConfig]?
}

// MARK: - Config Loader

nonisolated struct MCPConfig: Sendable {

    static let configURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".majoor/mcp.json")
    }()

    /// Load the MCP config from ~/.majoor/mcp.json
    static func load() -> [String: MCPServerConfig] {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            MajoorLogger.log("MCP config not found at \(configURL.path)")
            return [:]
        }
        do {
            let data = try Data(contentsOf: configURL)
            let config = try JSONDecoder().decode(MCPConfigFile.self, from: data)
            let servers = config.mcpServers ?? [:]
            MajoorLogger.log("MCP config loaded: \(servers.count) server(s)")
            return servers
        } catch {
            MajoorLogger.error("Failed to load MCP config: \(error)")
            return [:]
        }
    }

    /// Save the MCP config to ~/.majoor/mcp.json
    static func save(_ servers: [String: MCPServerConfig]) {
        let config = MCPConfigFile(mcpServers: servers)
        do {
            // Ensure directory exists
            let dir = configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
            MajoorLogger.log("MCP config saved: \(servers.count) server(s)")
        } catch {
            MajoorLogger.error("Failed to save MCP config: \(error)")
        }
    }

    /// Resolve environment variables, replacing "keychain:<key>" with Keychain values.
    static func resolveEnv(_ env: [String: String]?) -> [String: String] {
        guard let env else { return [:] }
        var resolved: [String: String] = [:]
        for (key, value) in env {
            if value.hasPrefix("keychain:") {
                let keychainKey = String(value.dropFirst("keychain:".count))
                if let secret = KeychainManager.shared.retrieve(key: keychainKey) {
                    resolved[key] = secret
                } else {
                    MajoorLogger.error("MCP env: Keychain key '\(keychainKey)' not found for \(key)")
                }
            } else {
                resolved[key] = value
            }
        }
        return resolved
    }
}

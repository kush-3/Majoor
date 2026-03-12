// MCPSettingsView.swift
// Majoor — MCP Integrations Settings
//
// UI for managing MCP servers: view status, add/remove tokens,
// test connections, add custom servers.

import SwiftUI

struct MCPSettingsView: View {
    @State private var servers: [ServerEntry] = []
    @State private var showAddCustom = false
    @State private var isLoading = true

    struct ServerEntry: Identifiable {
        let id: String  // server name
        let name: String
        var isRunning: Bool
        var toolCount: Int
        var error: String?
        var hasToken: Bool
        var tokenPreview: String?
    }

    // Known MCP servers with their token keychain keys and setup info
    private static let knownServers: [(name: String, keychainKey: String, tokenLabel: String, envKey: String, helpURL: String)] = [
        ("github", "github_pat", "Personal Access Token", "GITHUB_PERSONAL_ACCESS_TOKEN", "github.com/settings/tokens"),
        ("slack", "slack_bot_token", "Bot Token (xoxb-)", "SLACK_BOT_TOKEN", "api.slack.com/apps"),
        ("linear", "linear_api_key", "API Key", "LINEAR_API_KEY", "linear.app/settings/api"),
        ("notion", "notion_token", "Integration Token", "NOTION_API_TOKEN", "notion.so/my-integrations"),
    ]

    var body: some View {
        Form {
            Section("Integrations") {
                if isLoading {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading...").font(.system(size: 12)).foregroundColor(.secondary)
                    }
                } else if servers.isEmpty {
                    Text("No MCP servers configured.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(servers) { server in
                        MCPServerRow(server: server, onTokenChange: { newToken in
                            saveToken(for: server.name, token: newToken)
                        }, onRemoveToken: {
                            removeToken(for: server.name)
                        }, onTest: {
                            testServer(server.name)
                        })
                    }
                }
            }

            Section {
                HStack {
                    Button("Add Custom Server") { showAddCustom = true }
                        .font(.caption)
                    Spacer()
                    Button("Open mcp.json") { openConfigFile() }
                        .font(.caption)
                    Button("Reload") { Task { await refresh() } }
                        .font(.caption)
                }
            }

            Section {
                Text("MCP servers connect Majoor to external services. Add tokens above, or edit ~/.majoor/mcp.json directly for custom servers.")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { Task { await refresh() } }
        .sheet(isPresented: $showAddCustom) {
            AddCustomServerSheet(onSave: { name, command, args, envKey, envValue in
                addCustomServer(name: name, command: command, args: args, envKey: envKey, envValue: envValue)
                showAddCustom = false
            }, onCancel: {
                showAddCustom = false
            })
        }
    }

    // MARK: - Actions

    private func refresh() async {
        isLoading = true

        let configs = await MCPServerManager.shared.currentConfigs()
        let statuses = await MCPServerManager.shared.allStatus()
        let statusMap = Dictionary(uniqueKeysWithValues: statuses.map { ($0.name, $0) })

        var entries: [ServerEntry] = []

        // Add known servers (even if not configured, to show "Add Token" option)
        for known in Self.knownServers {
            let hasToken = KeychainManager.shared.retrieve(key: known.keychainKey) != nil
            let status = statusMap[known.name]
            let isConfigured = configs[known.name] != nil

            if isConfigured || hasToken {
                let tokenValue = KeychainManager.shared.retrieve(key: known.keychainKey)
                let preview = tokenValue.map { maskToken($0) }
                entries.append(ServerEntry(
                    id: known.name,
                    name: known.name,
                    isRunning: status?.isRunning ?? false,
                    toolCount: status?.toolCount ?? 0,
                    error: status?.error,
                    hasToken: hasToken,
                    tokenPreview: preview
                ))
            } else {
                entries.append(ServerEntry(
                    id: known.name,
                    name: known.name,
                    isRunning: false,
                    toolCount: 0,
                    error: nil,
                    hasToken: false,
                    tokenPreview: nil
                ))
            }
        }

        // Add any custom servers not in the known list
        let knownNames = Set(Self.knownServers.map(\.name))
        for (name, _) in configs where !knownNames.contains(name) {
            let status = statusMap[name]
            entries.append(ServerEntry(
                id: name,
                name: name,
                isRunning: status?.isRunning ?? false,
                toolCount: status?.toolCount ?? 0,
                error: status?.error,
                hasToken: true,  // Custom servers don't need separate token management
                tokenPreview: nil
            ))
        }

        servers = entries
        isLoading = false
    }

    private func saveToken(for serverName: String, token: String) {
        guard let known = Self.knownServers.first(where: { $0.name == serverName }) else { return }
        KeychainManager.shared.save(key: known.keychainKey, value: token)

        // Ensure the server is in mcp.json
        var configs = MCPConfig.load()
        if configs[serverName] == nil {
            let serverConfig = defaultConfig(for: serverName)
            configs[serverName] = serverConfig
            MCPConfig.save(configs)
        }

        // Restart the server
        Task {
            if let config = MCPConfig.load()[serverName] {
                await MCPServerManager.shared.startServer(name: serverName, config: config)
            }
            await refresh()
        }
    }

    private func removeToken(for serverName: String) {
        guard let known = Self.knownServers.first(where: { $0.name == serverName }) else { return }
        KeychainManager.shared.delete(key: known.keychainKey)

        // Stop the server
        Task {
            await MCPServerManager.shared.stopServer(name: serverName)

            // Remove from config
            var configs = MCPConfig.load()
            configs.removeValue(forKey: serverName)
            MCPConfig.save(configs)

            await refresh()
        }
    }

    private func testServer(_ serverName: String) {
        Task {
            if let client = await MCPServerManager.shared.client(for: serverName) {
                do {
                    let tools = try await client.listTools()
                    MajoorLogger.log("MCP[\(serverName)] test: \(tools.count) tools discovered")
                } catch {
                    MajoorLogger.error("MCP[\(serverName)] test failed: \(error)")
                }
            }
            await refresh()
        }
    }

    private func openConfigFile() {
        NSWorkspace.shared.open(MCPConfig.configURL)
    }

    private func addCustomServer(name: String, command: String, args: String, envKey: String, envValue: String) {
        var configs = MCPConfig.load()
        let argsArray = args.split(separator: " ").map(String.init)
        var env: [String: String]? = nil
        if !envKey.isEmpty && !envValue.isEmpty {
            // Save token to keychain
            let keychainKey = "\(name)_token"
            KeychainManager.shared.save(key: keychainKey, value: envValue)
            env = [envKey: "keychain:\(keychainKey)"]
        }
        configs[name] = MCPServerConfig(command: command, args: argsArray, env: env)
        MCPConfig.save(configs)

        Task {
            await MCPServerManager.shared.reload()
            await refresh()
        }
    }

    private func defaultConfig(for serverName: String) -> MCPServerConfig {
        switch serverName {
        case "github":
            return MCPServerConfig(command: "npx", args: ["-y", "@modelcontextprotocol/server-github"], env: ["GITHUB_PERSONAL_ACCESS_TOKEN": "keychain:github_pat"])
        case "slack":
            return MCPServerConfig(command: "npx", args: ["-y", "@modelcontextprotocol/server-slack"], env: ["SLACK_BOT_TOKEN": "keychain:slack_bot_token"])
        case "linear":
            return MCPServerConfig(command: "npx", args: ["-y", "mcp-linear"], env: ["LINEAR_API_KEY": "keychain:linear_api_key"])
        case "notion":
            return MCPServerConfig(command: "npx", args: ["-y", "@modelcontextprotocol/server-notion"], env: ["NOTION_API_TOKEN": "keychain:notion_token"])
        default:
            return MCPServerConfig(command: "echo", args: ["unknown"], env: nil)
        }
    }

    private func maskToken(_ token: String) -> String {
        guard token.count > 8 else { return String(repeating: "*", count: token.count) }
        let suffix = String(token.suffix(4))
        return String(repeating: "*", count: 8) + suffix
    }
}

// MARK: - Server Row

struct MCPServerRow: View {
    let server: MCPSettingsView.ServerEntry
    var onTokenChange: (String) -> Void
    var onRemoveToken: () -> Void
    var onTest: () -> Void

    @State private var showTokenInput = false
    @State private var tokenText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(server.name.capitalized)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            if let error = server.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            if server.hasToken {
                HStack {
                    if let preview = server.tokenPreview {
                        Text("Token: \(preview)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Change") { showTokenInput = true }
                        .font(.caption)
                    Button("Test") { onTest() }
                        .font(.caption)
                    Button("Remove") { onRemoveToken() }
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } else {
                Button("Add Token") { showTokenInput = true }
                    .font(.caption)
            }

            if showTokenInput {
                HStack {
                    SecureField("Paste token...", text: $tokenText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button("Save") {
                        guard !tokenText.isEmpty else { return }
                        onTokenChange(tokenText)
                        tokenText = ""
                        showTokenInput = false
                    }
                    .font(.caption)
                    Button("Cancel") {
                        tokenText = ""
                        showTokenInput = false
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        if server.isRunning { return .green }
        if server.hasToken { return .orange }
        return .secondary
    }

    private var statusText: String {
        if server.isRunning { return "Connected (\(server.toolCount) tools)" }
        if server.error != nil { return "Error" }
        if server.hasToken { return "Not running" }
        return "No token"
    }
}

// MARK: - Add Custom Server Sheet

struct AddCustomServerSheet: View {
    var onSave: (String, String, String, String, String) -> Void
    var onCancel: () -> Void

    @State private var name = ""
    @State private var command = "npx"
    @State private var args = ""
    @State private var envKey = ""
    @State private var envValue = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Custom MCP Server")
                .font(.headline)

            Form {
                TextField("Server Name", text: $name)
                TextField("Command", text: $command)
                TextField("Arguments (space separated)", text: $args)
                TextField("Env Variable Name (optional)", text: $envKey)
                SecureField("Env Variable Value / Token (optional)", text: $envValue)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { onCancel() }
                Spacer()
                Button("Add Server") {
                    guard !name.isEmpty, !command.isEmpty else { return }
                    onSave(name, command, args, envKey, envValue)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || command.isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 400, height: 320)
    }
}

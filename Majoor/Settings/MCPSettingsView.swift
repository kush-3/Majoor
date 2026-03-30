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

    struct ExtraCredential: Identifiable {
        var id: String { keychainKey }
        let keychainKey: String
        let label: String
        let envKey: String
        var hasValue: Bool
        var preview: String?
    }

    struct ServerEntry: Identifiable {
        let id: String  // server name
        let name: String
        var isRunning: Bool
        var toolCount: Int
        var error: String?
        var hasToken: Bool
        var tokenPreview: String?
        var extraCredentials: [ExtraCredential]
    }

    // Known MCP servers with their token keychain keys and setup info
    // extraCredentials: additional keychain keys needed beyond the primary token (e.g. Slack Team ID)
    private static let knownServers: [(name: String, keychainKey: String, tokenLabel: String, envKey: String, helpURL: String, extraCredentials: [(keychainKey: String, label: String, envKey: String)])] = [
        ("github", "github_pat", "Personal Access Token", "GITHUB_PERSONAL_ACCESS_TOKEN", "github.com/settings/tokens", []),
        ("slack", "slack_bot_token", "Bot Token (xoxb-)", "SLACK_BOT_TOKEN", "api.slack.com/apps",
         [("slack_team_id", "Team ID (T0...)", "SLACK_TEAM_ID")]),
        ("linear", "linear_api_key", "API Key", "LINEAR_API_KEY", "linear.app/settings/api", []),
        ("notion", "notion_token", "Integration Token", "NOTION_TOKEN", "notion.so/my-integrations", []),
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
                        }, onExtraCredentialChange: { keychainKey, value in
                            saveExtraCredential(for: server.name, keychainKey: keychainKey, value: value)
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
                    Button { Task { await refresh() } } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .font(.caption)
                    Spacer()
                    Button("Open mcp.json") { openConfigFile() }
                        .font(.caption)
                    Spacer()
                    Button("Add Custom Server...") { showAddCustom = true }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
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

            // Build extra credentials list
            let extras: [ExtraCredential] = known.extraCredentials.map { extra in
                let val = KeychainManager.shared.retrieve(key: extra.keychainKey)
                return ExtraCredential(
                    keychainKey: extra.keychainKey,
                    label: extra.label,
                    envKey: extra.envKey,
                    hasValue: val != nil,
                    preview: val.map { maskToken($0) }
                )
            }

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
                    tokenPreview: preview,
                    extraCredentials: extras
                ))
            } else {
                entries.append(ServerEntry(
                    id: known.name,
                    name: known.name,
                    isRunning: false,
                    toolCount: 0,
                    error: nil,
                    hasToken: false,
                    tokenPreview: nil,
                    extraCredentials: extras
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
                tokenPreview: nil,
                extraCredentials: []
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
            let serverConfig = Self.defaultServerConfig(for: serverName)
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

    private func saveExtraCredential(for serverName: String, keychainKey: String, value: String) {
        KeychainManager.shared.save(key: keychainKey, value: value)

        // Ensure config exists and restart
        var configs = MCPConfig.load()
        if configs[serverName] == nil {
            configs[serverName] = Self.defaultServerConfig(for: serverName)
            MCPConfig.save(configs)
        }

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
        // Also remove extra credentials
        for extra in known.extraCredentials {
            KeychainManager.shared.delete(key: extra.keychainKey)
        }

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

    static func defaultServerConfig(for serverName: String) -> MCPServerConfig {
        switch serverName {
        case "github":
            return MCPServerConfig(command: "npx", args: ["-y", "@modelcontextprotocol/server-github"], env: ["GITHUB_PERSONAL_ACCESS_TOKEN": "keychain:github_pat"])
        case "slack":
            return MCPServerConfig(command: "npx", args: ["-y", "@modelcontextprotocol/server-slack"], env: ["SLACK_BOT_TOKEN": "keychain:slack_bot_token", "SLACK_TEAM_ID": "keychain:slack_team_id"])
        case "linear":
            return MCPServerConfig(command: "npx", args: ["-y", "mcp-linear"], env: ["LINEAR_API_KEY": "keychain:linear_api_key"])
        case "notion":
            return MCPServerConfig(command: "npx", args: ["-y", "@notionhq/notion-mcp-server"], env: ["NOTION_TOKEN": "keychain:notion_token"])
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
    var onExtraCredentialChange: (String, String) -> Void  // (keychainKey, value)
    var onRemoveToken: () -> Void
    var onTest: () -> Void

    enum TestResult { case idle, testing, success(Int), failure(String) }

    @State private var showTokenInput = false
    @State private var tokenText = ""
    @State private var extraInputs: [String: String] = [:]  // keychainKey -> text
    @State private var showExtraInput: String? = nil          // keychainKey being edited
    @State private var testResult: TestResult = .idle
    @State private var showRemoveConfirmation = false

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
                    Button("Change") { withAnimation(DT.Anim.normal) { showTokenInput = true } }
                        .font(.caption)
                    testButton
                    Button("Remove") { showRemoveConfirmation = true }
                        .font(.caption)
                        .foregroundColor(.red)
                        .alert("Remove \(server.name.capitalized)?", isPresented: $showRemoveConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Remove", role: .destructive) { onRemoveToken() }
                        } message: {
                            Text("This will delete the token and stop the server.")
                        }
                }
            } else {
                Button("Add Token") { withAnimation(DT.Anim.normal) { showTokenInput = true } }
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

            // Extra credentials (e.g. Slack Team ID)
            ForEach(server.extraCredentials) { extra in
                HStack {
                    if extra.hasValue {
                        Text("\(extra.label): \(extra.preview ?? "set")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Change") { showExtraInput = extra.keychainKey }
                            .font(.caption)
                    } else {
                        Text("\(extra.label): not set")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Spacer()
                        Button("Add") { showExtraInput = extra.keychainKey }
                            .font(.caption)
                    }
                }

                if showExtraInput == extra.keychainKey {
                    HStack {
                        TextField(extra.label, text: Binding(
                            get: { extraInputs[extra.keychainKey] ?? "" },
                            set: { extraInputs[extra.keychainKey] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        Button("Save") {
                            let value = extraInputs[extra.keychainKey] ?? ""
                            guard !value.isEmpty else { return }
                            onExtraCredentialChange(extra.keychainKey, value)
                            extraInputs[extra.keychainKey] = nil
                            showExtraInput = nil
                        }
                        .font(.caption)
                        Button("Cancel") {
                            extraInputs[extra.keychainKey] = nil
                            showExtraInput = nil
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var testButton: some View {
        switch testResult {
        case .idle:
            Button("Test") { runTest() }
                .font(.caption)
        case .testing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Testing...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .success(let count):
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("\(count) tools")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        case .failure(let message):
            HStack(spacing: 2) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }

    private func runTest() {
        testResult = .testing
        Task {
            if let client = await MCPServerManager.shared.client(for: server.name) {
                do {
                    let tools = try await client.listTools()
                    testResult = .success(tools.count)
                } catch {
                    testResult = .failure("Failed")
                }
            } else {
                testResult = .failure("Not running")
            }
            try? await Task.sleep(for: .seconds(8))
            testResult = .idle
        }
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

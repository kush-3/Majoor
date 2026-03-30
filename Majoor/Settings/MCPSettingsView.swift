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
        let id: String
        let name: String
        var isRunning: Bool
        var toolCount: Int
        var error: String?
        var hasToken: Bool
        var tokenPreview: String?
        var extraCredentials: [ExtraCredential]
    }

    private static let knownServers: [(name: String, keychainKey: String, tokenLabel: String, envKey: String, helpURL: String, extraCredentials: [(keychainKey: String, label: String, envKey: String)])] = [
        ("github", "github_pat", "Personal Access Token", "GITHUB_PERSONAL_ACCESS_TOKEN", "github.com/settings/tokens", []),
        ("slack", "slack_bot_token", "Bot Token (xoxb-)", "SLACK_BOT_TOKEN", "api.slack.com/apps",
         [("slack_team_id", "Team ID (T0...)", "SLACK_TEAM_ID")]),
        ("linear", "linear_api_key", "API Key", "LINEAR_API_KEY", "linear.app/settings/api", []),
        ("notion", "notion_token", "Integration Token", "NOTION_TOKEN", "notion.so/my-integrations", []),
    ]

    var body: some View {
        Form {
            Section {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading servers...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
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
            } header: {
                Text("MCP Servers")
            }

            Section {
                Button("Add Custom Server...") { showAddCustom = true }
            } header: {
                Text("Custom")
            } footer: {
                Text("MCP servers extend Majoor with tools from external services. Tokens are stored in the macOS Keychain.")
            }

            Section {
                HStack {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Reload Servers", systemImage: "arrow.clockwise")
                    }
                    Spacer()
                    Button("Open mcp.json...") { openConfigFile() }
                }
            }
        }
        .formStyle(.grouped)
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

        for known in Self.knownServers {
            let hasToken = KeychainManager.shared.retrieve(key: known.keychainKey) != nil
            let status = statusMap[known.name]
            let isConfigured = configs[known.name] != nil

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
                    id: known.name, name: known.name,
                    isRunning: status?.isRunning ?? false,
                    toolCount: status?.toolCount ?? 0,
                    error: status?.error,
                    hasToken: hasToken, tokenPreview: preview,
                    extraCredentials: extras
                ))
            } else {
                entries.append(ServerEntry(
                    id: known.name, name: known.name,
                    isRunning: false, toolCount: 0,
                    error: nil, hasToken: false, tokenPreview: nil,
                    extraCredentials: extras
                ))
            }
        }

        let knownNames = Set(Self.knownServers.map(\.name))
        for (name, _) in configs where !knownNames.contains(name) {
            let status = statusMap[name]
            entries.append(ServerEntry(
                id: name, name: name,
                isRunning: status?.isRunning ?? false,
                toolCount: status?.toolCount ?? 0,
                error: status?.error,
                hasToken: true, tokenPreview: nil,
                extraCredentials: []
            ))
        }

        servers = entries
        isLoading = false
    }

    private func saveToken(for serverName: String, token: String) {
        guard let known = Self.knownServers.first(where: { $0.name == serverName }) else { return }
        KeychainManager.shared.save(key: known.keychainKey, value: token)

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

    private func saveExtraCredential(for serverName: String, keychainKey: String, value: String) {
        KeychainManager.shared.save(key: keychainKey, value: value)

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
        for extra in known.extraCredentials {
            KeychainManager.shared.delete(key: extra.keychainKey)
        }

        Task {
            await MCPServerManager.shared.stopServer(name: serverName)
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
        guard token.count > 8 else { return String(repeating: "\u{2022}", count: token.count) }
        let suffix = String(token.suffix(4))
        return String(repeating: "\u{2022}", count: 8) + suffix
    }
}

// MARK: - Server Row

struct MCPServerRow: View {
    let server: MCPSettingsView.ServerEntry
    var onTokenChange: (String) -> Void
    var onExtraCredentialChange: (String, String) -> Void
    var onRemoveToken: () -> Void
    var onTest: () -> Void

    enum TestResult { case idle, testing, success(Int), failure(String) }

    @State private var showTokenInput = false
    @State private var tokenText = ""
    @State private var extraInputs: [String: String] = [:]
    @State private var showExtraInput: String? = nil
    @State private var testResult: TestResult = .idle
    @State private var showRemoveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: name + status
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(server.name.capitalized)
                    .font(.body)

                Spacer()

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Error
            if let error = server.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            // Token management
            if server.hasToken && !showTokenInput {
                HStack(spacing: 12) {
                    if let preview = server.tokenPreview {
                        Text(preview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    testResultView
                    Button("Change") { showTokenInput = true }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    Button("Remove", role: .destructive) { showRemoveConfirmation = true }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .alert("Remove \(server.name.capitalized)?", isPresented: $showRemoveConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Remove", role: .destructive) { onRemoveToken() }
                        } message: {
                            Text("This will delete the token from Keychain and stop the server.")
                        }
                }
            } else if !server.hasToken && !showTokenInput {
                Button("Add Token...") { showTokenInput = true }
                    .font(.caption)
            }

            // Token input field
            if showTokenInput {
                HStack(spacing: 8) {
                    SecureField("Paste token...", text: $tokenText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button("Save") {
                        guard !tokenText.isEmpty else { return }
                        onTokenChange(tokenText)
                        tokenText = ""
                        showTokenInput = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(tokenText.isEmpty)
                    Button("Cancel") {
                        tokenText = ""
                        showTokenInput = false
                    }
                    .controlSize(.small)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Extra credentials
            ForEach(server.extraCredentials) { extra in
                HStack {
                    Text(extra.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if extra.hasValue {
                        Text(extra.preview ?? "Set")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Button("Change") { showExtraInput = extra.keychainKey }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text("Not set")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Add") { showExtraInput = extra.keychainKey }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }

                if showExtraInput == extra.keychainKey {
                    HStack(spacing: 8) {
                        TextField(extra.label, text: Binding(
                            get: { extraInputs[extra.keychainKey] ?? "" },
                            set: { extraInputs[extra.keychainKey] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        Button("Save") {
                            let value = extraInputs[extra.keychainKey] ?? ""
                            guard !value.isEmpty else { return }
                            onExtraCredentialChange(extra.keychainKey, value)
                            extraInputs[extra.keychainKey] = nil
                            showExtraInput = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled((extraInputs[extra.keychainKey] ?? "").isEmpty)
                        Button("Cancel") {
                            extraInputs[extra.keychainKey] = nil
                            showExtraInput = nil
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: showTokenInput)
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testResult {
        case .idle:
            Button("Test") { runTest() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        case .testing:
            ProgressView()
                .controlSize(.mini)
        case .success(let count):
            Label("\(count) tools", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
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
            try? await Task.sleep(for: .seconds(5))
            testResult = .idle
        }
    }

    private var statusColor: Color {
        if server.isRunning { return .green }
        if server.hasToken { return .orange }
        return Color.secondary.opacity(0.5)
    }

    private var statusText: String {
        if server.isRunning { return "Connected \u{00B7} \(server.toolCount) tools" }
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
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Text("Add Custom MCP Server")
                    .font(.headline)
                Text("Configure a stdio-based MCP server to extend Majoor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 12)

            Form {
                Section {
                    TextField("Server Name", text: $name)
                    TextField("Command", text: $command)
                    TextField("Arguments (space separated)", text: $args)
                } header: {
                    Text("Server")
                }

                Section {
                    TextField("Environment Variable Name", text: $envKey)
                    SecureField("Token or Value", text: $envValue)
                } header: {
                    Text("Authentication (optional)")
                }
            }
            .formStyle(.grouped)

            // Buttons
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Server") {
                    guard !name.isEmpty, !command.isEmpty else { return }
                    onSave(name, command, args, envKey, envValue)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || command.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 440, height: 360)
    }
}

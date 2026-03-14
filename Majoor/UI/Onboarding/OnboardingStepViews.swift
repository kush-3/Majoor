// OnboardingStepViews.swift
// Majoor — Reusable components for onboarding and settings
//
// IntegrationCard: Token input card for MCP services.
// Used by both OnboardingView and MCPSettingsView.

import SwiftUI
import EventKit

// MARK: - Integration Card (reusable token input)

struct IntegrationCard: View {
    let name: String
    let icon: String
    let keychainKey: String
    let placeholder: String
    let recommended: Bool
    var extraCredential: (keychainKey: String, label: String, envKey: String)? = nil
    @Binding var connectedIntegrations: [String]

    @State private var token = ""
    @State private var extraValue = ""
    @State private var isExpanded = false
    @State private var isSaved = false
    @State private var isSaving = false
    @State private var toolCount: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                if recommended {
                    Text("Recommended")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundColor(.accentColor)
                }
                Spacer()

                if isSaved {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        if let count = toolCount {
                            Text("\(count) tools").font(.system(size: 11)).foregroundColor(.green)
                        } else {
                            Text("Connected").font(.system(size: 11)).foregroundColor(.green)
                        }
                    }
                } else if !isExpanded {
                    Button(hasExistingToken ? "Change" : "Set up") {
                        isExpanded = true
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                }
            }

            if isExpanded && !isSaved {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SecureField(placeholder, text: $token)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        Button("Save") { saveToken() }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .disabled(token.isEmpty || isSaving)
                        Button("Skip") {
                            isExpanded = false
                            token = ""
                        }
                        .font(.caption)
                    }

                    if let extra = extraCredential {
                        HStack {
                            TextField(extra.label, text: $extraValue)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                        }
                    }

                    if isSaving {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.5)
                            Text("Connecting...").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }
            }

            if !recommended && !isExpanded && !isSaved {
                Text("Set up later in Settings")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .onAppear { checkExisting() }
    }

    private var hasExistingToken: Bool {
        KeychainManager.shared.retrieve(key: keychainKey) != nil
    }

    private func checkExisting() {
        if hasExistingToken {
            isSaved = true
            if !connectedIntegrations.contains(name) {
                connectedIntegrations.append(name)
            }
        }
    }

    private func saveToken() {
        guard !token.isEmpty else { return }
        isSaving = true

        KeychainManager.shared.save(key: keychainKey, value: token)

        // Save extra credential if provided
        if let extra = extraCredential, !extraValue.isEmpty {
            KeychainManager.shared.save(key: extra.keychainKey, value: extraValue)
        }

        // Ensure mcp.json config exists for this server
        let serverName = name.lowercased()
        var configs = MCPConfig.load()
        if configs[serverName] == nil {
            configs[serverName] = MCPSettingsView.defaultServerConfig(for: serverName)
            MCPConfig.save(configs)
        }

        // Start the server and check tools
        Task {
            if let config = MCPConfig.load()[serverName] {
                await MCPServerManager.shared.startServer(name: serverName, config: config)
                // Wait briefly for tools to be discovered
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let client = await MCPServerManager.shared.client(for: serverName) {
                    let tools = await client.discoveredTools
                    await MainActor.run {
                        toolCount = tools.count
                    }
                }
            }
            await MainActor.run {
                isSaving = false
                isSaved = true
                isExpanded = false
                if !connectedIntegrations.contains(name) {
                    connectedIntegrations.append(name)
                }
            }
        }
    }
}

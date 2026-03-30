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
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)

                Text(name)
                    .font(.system(size: 13, weight: .medium))

                if recommended {
                    Text("Recommended")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.12))
                        )
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                if isSaved {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if let count = toolCount {
                            Text("\(count) tools")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text("Connected")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                } else if !isExpanded {
                    Button(hasExistingToken ? "Change" : "Set Up") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded = true
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Token input
            if isExpanded && !isSaved {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SecureField(placeholder, text: $token)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))

                        Button("Save") { saveToken() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(token.isEmpty || isSaving)

                        Button("Cancel") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded = false
                                token = ""
                            }
                        }
                        .controlSize(.small)
                    }

                    if let extra = extraCredential {
                        TextField(extra.label, text: $extraValue)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    if isSaving {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Connecting...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(0.03))
        )
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

        if let extra = extraCredential, !extraValue.isEmpty {
            KeychainManager.shared.save(key: extra.keychainKey, value: extraValue)
        }

        let serverName = name.lowercased()
        var configs = MCPConfig.load()
        if configs[serverName] == nil {
            configs[serverName] = MCPSettingsView.defaultServerConfig(for: serverName)
            MCPConfig.save(configs)
        }

        Task {
            if let config = MCPConfig.load()[serverName] {
                await MCPServerManager.shared.startServer(name: serverName, config: config)
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

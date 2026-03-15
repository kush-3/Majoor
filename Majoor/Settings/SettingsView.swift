// SettingsView.swift
// Majoor — Settings / Preferences

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "cpu") }
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            MCPSettingsView()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece") }
            MemorySettingsView()
                .tabItem { Label("Memory", systemImage: "brain") }
            UsageSettingsView()
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 420)
    }
}

struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true
    @State private var autoCheckUpdates: Bool = true

    private var updateManager: UpdateManager? {
        (NSApp.delegate as? AppDelegate)?.updateManager
    }

    var body: some View {
        Form {
            Section("Startup") { Toggle("Launch Majoor at login", isOn: $launchAtLogin) }
            Section("Notifications") { Toggle("Show notifications when tasks complete", isOn: $showNotifications) }
            Section("Keyboard Shortcut") {
                HStack {
                    Text("Open Command Bar:")
                    Spacer()
                    Text("⌘⇧Space")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) { _, newValue in
                        updateManager?.automaticallyChecksForUpdates = newValue
                    }
                HStack {
                    Button("Check for Updates") {
                        updateManager?.checkForUpdates()
                    }
                    .font(.system(size: 12))
                    Spacer()
                    if let lastCheck = updateManager?.lastUpdateCheckDate {
                        Text("Last checked: \(lastCheck, style: .relative) ago")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Section("Setup") {
                Button("Run Setup Wizard") {
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.showOnboarding()
                    }
                }
                .font(.system(size: 12))
            }
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text("Majoor is an AI assistant and can make mistakes. Always review actions before approving, especially for emails, file changes, and code commits.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineSpacing(2)
                }
            } header: {
                Text("Safety")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            autoCheckUpdates = updateManager?.automaticallyChecksForUpdates ?? true
        }
    }
}

struct ModelsSettingsTab: View {
    var body: some View {
        Form {
            Section("Model Routing") {
                ModelRow(label: "Code & Deep Research", model: "Claude Opus", detail: ModelRouter.opusModel)
                ModelRow(label: "General & File Tasks", model: "Claude Sonnet", detail: ModelRouter.sonnetModel)
                ModelRow(label: "Classification", model: "Claude Haiku", detail: ModelRouter.haikuModel)
            }
            Section("API Status") {
                HStack {
                    Image(systemName: APIConfig.claudeAPIKey.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundColor(APIConfig.claudeAPIKey.isEmpty ? .red : .green)
                    Text(APIConfig.claudeAPIKey.isEmpty ? "No API key configured" : "API key configured")
                        .font(.system(size: 12))
                }
            }
            Section {
                Text("Tasks are automatically routed to the best model based on their content.")
                    .font(.caption).foregroundColor(.secondary.opacity(0.7))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ModelRow: View {
    let label: String
    let model: String
    let detail: String
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
            Spacer()
            Text(model).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}

struct AboutTab: View {
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.6.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "hammer.fill").font(.system(size: 48)).foregroundColor(.accentColor)
            Text("Majoor").font(.system(size: 24, weight: .bold))
            Text("Your AI that does the work").font(.system(size: 14)).foregroundColor(.secondary)
            Text(appVersion).font(.system(size: 12)).foregroundColor(.secondary.opacity(0.7))
            Spacer()
            Link("majoor.ai", destination: URL(string: "https://majoor.ai")!).font(.caption)
            Spacer()
        }.frame(maxWidth: .infinity).padding()
    }
}

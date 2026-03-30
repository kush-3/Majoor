// SettingsView.swift
// Majoor — Settings / Preferences

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
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
        .frame(width: DT.Layout.settingsWidth, height: DT.Layout.settingsHeight)
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
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            autoCheckUpdates = updateManager?.automaticallyChecksForUpdates ?? true
        }
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
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.6.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DT.Spacing.md) {
                Spacer()
                    .frame(height: DT.Spacing.xl)

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)

                Text("Majoor")
                    .font(DT.TitleFont.hero)

                Text("Your AI agent for macOS")
                    .font(DT.Font.headline)
                    .foregroundColor(.secondary)

                Text("Version \(appVersion) (\(buildNumber))")
                    .font(DT.Font.caption)
                    .foregroundColor(.secondary)

                // Model Routing info card
                VStack(alignment: .leading, spacing: DT.Spacing.sm) {
                    Text("Model Routing")
                        .font(DT.Font.caption(.semibold))
                        .foregroundColor(.secondary)
                    ModelRow(label: "Code & Deep Research", model: "Claude Opus", detail: ModelRouter.opusModel)
                    ModelRow(label: "General & File Tasks", model: "Claude Sonnet", detail: ModelRouter.sonnetModel)
                    ModelRow(label: "Classification", model: "Claude Haiku", detail: ModelRouter.haikuModel)
                    Divider()
                    HStack(spacing: DT.Spacing.xs) {
                        Image(systemName: APIConfig.claudeAPIKey.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(APIConfig.claudeAPIKey.isEmpty ? DT.Color.error : DT.Color.success)
                        Text(APIConfig.claudeAPIKey.isEmpty ? "No API key configured" : "API key configured")
                            .font(DT.Font.caption)
                    }
                }
                .padding(DT.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DT.Radius.medium, style: .continuous).fill(DT.Color.surfaceCard))

                Spacer()
                    .frame(height: DT.Spacing.lg)

                VStack(spacing: DT.Spacing.sm) {
                    Text("Built with GRDB.swift")
                        .font(DT.Font.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: DT.Spacing.lg) {
                        Link("Website", destination: URL(string: "https://majoor.ai")!)
                        Link("GitHub", destination: URL(string: "https://github.com/kush-3/majoor")!)
                    }
                    .font(DT.Font.body)
                }

                Spacer()
                    .frame(height: DT.Spacing.lg)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}

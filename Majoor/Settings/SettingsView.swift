// SettingsView.swift
// Majoor — Settings / Preferences
//
// macOS System Settings-inspired tab layout with grouped forms.

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            MCPSettingsView()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
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

// MARK: - General

struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true
    @State private var autoCheckUpdates: Bool = true

    private var updateManager: UpdateManager? {
        (NSApp.delegate as? AppDelegate)?.updateManager
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch Majoor at login", isOn: $launchAtLogin)
                Toggle("Show notifications when tasks complete", isOn: $showNotifications)
            }

            Section {
                LabeledContent("Command Bar") {
                    Text("\u{2318}\u{21E7}Space")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) { _, newValue in
                        updateManager?.automaticallyChecksForUpdates = newValue
                    }

                HStack {
                    Button("Check for Updates Now") {
                        updateManager?.checkForUpdates()
                    }
                    Spacer()
                    if let lastCheck = updateManager?.lastUpdateCheckDate {
                        Text("Last checked \(lastCheck, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Updates")
            }

            Section {
                Button("Run Setup Wizard...") {
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.showOnboarding()
                    }
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("Re-run the initial setup to reconfigure API keys and integrations.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            autoCheckUpdates = updateManager?.automaticallyChecksForUpdates ?? true
        }
    }
}

// MARK: - About

struct AboutTab: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.6.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Majoor")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 12)

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            // Model routing
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    modelRow("Code & Research", model: "Opus", detail: ModelRouter.opusModel)
                    Divider()
                    modelRow("General Tasks", model: "Sonnet", detail: ModelRouter.sonnetModel)
                    Divider()
                    modelRow("Classification", model: "Haiku", detail: ModelRouter.haikuModel)
                }
                .padding(.vertical, 2)
            } label: {
                Label("Model Routing", systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 48)
            .padding(.top, 20)

            Spacer()

            // Footer
            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://majoor.ai")!)
                Text("\u{00B7}")
                    .foregroundStyle(.quaternary)
                Link("GitHub", destination: URL(string: "https://github.com/kush-3/majoor")!)
            }
            .font(.caption)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func modelRow(_ label: String, model: String, detail: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            Text(model)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

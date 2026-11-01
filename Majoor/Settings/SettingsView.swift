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
            ModelsSettingsView()
                .tabItem { Label("Models", systemImage: "cpu") }
            MCPSettingsView()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            MemorySettingsView()
                .tabItem { Label("Memory", systemImage: "brain") }
            UsageSettingsView()
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            if AppMode.current == .client {
                ClientSettingsView()
                    .tabItem { Label("Mac mini", systemImage: "desktopcomputer") }
            } else {
                ControlAPISettingsView()
                    .tabItem { Label("Remote", systemImage: "antenna.radiowaves.left.and.right") }
            }
            if AppMode.current == .runtime {
                ChannelsSettingsView()
                    .tabItem { Label("Channels", systemImage: "message") }
                LocationSettingsView()
                    .tabItem { Label("Location", systemImage: "location") }
            }
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
    @AppStorage(PermissionMode.defaultsKey) private var permissionMode = PermissionMode.standard.rawValue
    @AppStorage(AppMode.defaultsKey) private var appMode = AppMode.local.rawValue
    @State private var modeAtLaunch = AppMode.current
    @State private var autoCheckUpdates: Bool = true
    @StateObject private var remotePermission = RemotePermissionModel()
    @ObservedObject private var connection = RuntimeConnectionModel.shared

    /// Client mode edits the runtime's permission mode over the API.
    private var editsRemotePermission: Bool { connection.isClientMode && connection.isPaired }

    private var updateManager: UpdateManager? {
        (NSApp.delegate as? AppDelegate)?.updateManager
    }

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $appMode) {
                    ForEach(AppMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text((AppMode(rawValue: appMode) ?? .local).blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if AppMode(rawValue: appMode) != modeAtLaunch {
                    HStack {
                        Text("Restart Majoor to apply the new mode.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Quit Majoor") { NSApplication.shared.terminate(nil) }
                    }
                }
            } header: {
                Text("Mode")
            }

            Section {
                if editsRemotePermission {
                    Picker("Permission mode", selection: Binding(get: { remotePermission.mode }, set: { remotePermission.set($0) })) {
                        ForEach(PermissionMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!remotePermission.loaded)
                    Text((PermissionMode(rawValue: remotePermission.mode) ?? .standard).blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(remotePermission.loaded ? "This is the Mac mini's setting. You can tighten it from here; loosening it must be done on the Mac mini." : "Reading the Mac mini's setting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = remotePermission.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Picker("Permission mode", selection: $permissionMode) {
                        ForEach(PermissionMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text((PermissionMode(rawValue: permissionMode) ?? .standard).blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if connection.isClientMode {
                        Text("Applies to tasks run on this Mac (\"Run here\"). Pair with the runtime to edit its mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Permissions")
            }

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
            if editsRemotePermission { remotePermission.load() }
        }
        .onChange(of: connection.isConnected) { _, connected in
            if connected, editsRemotePermission { remotePermission.load() }
        }
    }
}

// MARK: - About

struct AboutTab: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
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
            VStack(alignment: .trailing, spacing: 1) {
                Text(model)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

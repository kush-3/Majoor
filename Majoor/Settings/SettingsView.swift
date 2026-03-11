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
            MemorySettingsView()
                .tabItem { Label("Memory", systemImage: "brain") }
            UsageSettingsView()
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true
    
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
        }
        .formStyle(.grouped)
        .padding()
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
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bolt.fill").font(.system(size: 48)).foregroundColor(.accentColor)
            Text("Majoor").font(.system(size: 24, weight: .bold))
            Text("Your AI that does the work").font(.system(size: 14)).foregroundColor(.secondary)
            Text("Version 0.3.0 — Phase 3").font(.system(size: 12)).foregroundColor(.secondary.opacity(0.7))
            Spacer()
            Link("majoor.ai", destination: URL(string: "https://majoor.ai")!).font(.caption)
            Spacer()
        }.frame(maxWidth: .infinity).padding()
    }
}

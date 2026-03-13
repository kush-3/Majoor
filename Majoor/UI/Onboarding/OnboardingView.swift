// OnboardingView.swift
// Majoor — First-Run Setup Wizard
//
// 5-step onboarding: Welcome → API Key → Integrations → Permissions → Ready
// Shown once on first launch. Can be re-run from Settings > General.

import SwiftUI
import EventKit

struct OnboardingView: View {
    @State private var currentStep = 0
    @State private var claudeKey = ""
    @State private var tavilyKey = ""
    @State private var claudeKeyValid: ValidationState = .idle
    @State private var connectedIntegrations: [String] = []
    @State private var calendarGranted = false

    var onComplete: () -> Void

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: apiKeyStep
                case 2: integrationsStep
                case 3: permissionsStep
                case 4: readyStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation bar
            HStack {
                if currentStep > 0 && currentStep < totalSteps - 1 {
                    Button("Back") { currentStep -= 1 }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Progress dots
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Circle()
                            .fill(i == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }

                Spacer()

                if currentStep == 0 {
                    Button("Get Started") { currentStep = 1 }
                        .buttonStyle(.borderedProminent)
                } else if currentStep < totalSteps - 1 {
                    if currentStep == 1 {
                        Button("Next") { currentStep += 1 }
                            .buttonStyle(.borderedProminent)
                            .disabled(claudeKeyValid != .valid)
                    } else {
                        Button("Next") { currentStep += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("Open Majoor") {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 400)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bolt.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            Text("Welcome to Majoor")
                .font(.system(size: 24, weight: .bold))
            Text("Your AI agent that lives in the menu bar.\nIt runs tasks, writes code, manages email, and more.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Spacer()
        }
        .padding()
    }

    // MARK: - Step 2: API Key

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Anthropic API Key")
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 24)

            Text("Majoor uses Claude to understand your tasks. You'll need an API key from Anthropic.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            HStack {
                SecureField("sk-ant-...", text: $claudeKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit { validateClaudeKey() }

                Button(action: { pasteFromClipboard() }) {
                    Image(systemName: "doc.on.clipboard")
                }
                .help("Paste from clipboard")

                Button("Validate") { validateClaudeKey() }
                    .buttonStyle(.bordered)
                    .disabled(claudeKey.isEmpty || claudeKeyValid == .validating)
            }

            HStack(spacing: 6) {
                switch claudeKeyValid {
                case .idle:
                    EmptyView()
                case .validating:
                    ProgressView().scaleEffect(0.6)
                    Text("Validating...").font(.system(size: 12)).foregroundColor(.secondary)
                case .valid:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("API key is valid").font(.system(size: 12)).foregroundColor(.green)
                case .invalid(let msg):
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(msg).font(.system(size: 12)).foregroundColor(.red)
                }
            }

            Spacer()

            HStack {
                Text("Don't have a key?")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Link("Get one from Anthropic Console", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.system(size: 12))
            }

            // Optional: Tavily key
            DisclosureGroup("Web Search (optional)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a Tavily API key to enable web search. You can skip this.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    HStack {
                        SecureField("tvly-...", text: $tavilyKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        if !tavilyKey.isEmpty {
                            Button("Save") {
                                APIConfig.saveTavilyKey(tavilyKey)
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
    }

    // MARK: - Step 3: Integrations

    private var integrationsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Integrations")
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 24)

            Text("Connect external services. Only GitHub is recommended to start — you can set up others later in Settings.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 10) {
                    IntegrationCard(
                        name: "GitHub",
                        icon: "chevron.left.forwardslash.chevron.right",
                        keychainKey: "github_pat",
                        placeholder: "ghp_...",
                        recommended: true,
                        connectedIntegrations: $connectedIntegrations
                    )
                    IntegrationCard(
                        name: "Slack",
                        icon: "number",
                        keychainKey: "slack_bot_token",
                        placeholder: "xoxb-...",
                        recommended: false,
                        extraCredential: ("slack_team_id", "Team ID (T0...)", "SLACK_TEAM_ID"),
                        connectedIntegrations: $connectedIntegrations
                    )
                    IntegrationCard(
                        name: "Linear",
                        icon: "lineweight",
                        keychainKey: "linear_api_key",
                        placeholder: "lin_api_...",
                        recommended: false,
                        connectedIntegrations: $connectedIntegrations
                    )
                    IntegrationCard(
                        name: "Notion",
                        icon: "doc.text",
                        keychainKey: "notion_token",
                        placeholder: "ntn_...",
                        recommended: false,
                        connectedIntegrations: $connectedIntegrations
                    )
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
    }

    // MARK: - Step 4: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 24)

            Text("Majoor can manage your calendar events through Apple Calendar.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "calendar")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calendar Access")
                            .font(.system(size: 13, weight: .medium))
                        Text("Read and create calendar events")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if calendarGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Granted").font(.system(size: 12)).foregroundColor(.green)
                    } else {
                        Button("Grant Access") {
                            requestCalendarAccess()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }

            Text("You can skip this and grant access later when Majoor first tries to use your calendar.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, 32)
        .onAppear { checkCalendarAccess() }
    }

    // MARK: - Step 5: Ready

    private var readyStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("You're all set!")
                .font(.system(size: 22, weight: .bold))

            VStack(alignment: .leading, spacing: 8) {
                SummaryRow(icon: "checkmark.circle.fill", color: .green, text: "Anthropic API key configured")

                if !tavilyKey.isEmpty || APIConfig.hasUserTavilyKey {
                    SummaryRow(icon: "checkmark.circle.fill", color: .green, text: "Web search enabled")
                } else {
                    SummaryRow(icon: "minus.circle", color: .secondary, text: "Web search — using default")
                }

                if !connectedIntegrations.isEmpty {
                    SummaryRow(icon: "checkmark.circle.fill", color: .green, text: "\(connectedIntegrations.joined(separator: ", ")) connected")
                } else {
                    SummaryRow(icon: "minus.circle", color: .secondary, text: "No integrations — set up in Settings")
                }

                if calendarGranted {
                    SummaryRow(icon: "checkmark.circle.fill", color: .green, text: "Calendar access granted")
                } else {
                    SummaryRow(icon: "minus.circle", color: .secondary, text: "Calendar — grant later when needed")
                }
            }
            .padding(.horizontal, 40)

            Text("Press ⌘⇧Space to open the command bar.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)

            Spacer()
        }
        .padding()
    }

    // MARK: - Actions

    private func pasteFromClipboard() {
        if let str = NSPasteboard.general.string(forType: .string) {
            claudeKey = str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func validateClaudeKey() {
        guard !claudeKey.isEmpty else { return }
        claudeKeyValid = .validating

        Task {
            let valid = await testAnthropicKey(claudeKey)
            await MainActor.run {
                if valid {
                    claudeKeyValid = .valid
                    APIConfig.saveClaudeKey(claudeKey)
                } else {
                    claudeKeyValid = .invalid("Invalid key or can't reach API")
                }
            }
        }
    }

    private func testAnthropicKey(_ key: String) async -> Bool {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return http.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    private func requestCalendarAccess() {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async { calendarGranted = granted }
            }
        } else {
            store.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async { calendarGranted = granted }
            }
        }
    }

    private func checkCalendarAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            calendarGranted = status == .fullAccess
        } else {
            calendarGranted = status == .authorized
        }
    }
}

// MARK: - Validation State

enum ValidationState: Equatable {
    case idle, validating, valid, invalid(String)
}

// MARK: - Summary Row

struct SummaryRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 13))
        }
    }
}

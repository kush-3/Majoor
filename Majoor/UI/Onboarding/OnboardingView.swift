// OnboardingView.swift
// Majoor — First-Run Setup Wizard
//
// macOS Setup Assistant-inspired onboarding flow.
// 5 steps: Welcome -> API Key -> Integrations -> Permissions -> Ready

import SwiftUI
import EventKit

struct OnboardingView: View {
    @State private var currentStep = 0
    @State private var direction: Int = 1
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
            .id(currentStep)
            .transition(
                direction > 0
                ? .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
                : .asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity))
            )
            .animation(DT.Anim.page, value: currentStep)

            Divider()

            // Navigation bar
            HStack {
                // Back button (fixed width to prevent layout shift)
                Group {
                    if currentStep > 0 && currentStep < totalSteps - 1 {
                        Button("Back") {
                            direction = -1
                            currentStep -= 1
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                }
                .frame(width: 80, alignment: .leading)

                Spacer()

                // Progress indicators
                HStack(spacing: 8) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Circle()
                            .fill(dotColor(for: i))
                            .frame(width: i == currentStep ? 8 : 6,
                                   height: i == currentStep ? 8 : 6)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentStep)
                    }
                }

                Spacer()

                // Next / Action button (fixed width)
                Group {
                    if currentStep == 0 {
                        Button("Get Started") {
                            direction = 1
                            currentStep = 1
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: [])
                    } else if currentStep < totalSteps - 1 {
                        Button("Continue") {
                            direction = 1
                            currentStep += 1
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(currentStep == 1 && claudeKeyValid != .valid)
                        .keyboardShortcut(.return, modifiers: [])
                    } else {
                        Button("Open Majoor") {
                            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                            onComplete()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: [])
                    }
                }
                .frame(width: 140, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: DT.Layout.onboardingWidth, height: DT.Layout.onboardingHeight)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Welcome to Majoor")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 16)

            Text("Your AI agent for macOS")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Spacer()

            Text("Runs tasks, writes code, manages email, and more \u{2014}\nright from your menu bar.")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Step 2: API Key

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Anthropic API Key")
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 28)

            Text("Majoor uses Claude to understand and execute your tasks.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            // API Key input
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SecureField("sk-ant-...", text: $claudeKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { validateClaudeKey() }

                    Button {
                        pasteFromClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .help("Paste from clipboard")

                    Button("Validate") { validateClaudeKey() }
                        .buttonStyle(.bordered)
                        .disabled(claudeKey.isEmpty || claudeKeyValid == .validating)
                }

                // Validation feedback
                HStack(spacing: 6) {
                    switch claudeKeyValid {
                    case .idle:
                        EmptyView()
                    case .validating:
                        ProgressView()
                            .controlSize(.small)
                        Text("Validating...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .valid:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("API key is valid")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .invalid(let msg):
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(height: 16)
            }
            .padding(.top, 20)

            Spacer()

            // Optional web search key
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enable web search with a Tavily API key. You can skip this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        SecureField("tvly-...", text: $tavilyKey)
                            .textFieldStyle(.roundedBorder)
                        if !tavilyKey.isEmpty {
                            Button("Save") {
                                APIConfig.saveTavilyKey(tavilyKey)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Web Search (optional)")
                    .font(.caption)
            }

            // Help link
            HStack(spacing: 4) {
                Text("Need a key?")
                    .foregroundStyle(.secondary)
                Link("console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            }
            .font(.caption)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 36)
    }

    // MARK: - Step 3: Integrations

    private var integrationsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Integrations")
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 28)

            Text("Connect services you use. You can set these up later in Settings.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            ScrollView {
                VStack(spacing: 8) {
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
                .padding(.top, 16)
            }
        }
        .padding(.horizontal, 36)
    }

    // MARK: - Step 4: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Permissions")
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 28)

            Text("Majoor can manage your calendar events through Apple Calendar.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            // Calendar permission card
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar Access")
                        .font(.system(size: 13, weight: .medium))
                    Text("Read and create calendar events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if calendarGranted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("Grant Access") {
                        requestCalendarAccess()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(0.03))
            )
            .padding(.top, 20)

            Text("You can skip this. Majoor will ask again when it first needs calendar access.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)

            Spacer()
        }
        .padding(.horizontal, 36)
        .onAppear { checkCalendarAccess() }
    }

    // MARK: - Step 5: Ready

    private var readyStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.green)

            Text("You're all set")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 12)

            // Summary
            VStack(alignment: .leading, spacing: 10) {
                SummaryRow(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    text: "Anthropic API key configured"
                )
                summaryRowForWebSearch
                summaryRowForIntegrations
                summaryRowForCalendar
            }
            .padding(.horizontal, 48)
            .padding(.top, 20)

            Spacer()

            Text("Press \u{2318}\u{21E7}Space anytime to open the command bar.")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private var summaryRowForWebSearch: some View {
        if !tavilyKey.isEmpty || APIConfig.hasUserTavilyKey {
            SummaryRow(icon: "checkmark.circle.fill", color: .green, text: "Web search enabled")
        } else {
            SummaryRow(icon: "minus.circle", color: .secondary, text: "Web search \u{2014} using default")
        }
    }

    @ViewBuilder
    private var summaryRowForIntegrations: some View {
        if !connectedIntegrations.isEmpty {
            SummaryRow(icon: "checkmark.circle.fill", color: .green, text: "\(connectedIntegrations.joined(separator: ", ")) connected")
        } else {
            SummaryRow(icon: "minus.circle", color: .secondary, text: "No integrations \u{2014} set up in Settings")
        }
    }

    @ViewBuilder
    private var summaryRowForCalendar: some View {
        if calendarGranted {
            SummaryRow(icon: "checkmark.circle.fill", color: .green, text: "Calendar access granted")
        } else {
            SummaryRow(icon: "minus.circle", color: .secondary, text: "Calendar \u{2014} grant later when needed")
        }
    }

    // MARK: - Helpers

    private func dotColor(for index: Int) -> Color {
        if index == currentStep { return .accentColor }
        if index < currentStep { return .accentColor.opacity(0.4) }
        return .secondary.opacity(0.25)
    }

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
        let store = sharedEventStore
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
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 14))
            Text(text)
                .font(.system(size: 13))
        }
    }
}

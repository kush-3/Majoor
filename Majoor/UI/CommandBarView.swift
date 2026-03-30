// CommandBarView.swift
// Majoor — Spotlight-style Command Bar
//
// Design reference: macOS Spotlight Search.
// Large centered input, material background, minimal chrome.
// Mode toggle is a subtle pill, not a loud colored button.
// Keyboard hints are whisper-quiet at the bottom.

import SwiftUI

enum CommandMode: String, CaseIterable {
    case task = "Task"
    case chat = "Chat"
}

struct CommandBarView: View {
    @State private var inputText = ""
    @State private var mode: CommandMode = {
        let saved = UserDefaults.standard.string(forKey: "commandBarMode") ?? "task"
        return CommandMode(rawValue: saved.capitalized) ?? .task
    }()
    @State private var historyIndex: Int = -1
    @FocusState private var isFocused: Bool

    let isTaskRunning: Bool
    let runningTaskInput: String
    let onSubmit: (String, CommandMode) -> Void
    let onCancel: () -> Void
    let onStop: () -> Void

    private var history: [String] {
        UserDefaults.standard.stringArray(forKey: "commandHistory") ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if isTaskRunning {
                runningState
            } else {
                inputState
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DT.Radius.large, style: .continuous)
                .fill(.ultraThickMaterial)
                .shadow(color: .black.opacity(0.20), radius: 40, y: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DT.Radius.large, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .frame(width: DT.Layout.commandBarWidth)
        .onAppear {
            if !isTaskRunning {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isFocused = true }
            }
        }
    }

    // MARK: - Running Task State

    private var runningState: some View {
        HStack(spacing: DT.Spacing.md) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: DT.Spacing.xxs) {
                Text("Running...")
                    .font(DT.Font.body(.medium))
                Text(runningTaskInput)
                    .font(DT.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onStop()
                onCancel()
            } label: {
                HStack(spacing: DT.Spacing.xs) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9))
                    Text("Stop")
                        .font(DT.Font.caption(.medium))
                }
                .foregroundStyle(.red)
                .padding(.horizontal, DT.Spacing.md)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.red.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DT.Spacing.xl)
        .padding(.vertical, DT.Spacing.lg)
    }

    // MARK: - Input State

    private var inputState: some View {
        VStack(spacing: 0) {
            HStack(spacing: DT.Spacing.md) {
                // Search icon (like Spotlight)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tertiary)

                // Input field
                TextField(placeholder, text: $inputText)
                    .textFieldStyle(.plain)
                    .font(DT.Font.largeInput)
                    .focused($isFocused)
                    .onSubmit { submitCommand() }
                    .onExitCommand { onCancel() }
                    .onKeyPress(.upArrow) { navigateHistory(direction: -1); return .handled }
                    .onKeyPress(.downArrow) { navigateHistory(direction: 1); return .handled }
                    .onKeyPress(.tab) { toggleMode(); return .handled }

                // Mode toggle — subtle pill, not a loud button
                Button(action: toggleMode) {
                    Text(mode.rawValue)
                        .font(DT.Font.caption(.medium))
                        .foregroundStyle(mode == .task ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(mode == .task ? 0.08 : 0.04))
                        )
                }
                .buttonStyle(.plain)
                .help("Tab to switch mode")

                // Submit button — only visible when there's text
                if !inputText.isEmpty {
                    Button(action: submitCommand) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, DT.Spacing.xl)
            .padding(.vertical, DT.Spacing.lg)
            .animation(DT.Anim.fast, value: inputText.isEmpty)

            // Keyboard hints — barely visible, just enough to guide
            Rectangle()
                .fill(Color.primary.opacity(0.04))
                .frame(height: 0.5)

            HStack(spacing: DT.Spacing.lg) {
                hintLabel("Return", "submit")
                hintLabel("Tab", "switch mode")
                hintLabel("\u{2191}\u{2193}", "history")
                hintLabel("Esc", "close")
                Spacer()
            }
            .padding(.horizontal, DT.Spacing.xl)
            .padding(.vertical, DT.Spacing.sm)
        }
    }

    // MARK: - Hint Label

    private func hintLabel(_ key: String, _ action: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            Text(action)
                .font(.system(size: 9))
        }
        .foregroundStyle(.quaternary)
    }

    // MARK: - Helpers

    private var placeholder: String {
        mode == .task ? "What can I help with?" : "Ask anything..."
    }

    private func toggleMode() {
        withAnimation(DT.Anim.fast) {
            mode = (mode == .task) ? .chat : .task
            UserDefaults.standard.set(mode.rawValue.lowercased(), forKey: "commandBarMode")
        }
    }

    private func submitCommand() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        var hist = history
        hist.removeAll { $0 == t }
        hist.insert(t, at: 0)
        if hist.count > 20 { hist = Array(hist.prefix(20)) }
        UserDefaults.standard.set(hist, forKey: "commandHistory")

        onSubmit(t, mode)
        inputText = ""
        historyIndex = -1
    }

    private func navigateHistory(direction: Int) {
        let hist = history
        guard !hist.isEmpty else { return }

        let newIndex = historyIndex + direction
        if newIndex < 0 {
            historyIndex = -1
            inputText = ""
        } else if newIndex < hist.count {
            historyIndex = newIndex
            inputText = hist[newIndex]
        }
    }
}

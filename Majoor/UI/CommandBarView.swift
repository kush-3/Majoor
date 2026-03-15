// CommandBarView.swift
// Majoor — Command Bar Input
//
// Spotlight-style command bar with Task/Chat mode toggle and input history.

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
    let onSubmit: (String, CommandMode) -> Void
    let onCancel: () -> Void

    private var history: [String] {
        UserDefaults.standard.stringArray(forKey: "commandHistory") ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Mode toggle
                Button(action: toggleMode) {
                    Text(mode.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(mode == .task ? .white : .accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(mode == .task ? Color.accentColor : Color.accentColor.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .help("Tab to switch mode")

                // Input field
                TextField(placeholder, text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($isFocused)
                    .onSubmit { submitCommand() }
                    .onExitCommand { onCancel() }
                    .onKeyPress(.upArrow) { navigateHistory(direction: -1); return .handled }
                    .onKeyPress(.downArrow) { navigateHistory(direction: 1); return .handled }
                    .onKeyPress(.tab) { toggleMode(); return .handled }

                // Submit button
                if !inputText.isEmpty {
                    Button(action: submitCommand) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            // Keyboard hints
            HStack(spacing: 16) {
                HintLabel(key: "Return", action: "submit")
                HintLabel(key: "Tab", action: "switch mode")
                HintLabel(key: "Up/Down", action: "history")
                HintLabel(key: "Esc", action: "close")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .frame(width: 600)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isFocused = true }
        }
    }

    private var placeholder: String {
        mode == .task ? "What can I help with?" : "Ask Majoor anything..."
    }

    private func toggleMode() {
        withAnimation(.easeInOut(duration: 0.15)) {
            mode = (mode == .task) ? .chat : .task
            UserDefaults.standard.set(mode.rawValue.lowercased(), forKey: "commandBarMode")
        }
    }

    private func submitCommand() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        // Save to history
        var hist = history
        hist.removeAll { $0 == t } // Remove duplicates
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

// MARK: - Keyboard Hint Label

private struct HintLabel: View {
    let key: String
    let action: String

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(action)
                .font(.system(size: 9))
        }
        .foregroundColor(.secondary.opacity(0.5))
    }
}

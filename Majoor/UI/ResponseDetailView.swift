// ResponseDetailView.swift
// Majoor — Full Response Viewer
//
// Scrollable view for reading long agent responses.
// Renders markdown content and collapsible tool call log.

import SwiftUI

struct ResponseDetailView: View {
    let task: AgentTask
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with metadata
            VStack(alignment: .leading, spacing: 6) {
                Text(task.userInput)
                    .font(DT.Font.body(.semibold))
                    .lineLimit(2)

                HStack(spacing: 12) {
                    if !task.modelUsed.isEmpty {
                        Label(friendlyModel(task.modelUsed), systemImage: "cpu")
                    }
                    if task.tokensUsed > 0 {
                        Label(formatTokens(task.tokensUsed), systemImage: "number")
                    }
                    if let completed = task.completedAt {
                        Label(completed.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    }
                    Spacer()
                    Button(action: copyResponse) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(didCopy ? .green : .secondary)
                    .help("Copy response")
                }
                .font(DT.Font.micro)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(DT.Opacity.cardFill))

            Divider()

            // Response body + tool log
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let responseText = fullResponseText {
                        // Try markdown rendering, fall back to plain text
                        if let attributed = try? AttributedString(markdown: responseText,
                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                            Text(attributed)
                                .font(DT.Font.body)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(responseText)
                                .font(DT.Font.body)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("No response content available.")
                            .font(DT.Font.body)
                            .foregroundColor(.secondary)
                    }

                    // Collapsible tool call log
                    if hasToolCalls {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(toolSteps.enumerated()), id: \.offset) { _, step in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: step.type == .toolCall ? "wrench.fill" : "arrow.right")
                                            .font(.system(size: 9))
                                            .foregroundColor(step.type == .toolCall ? .orange : .green)
                                            .frame(width: 12)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(step.description)
                                                .font(DT.Font.caption(.medium))
                                            if let detail = step.detail {
                                                Text(detail)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(5)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(DT.Font.micro)
                                Text("Tool Calls (\(toolSteps.filter { $0.type == .toolCall }.count))")
                                    .font(DT.Font.caption(.medium))
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Computed

    private var fullResponseText: String? {
        task.steps.last(where: { $0.type == .response })?.description
    }

    private var hasToolCalls: Bool {
        task.steps.contains(where: { $0.type == .toolCall || $0.type == .toolResult })
    }

    private var toolSteps: [TaskStep] {
        task.steps.filter { $0.type == .toolCall || $0.type == .toolResult }
    }

    // MARK: - Actions

    private func copyResponse() {
        guard let text = fullResponseText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }

}

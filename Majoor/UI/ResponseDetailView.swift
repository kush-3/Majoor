// ResponseDetailView.swift
// Majoor — Full Response Viewer
//
// Design reference: Xcode's inspector panel / Preview.app.
// Metadata bar at top with copy action, body below with markdown.
// Tool call log is a collapsible section, not a separate view.

import SwiftUI

struct ResponseDetailView: View {
    let task: AgentTask
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            // Metadata header — compact, material background
            metadataHeader

            // Response body + tool log
            ScrollView {
                VStack(alignment: .leading, spacing: DT.Spacing.xl) {
                    if let responseText = fullResponseText {
                        if let attributed = try? AttributedString(
                            markdown: responseText,
                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                        ) {
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
                        VStack(spacing: DT.Spacing.sm) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 24, weight: .thin))
                                .foregroundStyle(.quaternary)
                            Text("No response content")
                                .font(DT.Font.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, DT.Spacing.xxxl)
                    }

                    // Tool call log
                    if hasToolCalls {
                        toolCallLog
                    }
                }
                .padding(DT.Spacing.lg)
            }
        }
    }

    // MARK: - Metadata Header

    private var metadataHeader: some View {
        VStack(alignment: .leading, spacing: DT.Spacing.sm) {
            Text(task.userInput)
                .font(DT.Font.body(.semibold))
                .lineLimit(2)

            HStack(spacing: DT.Spacing.md) {
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
                        .foregroundStyle(didCopy ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy response")
            }
            .font(DT.Font.micro)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DT.Spacing.lg)
        .padding(.vertical, DT.Spacing.md)
        .background(.ultraThinMaterial)
    }

    // MARK: - Tool Call Log

    private var toolCallLog: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: DT.Spacing.xs) {
                ForEach(Array(toolSteps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: DT.Spacing.sm) {
                        Image(systemName: step.type == .toolCall ? "wrench.fill" : "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(step.type == .toolCall ? .orange : .green)
                            .frame(width: 12)

                        VStack(alignment: .leading, spacing: DT.Spacing.xxs) {
                            Text(step.description)
                                .font(DT.Font.caption(.medium))
                            if let detail = step.detail {
                                Text(detail)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(5)
                            }
                        }
                    }
                    .padding(.vertical, DT.Spacing.xxs)
                }
            }
        } label: {
            HStack(spacing: DT.Spacing.xs) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(DT.Font.micro)
                Text("Tool Calls (\(toolSteps.filter { $0.type == .toolCall }.count))")
                    .font(DT.Font.caption(.medium))
            }
            .foregroundStyle(.secondary)
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

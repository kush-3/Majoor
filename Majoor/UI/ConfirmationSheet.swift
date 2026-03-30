// ConfirmationSheet.swift
// Majoor — Interactive Confirmation View
//
// Design reference: macOS system confirmation dialogs.
// Clear hierarchy: icon + title, body content, action footer.
// Approve is the prominent action, Deny is secondary.
// Feedback field is optional and unobtrusive.

import SwiftUI

struct ConfirmationSheet: View {
    let confirmation: ConfirmationContext
    @EnvironmentObject var taskManager: TaskManager
    @State private var feedbackText: String = ""
    @FocusState private var feedbackFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: DT.Spacing.sm) {
                Image(systemName: headerIcon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(headerColor)

                VStack(alignment: .leading, spacing: DT.Spacing.xxs) {
                    Text(headerTitle)
                        .font(DT.Font.headline)
                    Text("Review the details below before continuing")
                        .font(DT.Font.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, DT.Spacing.xl)
            .padding(.vertical, DT.Spacing.lg)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: DT.Spacing.md) {
                    // Confirmation context
                    VStack(alignment: .leading, spacing: DT.Spacing.sm) {
                        Text(confirmation.title)
                            .font(DT.Font.body(.medium))

                        Text(confirmation.body)
                            .font(DT.Font.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Pipeline steps
                    if taskManager.pendingPipelinePlan != nil {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 0.5)
                            .padding(.vertical, DT.Spacing.xs)

                        VStack(alignment: .leading, spacing: DT.Spacing.sm) {
                            ForEach(Array(taskManager.pipelineSteps.enumerated()), id: \.element.id) { index, step in
                                HStack(alignment: .top, spacing: DT.Spacing.sm) {
                                    Button(action: { taskManager.togglePipelineStep(at: index) }) {
                                        Image(systemName: step.enabled ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 16))
                                            .foregroundColor(step.enabled ? .accentColor : .secondary.opacity(0.35))
                                    }
                                    .buttonStyle(.plain)

                                    Text("\(index + 1). \(step.planDescription)")
                                        .font(DT.Font.caption)
                                        .foregroundStyle(step.enabled ? .primary : .tertiary)
                                        .strikethrough(!step.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, DT.Spacing.xl)
                .padding(.vertical, DT.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Footer: feedback + actions
            VStack(spacing: DT.Spacing.md) {
                // Subtle separator
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)

                // Feedback input
                TextField("Add a note (optional)", text: $feedbackText)
                    .textFieldStyle(.plain)
                    .font(DT.Font.caption)
                    .padding(.horizontal, DT.Spacing.md)
                    .padding(.vertical, DT.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DT.Radius.small, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .focused($feedbackFocused)
                    .onSubmit { resolveConfirmation(approved: true) }

                // Action buttons — Apple style: secondary left, primary right
                HStack(spacing: DT.Spacing.sm) {
                    if taskManager.pendingPipelinePlan != nil {
                        let enabled = taskManager.pipelineSteps.filter(\.enabled).count
                        let total = taskManager.pipelineSteps.count
                        Text("\(enabled)/\(total) steps")
                            .font(DT.Font.micro)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    // Deny — secondary style
                    Button("Deny") {
                        resolveConfirmation(approved: false)
                    }
                    .buttonStyle(.plain)
                    .font(DT.Font.body(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DT.Spacing.lg)
                    .padding(.vertical, DT.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DT.Radius.small, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .keyboardShortcut(.escape, modifiers: [])

                    // Approve — primary accent style
                    Button("Approve") {
                        resolveConfirmation(approved: true)
                    }
                    .buttonStyle(.plain)
                    .font(DT.Font.body(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DT.Spacing.lg)
                    .padding(.vertical, DT.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DT.Radius.small, style: .continuous)
                            .fill(Color.accentColor)
                    )
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.horizontal, DT.Spacing.xl)
            .padding(.vertical, DT.Spacing.md)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Helpers

    private var headerTitle: String {
        switch confirmation.category {
        case NotificationManager.confirmEmailCategory:
            return "Send this email?"
        case NotificationManager.confirmDeleteCategory:
            return "Delete this event?"
        case NotificationManager.pipelineConfirmCategory:
            return "Run this pipeline?"
        default:
            return "Confirm this action?"
        }
    }

    private var headerIcon: String {
        switch confirmation.category {
        case NotificationManager.confirmEmailCategory:
            return "envelope.badge.shield.half.filled"
        case NotificationManager.confirmDeleteCategory:
            return "trash.circle"
        case NotificationManager.pipelineConfirmCategory:
            return "arrow.triangle.branch"
        default:
            return "exclamationmark.shield"
        }
    }

    private var headerColor: Color {
        switch confirmation.category {
        case NotificationManager.confirmDeleteCategory:
            return .red
        case NotificationManager.pipelineConfirmCategory:
            return .accentColor
        default:
            return .orange
        }
    }

    private func resolveConfirmation(approved: Bool) {
        let feedback = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await ConfirmationManager.shared.resolve(
                id: confirmation.id,
                approved: approved,
                feedback: feedback.isEmpty ? nil : feedback
            )
        }
        taskManager.clearConfirmation()
    }
}

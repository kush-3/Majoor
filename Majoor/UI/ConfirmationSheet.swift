// ConfirmationSheet.swift
// Majoor — Interactive Confirmation View
//
// Full in-app confirmation view with context display and text feedback input.
// Replaces the simple approve/deny binary with interactive feedback.
// Works for all confirmation types: email, calendar, pipeline, generic.

import SwiftUI

struct ConfirmationSheet: View {
    let confirmation: ConfirmationContext
    @EnvironmentObject var taskManager: TaskManager
    @State private var feedbackText: String = ""
    @FocusState private var feedbackFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(headerColor)
                Text("Confirmation Required")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(confirmation.title)
                        .font(.system(size: 13, weight: .medium))

                    Text(confirmation.body)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    // Pipeline steps (if this is a pipeline confirmation with steps)
                    if taskManager.pendingPipelinePlan != nil {
                        Divider().padding(.vertical, 4)

                        ForEach(Array(taskManager.pipelineSteps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Button(action: { taskManager.togglePipelineStep(at: index) }) {
                                    Image(systemName: step.enabled ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 15))
                                        .foregroundColor(step.enabled ? .accentColor : .secondary.opacity(0.4))
                                }
                                .buttonStyle(.plain)

                                Text("\(index + 1). \(step.planDescription)")
                                    .font(.system(size: 12))
                                    .foregroundColor(step.enabled ? .primary : .secondary.opacity(0.5))
                                    .strikethrough(!step.enabled)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            // Feedback input + action buttons
            VStack(spacing: 10) {
                TextField("Add a note (optional)", text: $feedbackText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .focused($feedbackFocused)

                HStack(spacing: 10) {
                    if taskManager.pendingPipelinePlan != nil {
                        let enabled = taskManager.pipelineSteps.filter(\.enabled).count
                        let total = taskManager.pipelineSteps.count
                        Text("\(enabled)/\(total) steps")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Deny") {
                        resolveConfirmation(approved: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Approve") {
                        resolveConfirmation(approved: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Helpers

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

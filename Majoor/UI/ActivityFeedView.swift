// ActivityFeedView.swift
// Majoor — Activity Feed
//
// Displays recent tasks with polished Apple HIG-style cards.
// Groups running tasks separately from completed/failed.

import SwiftUI

struct ActivityFeedView: View {
    @EnvironmentObject var taskManager: TaskManager
    var onViewResponse: ((AgentTask) -> Void)? = nil

    var body: some View {
        if taskManager.tasks.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("No tasks yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Press Cmd+Shift+Space to get started")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.6))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Running tasks section
                    let running = taskManager.tasks.filter { $0.status == .running || $0.status == .waiting }
                    if !running.isEmpty {
                        SectionHeader(title: "Running")
                        ForEach(running) { task in
                            TaskCardView(task: task, onViewResponse: onViewResponse)
                        }
                    }

                    // Completed tasks section
                    let completed = taskManager.tasks.filter { $0.status == .completed || $0.status == .failed }
                    if !completed.isEmpty {
                        SectionHeader(title: "Recent")
                        ForEach(completed) { task in
                            TaskCardView(task: task, onViewResponse: onViewResponse)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Task Card

struct TaskCardView: View {
    @ObservedObject var task: AgentTask
    @State private var isExpanded = false
    var onViewResponse: ((AgentTask) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: status + timestamp
            HStack(spacing: 6) {
                statusIcon
                Text(task.status.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
                Spacer()
                Text(task.createdAt.timeAgo())
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            // User input
            Text(task.userInput)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(isExpanded ? nil : 2)

            // Summary (completed tasks)
            if !task.summary.isEmpty && task.status != .running {
                Text(task.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(isExpanded ? nil : 2)
            }

            // Expanded step details
            if isExpanded {
                Divider().padding(.vertical, 2)
                ForEach(task.steps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        stepIcon(step.type).frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.description)
                                .font(.system(size: 11))
                                .lineLimit(3)
                            if let d = step.detail {
                                Text(d)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
            }

            // Action buttons
            HStack(spacing: 12) {
                if !task.steps.isEmpty {
                    Button(isExpanded ? "Collapse" : "Details") {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                if hasLongResponse {
                    Button("View Response") { onViewResponse?(task) }
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                }
                Spacer()
                if task.tokensUsed > 0 {
                    HStack(spacing: 4) {
                        Text(friendlyModel(task.modelUsed))
                        Text("·")
                        Text(formatTokens(task.tokensUsed))
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        .padding(.vertical, 3)
    }

    // MARK: - Helpers

    private var hasLongResponse: Bool {
        guard task.status == .completed else { return false }
        guard let responseStep = task.steps.last(where: { $0.type == .response }) else { return false }
        return responseStep.description.count > 200
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .running:
            Image(systemName: "circle.dotted")
                .font(.system(size: 12))
                .foregroundColor(.orange)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
        case .waiting:
            Image(systemName: "clock.fill")
                .font(.system(size: 12))
                .foregroundColor(.blue)
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .running: return .orange
        case .completed: return .green
        case .failed: return .red
        case .waiting: return .blue
        }
    }

    private func stepIcon(_ type: TaskStep.StepType) -> some View {
        switch type {
        case .thinking: return Image(systemName: "brain").font(.system(size: 10)).foregroundColor(.purple)
        case .toolCall: return Image(systemName: "wrench").font(.system(size: 10)).foregroundColor(.orange)
        case .toolResult: return Image(systemName: "checkmark.circle").font(.system(size: 10)).foregroundColor(.green)
        case .response: return Image(systemName: "text.bubble").font(.system(size: 10)).foregroundColor(.blue)
        case .error: return Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundColor(.red)
        }
    }

    private func friendlyModel(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("haiku") { return "Haiku" }
        if model.contains("sonnet") { return "Sonnet" }
        return model
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 { return String(format: "%.1fK", Double(tokens) / 1000) }
        return "\(tokens)"
    }
}

extension Date {
    func timeAgo() -> String {
        let s = Int(-timeIntervalSinceNow)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

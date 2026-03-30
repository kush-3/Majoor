// ActivityFeedView.swift
// Majoor — Activity Feed
//
// Design reference: macOS Notification Center.
// Cards float on material, no hard borders, grouped by status.
// Subtle hover states, compact metadata, generous whitespace.

import SwiftUI

struct ActivityFeedView: View {
    @EnvironmentObject var taskManager: TaskManager
    var onViewResponse: ((AgentTask) -> Void)? = nil

    var body: some View {
        if taskManager.tasks.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Running tasks
                    let running = taskManager.tasks.filter { $0.status == .running || $0.status == .waiting }
                    if !running.isEmpty {
                        sectionHeader("Active")
                        ForEach(running) { task in
                            TaskCardView(task: task, onViewResponse: onViewResponse)
                        }
                    }

                    // Completed tasks
                    let completed = taskManager.tasks.filter { $0.status == .completed || $0.status == .failed }
                    if !completed.isEmpty {
                        sectionHeader("Recent")
                        ForEach(completed) { task in
                            TaskCardView(task: task, onViewResponse: onViewResponse)
                        }
                    }
                }
                .padding(.horizontal, DT.Spacing.md)
                .padding(.vertical, DT.Spacing.sm)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DT.Spacing.lg) {
            Spacer()

            Image(systemName: "tray")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.quaternary)

            VStack(spacing: DT.Spacing.xs) {
                Text("No tasks yet")
                    .font(DT.Font.body(.medium))
                    .foregroundStyle(.secondary)
                Text("Press \u{2318}\u{21E7}Space to get started")
                    .font(DT.Font.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(DT.Font.caption(.medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, DT.Spacing.xs)
        .padding(.top, DT.Spacing.md)
        .padding(.bottom, DT.Spacing.xs)
    }
}

// MARK: - Task Card
//
// Each task card is a subtle vibrancy surface that reveals detail on hover/tap.
// No hard borders. Status communicated through icon + color, not background fills.

struct TaskCardView: View {
    @ObservedObject var task: AgentTask
    @State private var isExpanded = false
    @State private var isHovered = false
    var onViewResponse: ((AgentTask) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DT.Spacing.sm) {
            // Top row: status icon + input text + timestamp
            HStack(alignment: .top, spacing: DT.Spacing.sm) {
                statusIcon
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: DT.Spacing.xxs) {
                    Text(task.userInput)
                        .font(DT.Font.body(.medium))
                        .lineLimit(isExpanded ? nil : 2)

                    // Summary (completed/failed only)
                    if !task.summary.isEmpty && task.status != .running {
                        Text(task.summary)
                            .font(DT.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                    }
                }

                Spacer(minLength: DT.Spacing.sm)

                Text(task.createdAt.timeAgo())
                    .font(DT.Font.micro)
                    .foregroundStyle(.tertiary)
            }

            // Expanded detail
            if isExpanded {
                expandedSteps
            }

            // Footer: actions + metadata
            HStack(spacing: DT.Spacing.sm) {
                if !task.steps.isEmpty {
                    Button {
                        withAnimation(DT.Anim.normal) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                            Text(isExpanded ? "Less" : "Details")
                                .font(DT.Font.micro(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if hasLongResponse {
                    Button {
                        onViewResponse?(task)
                    } label: {
                        Text("View Response")
                            .font(DT.Font.micro(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if task.tokensUsed > 0 {
                    HStack(spacing: 3) {
                        Text(friendlyModel(task.modelUsed))
                        Text("\u{00B7}")
                        Text(formatTokens(task.tokensUsed))
                    }
                    .font(DT.Font.micro)
                    .foregroundStyle(.quaternary)
                }
            }
        }
        .padding(DT.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DT.Radius.medium, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? DT.Opacity.hoverFill : DT.Opacity.cardFill))
        )
        .cardShadow()
        .padding(.vertical, DT.Spacing.xxs)
        .onHover { hovering in
            withAnimation(DT.Anim.fast) { isHovered = hovering }
        }
    }

    // MARK: - Expanded Steps

    private var expandedSteps: some View {
        VStack(alignment: .leading, spacing: DT.Spacing.xs) {
            ForEach(task.steps) { step in
                HStack(alignment: .top, spacing: DT.Spacing.sm) {
                    stepIcon(step.type)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: DT.Spacing.xxs) {
                        Text(step.description)
                            .font(DT.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        if let d = step.detail {
                            Text(d)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(4)
                        }
                    }
                }
            }
        }
        .padding(DT.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DT.Radius.small, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
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
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
        case .waiting:
            Image(systemName: "clock.fill")
                .font(.system(size: 13))
                .foregroundStyle(.blue)
        }
    }

    private func stepIcon(_ type: TaskStep.StepType) -> some View {
        let name: String
        let color: Color
        switch type {
        case .thinking:  name = "brain"; color = .purple
        case .toolCall:  name = "wrench"; color = .orange
        case .toolResult: name = "checkmark.circle"; color = .green
        case .response:  name = "text.bubble"; color = .blue
        case .error:     name = "exclamationmark.triangle"; color = .red
        }
        return Image(systemName: name)
            .font(.system(size: 10))
            .foregroundStyle(color)
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

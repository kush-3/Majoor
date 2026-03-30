// PipelineProgressView.swift
// Majoor — Real-time Pipeline Progress
//
// Shows step-by-step progress during pipeline execution.
// Observes TaskManager.pipelineSteps for real-time updates.
// Each step shows pending/running/completed/failed/skipped status.

import SwiftUI

struct PipelineProgressView: View {
    @EnvironmentObject var taskManager: TaskManager
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundColor(.accentColor)
                Text("Pipeline: \"\(title)\"")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                overallStatusIcon
            }

            // Progress bar
            progressBar

            Divider()

            // Steps
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(taskManager.pipelineSteps.enumerated()), id: \.element.id) { index, step in
                        PipelineStepRow(step: step, index: index + 1)
                    }
                }
            }

            Divider()

            // Footer: progress summary
            HStack {
                let completed = taskManager.pipelineSteps.filter { $0.status == .completed }.count
                let total = taskManager.pipelineSteps.filter { $0.enabled }.count
                let failed = taskManager.pipelineSteps.filter { $0.status == .failed }.count
                let currentStep = taskManager.pipelineSteps.firstIndex { $0.status == .running }.map { $0 + 1 }

                if let current = currentStep {
                    Text("Step \(current) of \(total)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else if completed == total && total > 0 {
                    Text("All \(total) steps completed")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                } else {
                    Text("\(completed)/\(total) steps completed")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                if failed > 0 {
                    Text("(\(failed) failed)")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }

                Spacer()

                if let start = taskManager.pipelineStartTime {
                    TimelineView(.periodic(from: start, by: 1)) { _ in
                        let elapsed = Int(Date().timeIntervalSince(start))
                        Text("\(elapsed)s elapsed")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(12)
    }

    private var progressBar: some View {
        let total = taskManager.pipelineSteps.filter(\.enabled).count
        let completed = taskManager.pipelineSteps.filter { $0.status == .completed }.count
        let fraction = total > 0 ? CGFloat(completed) / CGFloat(total) : 0

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DT.Color.surfaceCard)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(DT.Color.accent)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
        .animation(DT.Anim.slow, value: completed)
    }

    @ViewBuilder
    private var overallStatusIcon: some View {
        let allDone = taskManager.pipelineSteps.allSatisfy {
            $0.status == .completed || $0.status == .failed || $0.status == .skipped || !$0.enabled
        }
        let hasFailure = taskManager.pipelineSteps.contains { $0.status == .failed }

        if allDone && !taskManager.pipelineSteps.isEmpty {
            if hasFailure {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

// MARK: - Pipeline Step Row

struct PipelineStepRow: View {
    let step: PipelineStep
    let index: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            stepIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(index). \(step.planDescription)")
                        .font(.system(size: 12, weight: step.status == .running ? .medium : .regular))
                        .foregroundColor(textColor)
                        .strikethrough(!step.enabled && step.status == .pending)
                }

                if let result = step.result {
                    Text(result)
                        .font(DT.Font.micro)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                if let error = step.error {
                    Text(error)
                        .font(DT.Font.micro)
                        .foregroundColor(DT.Color.error)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, DT.Spacing.sm)
        .padding(.vertical, DT.Spacing.xs)
        .background(
            step.status == .running
                ? DT.Color.surfaceCard
                : .clear,
            in: RoundedRectangle(cornerRadius: DT.Radius.small, style: .continuous)
        )
    }

    private var textColor: Color {
        switch step.status {
        case .pending: return step.enabled ? .secondary : .secondary.opacity(0.4)
        case .running: return .primary
        case .completed: return DT.Color.textTertiary
        case .failed: return DT.Color.error
        case .skipped: return .secondary.opacity(0.5)
        }
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch step.status {
        case .pending:
            if step.enabled {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary.opacity(0.4))
            } else {
                Image(systemName: "forward.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.orange.opacity(0.5))
            }
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.red)
        case .skipped:
            Image(systemName: "forward.circle")
                .font(.system(size: 14))
                .foregroundColor(.orange)
        }
    }
}

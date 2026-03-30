// PipelineProgressView.swift
// Majoor — Real-time Pipeline Progress
//
// Design reference: Xcode build progress.
// Clean step list with status icons, thin progress bar,
// elapsed time in monospaced font. No visual clutter.

import SwiftUI

struct PipelineProgressView: View {
    @EnvironmentObject var taskManager: TaskManager
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: DT.Spacing.sm) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)

                Text(title)
                    .font(DT.Font.body(.medium))
                    .lineLimit(1)

                Spacer()

                overallStatusIcon
            }
            .padding(.horizontal, DT.Spacing.lg)
            .padding(.top, DT.Spacing.lg)
            .padding(.bottom, DT.Spacing.md)

            // Progress bar
            progressBar
                .padding(.horizontal, DT.Spacing.lg)

            // Steps
            ScrollView {
                VStack(alignment: .leading, spacing: DT.Spacing.xxs) {
                    ForEach(Array(taskManager.pipelineSteps.enumerated()), id: \.element.id) { index, step in
                        PipelineStepRow(step: step, index: index + 1)
                    }
                }
                .padding(.horizontal, DT.Spacing.md)
                .padding(.vertical, DT.Spacing.md)
            }

            // Footer
            HStack {
                footerStatus
                Spacer()
                if let start = taskManager.pipelineStartTime {
                    TimelineView(.periodic(from: start, by: 1)) { _ in
                        let elapsed = Int(Date().timeIntervalSince(start))
                        Text("\(elapsed)s")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, DT.Spacing.lg)
            .padding(.vertical, DT.Spacing.md)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        let total = taskManager.pipelineSteps.filter(\.enabled).count
        let completed = taskManager.pipelineSteps.filter { $0.status == .completed }.count
        let fraction = total > 0 ? CGFloat(completed) / CGFloat(total) : 0

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
        .animation(DT.Anim.slow, value: completed)
    }

    // MARK: - Overall Status Icon

    @ViewBuilder
    private var overallStatusIcon: some View {
        let allDone = taskManager.pipelineSteps.allSatisfy {
            $0.status == .completed || $0.status == .failed || $0.status == .skipped || !$0.enabled
        }
        let hasFailure = taskManager.pipelineSteps.contains { $0.status == .failed }

        if allDone && !taskManager.pipelineSteps.isEmpty {
            if hasFailure {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
        }
    }

    // MARK: - Footer Status

    @ViewBuilder
    private var footerStatus: some View {
        let completed = taskManager.pipelineSteps.filter { $0.status == .completed }.count
        let total = taskManager.pipelineSteps.filter { $0.enabled }.count
        let failed = taskManager.pipelineSteps.filter { $0.status == .failed }.count
        let currentStep = taskManager.pipelineSteps.firstIndex { $0.status == .running }.map { $0 + 1 }

        HStack(spacing: DT.Spacing.sm) {
            if let current = currentStep {
                Text("Step \(current) of \(total)")
                    .font(DT.Font.caption)
                    .foregroundStyle(.secondary)
            } else if completed == total && total > 0 {
                Text("All \(total) steps completed")
                    .font(DT.Font.caption)
                    .foregroundStyle(.green)
            } else {
                Text("\(completed)/\(total) completed")
                    .font(DT.Font.caption)
                    .foregroundStyle(.secondary)
            }

            if failed > 0 {
                Text("(\(failed) failed)")
                    .font(DT.Font.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Pipeline Step Row

struct PipelineStepRow: View {
    let step: PipelineStep
    let index: Int

    var body: some View {
        HStack(alignment: .top, spacing: DT.Spacing.sm) {
            stepIcon
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: DT.Spacing.xxs) {
                Text("\(index). \(step.planDescription)")
                    .font(DT.Font.caption(step.status == .running ? .medium : .regular))
                    .foregroundStyle(textColor)
                    .strikethrough(!step.enabled && step.status == .pending)

                if let result = step.result {
                    Text(result)
                        .font(DT.Font.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let error = step.error {
                    Text(error)
                        .font(DT.Font.micro)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, DT.Spacing.sm)
        .padding(.vertical, DT.Spacing.xs)
        .background(
            step.status == .running
                ? RoundedRectangle(cornerRadius: DT.Radius.small, style: .continuous)
                    .fill(Color.primary.opacity(DT.Opacity.cardFill))
                : nil
        )
    }

    private var textColor: Color {
        switch step.status {
        case .pending: return step.enabled ? .secondary : DT.Color.textQuaternary
        case .running: return .primary
        case .completed: return DT.Color.textTertiary
        case .failed: return DT.Color.error
        case .skipped: return DT.Color.textQuaternary
        }
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch step.status {
        case .pending:
            Image(systemName: step.enabled ? "circle" : "forward.circle")
                .font(.system(size: 13))
                .foregroundColor(step.enabled ? .secondary.opacity(0.35) : .orange.opacity(0.5))
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
        case .skipped:
            Image(systemName: "forward.circle")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
        }
    }
}

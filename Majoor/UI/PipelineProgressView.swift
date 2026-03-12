// PipelineProgressView.swift
// Majoor — Real-time Pipeline Progress
//
// Shows step-by-step progress during pipeline execution.
// Each step shows pending/running/completed/failed status.

import SwiftUI

struct PipelineProgressView: View {
    @ObservedObject var task: AgentTask
    let planText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundColor(.accentColor)
                Text("Pipeline Running")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if task.status == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if task.status == .failed {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }

            Divider()

            // Steps
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pipelineSteps) { step in
                        HStack(alignment: .top, spacing: 8) {
                            stepIcon(for: step)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.label)
                                    .font(.system(size: 12, weight: step.status == .running ? .medium : .regular))
                                    .foregroundColor(step.status == .pending ? .secondary : .primary)
                                if let detail = step.detail {
                                    Text(detail)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: - Step Tracking

    struct PipelineStep: Identifiable {
        let id = UUID()
        let label: String
        let status: StepStatus
        let detail: String?

        enum StepStatus {
            case pending, running, completed, failed
        }
    }

    private var pipelineSteps: [PipelineStep] {
        // Map task steps to pipeline progress
        var steps: [PipelineStep] = []
        var currentToolCall: String?

        for taskStep in task.steps {
            switch taskStep.type {
            case .toolCall:
                let toolName = extractToolName(from: taskStep.description)
                currentToolCall = toolName
                // Check if there's a result for this tool call
                let hasResult = task.steps.contains { $0.type == .toolResult && $0.description.contains(toolName) }
                let hasFailed = taskStep.detail?.contains("Error") == true

                if hasResult {
                    steps.append(PipelineStep(
                        label: friendlyName(for: toolName),
                        status: hasFailed ? .failed : .completed,
                        detail: taskStep.detail
                    ))
                } else {
                    steps.append(PipelineStep(
                        label: friendlyName(for: toolName),
                        status: .running,
                        detail: nil
                    ))
                }

            case .toolResult:
                // Already handled above
                break

            case .response:
                if task.status == .completed {
                    steps.append(PipelineStep(
                        label: "Pipeline complete",
                        status: .completed,
                        detail: String(taskStep.description.prefix(100))
                    ))
                }

            case .error:
                steps.append(PipelineStep(
                    label: "Error",
                    status: .failed,
                    detail: taskStep.description
                ))

            case .thinking:
                break
            }
        }

        // If no steps yet, show the plan as pending
        if steps.isEmpty {
            let planLines = planText.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") || $0.trimmingCharacters(in: .whitespaces).first?.isNumber == true }
            for line in planLines.prefix(8) {
                let cleanLine = line.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "^[0-9]+\\.\\s*", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression)
                steps.append(PipelineStep(label: cleanLine, status: .pending, detail: nil))
            }
        }

        return steps
    }

    private func extractToolName(from description: String) -> String {
        // "Calling github__create_pull_request" → "github__create_pull_request"
        description.replacingOccurrences(of: "Calling ", with: "")
    }

    private func friendlyName(for toolName: String) -> String {
        // Convert tool names to readable labels
        let mappings: [String: String] = [
            "git_status": "Check git status",
            "git_diff": "View changes",
            "git_commit": "Commit changes",
            "git_push": "Push to remote",
            "git_create_pr": "Create pull request",
        ]
        if let mapped = mappings[toolName] { return mapped }

        // For MCP tools: "github__create_pull_request" → "Create pull request (GitHub)"
        if toolName.contains("__") {
            let parts = toolName.split(separator: "_", maxSplits: 1)
            if parts.count == 2 {
                let server = parts[0].replacingOccurrences(of: "_", with: "")
                let tool = String(parts[1]).replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                return "\(tool.capitalized) (\(server.capitalized))"
            }
        }

        return toolName.replacingOccurrences(of: "_", with: " ").capitalized
    }

    @ViewBuilder
    private func stepIcon(for step: PipelineStep) -> some View {
        switch step.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.green)
        case .running:
            ProgressView()
                .scaleEffect(0.5)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.red)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 14))
                .foregroundColor(.secondary.opacity(0.4))
        }
    }
}

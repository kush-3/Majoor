// MainPanelView.swift
// Majoor — Dropdown Panel

import SwiftUI

struct MainPanelView: View {
    @EnvironmentObject var taskManager: TaskManager
    @State private var selectedTab = 0
    @State private var selectedTask: AgentTask?

    var body: some View {
        VStack(spacing: 0) {
            if let task = selectedTask {
                // Response detail view
                HStack {
                    Button(action: { selectedTask = nil }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 11))
                            Text("Back").font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                ResponseDetailView(task: task)
            } else if let confirmId = taskManager.pendingConfirmationId,
                      let confirmTitle = taskManager.pendingConfirmationTitle,
                      let confirmBody = taskManager.pendingConfirmationBody {
                // In-app confirmation view
                ConfirmationView(
                    confirmTitle: confirmTitle,
                    confirmBody: confirmBody,
                    onApprove: {
                        Task { await ConfirmationManager.shared.resolve(id: confirmId, approved: true) }
                    },
                    onDeny: {
                        Task { await ConfirmationManager.shared.resolve(id: confirmId, approved: false) }
                    }
                )
            } else if let planText = taskManager.pendingPipelinePlan,
                      let taskId = taskManager.pendingPipelineTaskId {
                // Pipeline plan or progress view
                if taskManager.pipelineExecuting {
                    // Pipeline is executing — show progress
                    let title = taskManager.tasks.first(where: { $0.id == taskId })?.userInput ?? "Pipeline"
                    PipelineProgressView(title: String(title.prefix(50)))
                        .environmentObject(taskManager)
                } else {
                    // Pipeline waiting for approval — show plan with inline editing + approve/deny
                    PipelinePlanView(
                        planText: planText,
                        steps: $taskManager.pipelineSteps,
                        confirmationId: taskManager.pendingConfirmationId,
                        onToggleStep: { index in
                            taskManager.togglePipelineStep(at: index)
                        },
                        onApprove: {
                            if let id = taskManager.pendingConfirmationId {
                                Task { await ConfirmationManager.shared.resolve(id: id, approved: true) }
                            }
                        },
                        onDeny: {
                            if let id = taskManager.pendingConfirmationId {
                                Task { await ConfirmationManager.shared.resolve(id: id, approved: false) }
                            }
                        }
                    )
                }
            } else {
                // Normal panel
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.system(size: 14, weight: .semibold)).foregroundColor(.accentColor)
                        Text("Majoor").font(.system(size: 14, weight: .semibold))
                    }
                    Spacer()
                    Picker("", selection: $selectedTab) {
                        Text("Activity").tag(0)
                        Text("Chat").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                Divider()

                if selectedTab == 0 {
                    ActivityFeedView(onViewResponse: { task in
                        selectedTask = task
                    }).environmentObject(taskManager)
                } else {
                    VStack { Spacer()
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 36)).foregroundColor(.secondary.opacity(0.5))
                        Text("Chat mode coming soon").font(.system(size: 13)).foregroundColor(.secondary)
                        Spacer()
                    }.frame(maxWidth: .infinity)
                }
            }
        }
        .frame(width: 380, height: 500)
        .background(.regularMaterial)
        .onReceive(NotificationCenter.default.publisher(for: .majoorOpenTaskDetail)) { notification in
            if let taskId = notification.userInfo?["taskId"] as? String,
               let task = taskManager.tasks.first(where: { $0.id.uuidString == taskId }) {
                selectedTask = task
            }
        }
    }
}

// MARK: - Confirmation View

struct ConfirmationView: View {
    let confirmTitle: String
    let confirmBody: String
    var onApprove: () -> Void
    var onDeny: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "exclamationmark.shield")
                    .foregroundColor(.orange)
                Text("Confirmation Required")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 12) {
                Text(confirmTitle)
                    .font(.system(size: 13, weight: .medium))
                Text(confirmBody)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Spacer()
                Button("Deny") { onDeny() }
                    .buttonStyle(.bordered)
                Button("Approve") { onApprove() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Pipeline Plan View (with inline step editing)

struct PipelinePlanView: View {
    let planText: String
    @Binding var steps: [PipelineStep]
    let confirmationId: String?
    var onToggleStep: (Int) -> Void
    var onApprove: () -> Void
    var onDeny: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundColor(.accentColor)
                Text("Pipeline Plan")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                let enabled = steps.filter(\.enabled).count
                let total = steps.count
                if total > 0 {
                    Text("\(enabled)/\(total) steps")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Steps with toggle
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if steps.isEmpty {
                        // Fallback: show raw plan text if steps weren't parsed
                        Text(planText)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Button(action: { onToggleStep(index) }) {
                                    Image(systemName: step.enabled ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 16))
                                        .foregroundColor(step.enabled ? .accentColor : .secondary.opacity(0.4))
                                }
                                .buttonStyle(.plain)

                                Text("\(index + 1). \(step.planDescription)")
                                    .font(.system(size: 12))
                                    .foregroundColor(step.enabled ? .primary : .secondary.opacity(0.5))
                                    .strikethrough(!step.enabled)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            // Footer with approve/deny buttons
            HStack(spacing: 12) {
                if confirmationId != nil {
                    Text("Toggle steps to skip.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Deny") { onDeny() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Approve") { onApprove() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Image(systemName: "hourglass")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Waiting for confirmation...")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

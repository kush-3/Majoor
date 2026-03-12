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
            } else if let planText = taskManager.pendingPipelinePlan,
                      let taskId = taskManager.pendingPipelineTaskId {
                // Pipeline plan view
                if taskManager.pipelineExecuting,
                   let pipelineTask = taskManager.tasks.first(where: { $0.id == taskId }) {
                    // Pipeline is executing — show progress
                    PipelineProgressView(task: pipelineTask, planText: planText)
                } else {
                    // Pipeline waiting for approval
                    PipelinePlanView(planText: planText, onApprove: {
                        // Resolve confirmation as approved
                        // The notification action handler does this — but panel buttons
                        // need to resolve it too. We find the pending confirmation.
                        Task {
                            // The confirmation is handled by the notification system.
                            // Panel buttons are a visual complement — the actual
                            // approval/denial happens via notification actions.
                        }
                    }, onDeny: {
                        Task {
                            // Same as above — notification handles the actual confirmation
                        }
                    })
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

// MARK: - Pipeline Plan View

struct PipelinePlanView: View {
    let planText: String
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Plan text
            ScrollView {
                Text(planText)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Text("Approve via notification")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

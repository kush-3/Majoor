// MainPanelView.swift
// Majoor — Dropdown Panel
//
// The main panel that appears when clicking the menu bar icon.
// Shows activity feed, confirmations, pipeline progress, and chat.
// Toast overlay provides in-app feedback for task completions and errors.

import SwiftUI

struct MainPanelView: View {
    @EnvironmentObject var taskManager: TaskManager
    @EnvironmentObject var chatManager: ChatManager
    @State private var selectedTask: AgentTask?

    var body: some View {
        ZStack(alignment: .top) {
            // Main content
            VStack(spacing: 0) {
                if let task = selectedTask {
                    // Response detail view with back button
                    HStack {
                        Button(action: { selectedTask = nil }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left").font(.system(size: 11))
                                Text("Back").font(.system(size: 12))
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, DT.Spacing.xs)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    ResponseDetailView(task: task)
                        .transition(.move(edge: .trailing).combined(with: .opacity))

                } else if let confirmation = taskManager.activeConfirmation {
                    // Interactive confirmation sheet (email, calendar, pipeline, generic)
                    if taskManager.pendingPipelinePlan != nil && taskManager.pipelineExecuting {
                        // Pipeline is executing — show progress
                        let taskId = taskManager.pendingPipelineTaskId
                        let title = taskId.flatMap { id in taskManager.tasks.first(where: { $0.id == id })?.userInput } ?? "Pipeline"
                        PipelineProgressView(title: String(title.prefix(50)))
                            .environmentObject(taskManager)
                            .transition(.opacity)
                    } else {
                        ConfirmationSheet(confirmation: confirmation)
                            .environmentObject(taskManager)
                            .transition(.opacity)
                    }

                } else if taskManager.pipelineExecuting, let taskId = taskManager.pendingPipelineTaskId {
                    // Pipeline executing without pending confirmation
                    let title = taskManager.tasks.first(where: { $0.id == taskId })?.userInput ?? "Pipeline"
                    PipelineProgressView(title: String(title.prefix(50)))
                        .environmentObject(taskManager)
                        .transition(.opacity)

                } else {
                    // Normal panel: header + tabs
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "hammer.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(DT.Color.textTertiary)
                            Text("Majoor")
                                .font(DT.Font.headline)
                        }
                        Spacer()

                        if taskManager.isTaskRunning {
                            HStack(spacing: DT.Spacing.xs) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Working")
                                    .font(DT.Font.caption(.medium))
                                    .foregroundStyle(DT.Color.running)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }

                        HStack(spacing: DT.Spacing.xxs) {
                            tabButton("Tasks", tag: 0)
                            tabButton("Chat", tag: 1)
                        }
                        .padding(DT.Spacing.xxs)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .animation(DT.Anim.fast, value: taskManager.isTaskRunning)

                    Divider()

                    if taskManager.selectedTab == 0 {
                        ActivityFeedView(onViewResponse: { task in
                            selectedTask = task
                        }).environmentObject(taskManager)
                    } else {
                        ChatView()
                            .environmentObject(chatManager)
                    }

                    Group {
                        Button("") { taskManager.selectedTab = 0 }
                            .keyboardShortcut("1", modifiers: .command)
                            .frame(width: 0, height: 0).hidden()
                        Button("") { taskManager.selectedTab = 1 }
                            .keyboardShortcut("2", modifiers: .command)
                            .frame(width: 0, height: 0).hidden()
                    }
                }
            }
            .animation(DT.Anim.normal, value: selectedTask?.id)

            // Toast overlay — floats above content
            ToastOverlayView()
                .environmentObject(taskManager)
        }
        .frame(width: DT.Layout.panelWidth, height: DT.Layout.panelHeight)
        .background(.regularMaterial)
        .onReceive(NotificationCenter.default.publisher(for: .majoorOpenTaskDetail)) { notification in
            if let taskId = notification.userInfo?["taskId"] as? String,
               let task = taskManager.tasks.first(where: { $0.id.uuidString == taskId }) {
                selectedTask = task
            }
        }
    }

    private func tabButton(_ label: String, tag: Int) -> some View {
        Button {
            withAnimation(DT.Anim.fast) { taskManager.selectedTab = tag }
        } label: {
            Text(label)
                .font(DT.Font.caption(.medium))
                .padding(.horizontal, DT.Spacing.sm)
                .padding(.vertical, DT.Spacing.xs)
                .background(
                    taskManager.selectedTab == tag
                        ? AnyShapeStyle(DT.Color.surfaceCard)
                        : AnyShapeStyle(.clear),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

// MainPanelView.swift
// Majoor — Dropdown Panel
//
// The main panel that appears when clicking the menu bar icon.
// Design reference: macOS Notification Center + Spotlight results.
// Material background with vibrancy, no hard borders, generous spacing.

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
                    // Response detail view with back navigation
                    detailHeader(task: task)
                    ResponseDetailView(task: task)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))

                } else if let confirmation = taskManager.activeConfirmation {
                    if taskManager.pendingPipelinePlan != nil && taskManager.pipelineExecuting {
                        let taskId = taskManager.pendingPipelineTaskId
                        let title = taskId.flatMap { id in taskManager.tasks.first(where: { $0.id == id })?.userInput } ?? "Pipeline"
                        PipelineProgressView(title: String(title.prefix(50)))
                            .environmentObject(taskManager)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else {
                        ConfirmationSheet(confirmation: confirmation)
                            .environmentObject(taskManager)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }

                } else if taskManager.pipelineExecuting, let taskId = taskManager.pendingPipelineTaskId {
                    let title = taskManager.tasks.first(where: { $0.id == taskId })?.userInput ?? "Pipeline"
                    PipelineProgressView(title: String(title.prefix(50)))
                        .environmentObject(taskManager)
                        .transition(.opacity)

                } else {
                    // Normal panel: toolbar + content
                    panelToolbar
                    tabContent
                    hiddenKeyboardShortcuts
                }
            }
            .animation(DT.Anim.normal, value: selectedTask?.id)

            // Toast overlay — floats above everything
            ToastOverlayView()
                .environmentObject(taskManager)
        }
        .frame(width: DT.Layout.panelWidth, height: DT.Layout.panelHeight)
        .background(.ultraThinMaterial)
        .onReceive(NotificationCenter.default.publisher(for: .majoorOpenTaskDetail)) { notification in
            if let taskId = notification.userInfo?["taskId"] as? String,
               let task = taskManager.tasks.first(where: { $0.id.uuidString == taskId }) {
                withAnimation(DT.Anim.normal) { selectedTask = task }
            }
        }
    }

    // MARK: - Toolbar

    /// Apple-style minimal toolbar: app identity left, segmented control right.
    /// No divider — the material background provides separation.
    private var panelToolbar: some View {
        HStack(spacing: DT.Spacing.sm) {
            // Working indicator (replaces title when active)
            if taskManager.isTaskRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("Working...")
                        .font(DT.Font.caption(.medium))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            Spacer()

            // Segmented tab control — Apple-style pill picker
            HStack(spacing: 2) {
                tabPill("Activity", systemImage: "list.bullet", tag: 0)
                tabPill("Chat", systemImage: "bubble.left.and.bubble.right", tag: 1)
            }
            .padding(3)
            .background(
                Capsule(style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
        }
        .padding(.horizontal, DT.Spacing.lg)
        .padding(.top, DT.Spacing.md)
        .padding(.bottom, DT.Spacing.sm)
        .animation(DT.Anim.fast, value: taskManager.isTaskRunning)
    }

    private func tabPill(_ label: String, systemImage: String, tag: Int) -> some View {
        let isSelected = taskManager.selectedTab == tag
        return Button {
            withAnimation(DT.Anim.fast) { taskManager.selectedTab = tag }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(DT.Font.caption(.medium))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        if taskManager.selectedTab == 0 {
            ActivityFeedView(onViewResponse: { task in
                withAnimation(DT.Anim.normal) { selectedTask = task }
            })
            .environmentObject(taskManager)
            .transition(.opacity)
        } else {
            ChatView()
                .environmentObject(chatManager)
                .transition(.opacity)
        }
    }

    // MARK: - Detail Header

    private func detailHeader(task: AgentTask) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(DT.Anim.normal) { selectedTask = nil }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(DT.Font.body(.medium))
                }
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(task.status.rawValue)
                .font(DT.Font.micro(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DT.Spacing.lg)
        .padding(.vertical, DT.Spacing.md)
    }

    // MARK: - Hidden Shortcuts

    @ViewBuilder
    private var hiddenKeyboardShortcuts: some View {
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

// TaskManager.swift
// Majoor — Task Manager
//
// Manages the list of all tasks (running, completed, failed),
// in-app toasts, and confirmation state.
// Stays on @MainActor (default) since it drives SwiftUI views.
// Loads persisted tasks on init, saves on changes.

import Foundation
import Combine

// MARK: - Toast Model

enum ToastType: Sendable {
    case info       // Task complete, general status
    case error      // Task failed, API errors
    case warning    // Non-critical warnings
}

struct Toast: Identifiable {
    let id = UUID()
    let type: ToastType
    let title: String
    let body: String
    let autoDismissDelay: TimeInterval?  // nil = persist until dismissed
    var action: (() -> Void)?            // Optional action button callback
    var actionLabel: String?             // Optional action button text
}

// MARK: - Task Notification Model

enum TaskNotificationType {
    case success
    case error
}

struct TaskNotification: Identifiable {
    let id = UUID()
    let type: TaskNotificationType
    let title: String
    let body: String
    let task: AgentTask?  // Associated task for "View Details"
}

// MARK: - Task Manager

class TaskManager: ObservableObject {

    @Published var tasks: [AgentTask] = []
    @Published var pendingPipelinePlan: String?
    @Published var pendingPipelineTaskId: UUID?
    @Published var pipelineExecuting: Bool = false
    @Published var pipelineSteps: [PipelineStep] = []
    @Published var pipelineStartTime: Date?
    @Published var selectedTab: Int = 0

    // In-app toast system
    @Published var toasts: [Toast] = []

    // In-app confirmation UI state
    @Published var activeConfirmation: ConfirmationContext?

    // In-app task completion/error notification
    @Published var activeNotification: TaskNotification?

    var runningTasks: [AgentTask] {
        tasks.filter { $0.status == .running }
    }

    var completedTasks: [AgentTask] {
        tasks.filter { $0.status == .completed }
    }

    // MARK: - Task Notification Methods

    func showNotification(type: TaskNotificationType, title: String, body: String, task: AgentTask? = nil) {
        activeNotification = TaskNotification(type: type, title: title, body: body, task: task)
    }

    func dismissNotification() {
        activeNotification = nil
    }

    // MARK: - Toast Methods

    func showToast(type: ToastType = .info, title: String, body: String,
                   autoDismiss: TimeInterval? = 4.0, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        let toast = Toast(type: type, title: title, body: body,
                         autoDismissDelay: autoDismiss, action: action, actionLabel: actionLabel)
        toasts.append(toast)

        // Cap at 3 visible toasts
        if toasts.count > 3 {
            toasts.removeFirst(toasts.count - 3)
        }

        // Schedule auto-dismiss
        if let delay = toast.autoDismissDelay {
            let toastId = toast.id
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.dismissToast(id: toastId)
            }
        }
    }

    func dismissToast(id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    // MARK: - Confirmation Methods

    func showConfirmation(id: String, title: String, body: String, category: String = "") {
        activeConfirmation = ConfirmationContext(id: id, title: title, body: body, category: category)
    }

    func clearConfirmation() {
        activeConfirmation = nil
    }

    // MARK: - Pipeline Methods

    func showPipelinePlan(_ plan: String, taskId: UUID) {
        pendingPipelinePlan = plan
        pendingPipelineTaskId = taskId
    }

    func clearPipelinePlan() {
        pendingPipelinePlan = nil
        pendingPipelineTaskId = nil
        pipelineExecuting = false
        pipelineSteps = []
        pipelineStartTime = nil
    }

    func setPipelineSteps(_ steps: [PipelineStep]) {
        pipelineSteps = steps
        pipelineStartTime = Date()
    }

    func updatePipelineStep(at index: Int, status: PipelineStepStatus, result: String? = nil, error: String? = nil) {
        guard index < pipelineSteps.count else { return }
        pipelineSteps[index].status = status
        if let result { pipelineSteps[index].result = result }
        if let error { pipelineSteps[index].error = error }
    }

    func addToolCallToPipelineStep(at index: Int, toolName: String) {
        guard index < pipelineSteps.count else { return }
        pipelineSteps[index].toolCalls.append(toolName)
    }

    func togglePipelineStep(at index: Int) {
        guard index < pipelineSteps.count else { return }
        pipelineSteps[index].enabled.toggle()
    }

    // MARK: - Task Methods

    init() {
        // Load persisted tasks from SQLite
        let persisted = TaskPersistence.shared.loadRecentTasks(limit: 50)
        tasks = persisted

        // Clean up old tasks (older than 30 days)
        TaskPersistence.shared.deleteOldTasks(olderThan: 30)
    }

    func addTask(_ task: AgentTask) {
        tasks.insert(task, at: 0)
        if tasks.count > 100 {
            tasks = Array(tasks.prefix(100))
        }
    }

    func persistTask(_ task: AgentTask) {
        TaskPersistence.shared.saveTask(task)
    }

    func clearCompleted() {
        tasks.removeAll { $0.status == .completed || $0.status == .failed }
    }
}

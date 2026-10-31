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

// MARK: - Task Manager

class TaskManager: ObservableObject {

    @Published var tasks: [AgentTask] = []
    @Published var pendingPipelinePlan: String?
    @Published var pendingPipelineTaskId: UUID?
    @Published var pipelineExecuting: Bool = false
    @Published var pipelineSteps: [PipelineStep] = []
    @Published var pipelineStartTime: Date?
    @Published var selectedTab: Int = 0

    // Running task state (for command bar UI)
    @Published var isTaskRunning: Bool = false
    @Published var runningTaskInput: String = ""

    // In-app toast system
    @Published var toasts: [Toast] = []

    // In-app confirmation UI state
    @Published var activeConfirmation: ConfirmationContext?
    @Published var pendingApprovals: [ApprovalRequest] = []
    @Published var runningCount: Int = 0

    var runningTasks: [AgentTask] {
        tasks.filter { $0.status == .running || $0.status == .waiting }
    }

    // MARK: - Session event mirror

    /// Every change the runtime makes lands here as an event; the published
    /// properties the views already read are derived from it.
    func apply(_ event: SessionEvent) {
        switch event {
        case .created(let info):
            if !tasks.contains(where: { $0.id == info.id }) {
                addTask(AgentTask(id: info.id, userInput: info.input, createdAt: info.createdAt, status: .running,
                                  summary: "", completedAt: nil, tokensUsed: 0, modelUsed: "", steps: []))
            }
            refreshRunning()
        case .state(let id, let state):
            if let task = task(id) {
                switch state {
                case .waitingApproval: task.status = .waiting
                case .running, .queued: if task.status == .waiting || task.status == .running { task.status = .running }
                case .completed, .failed, .stopped: break   // .finished carries the summary
                }
            }
            refreshRunning()
        case .step(let id, let step):
            task(id)?.steps.append(step.taskStep)
        case .cost(let id, let tokensIn, let tokensOut, _, _):
            task(id)?.tokensUsed = tokensIn + tokensOut
        case .finished(let id, let state, let summary):
            if let task = task(id) {
                task.status = state == .completed ? .completed : .failed
                task.summary = summary
                task.completedAt = Date()
            }
            if pendingPipelineTaskId == id { clearPipelinePlan() }
            pendingApprovals.removeAll { $0.sessionId == id }
            syncActiveConfirmation()
            refreshRunning()
        case .pipelinePlan(let id, let text, let steps):
            if text.isEmpty && steps.isEmpty {
                if pendingPipelineTaskId == id { clearPipelinePlan() }
            } else {
                showPipelinePlan(text, taskId: id)
                setPipelineSteps(steps.map { PipelineStep(planDescription: $0.planDescription, enabled: $0.enabled) })
            }
        case .pipelineStep(let id, let index, let status, let result, let error):
            guard pendingPipelineTaskId == id, let stepStatus = PipelineStepStatus(rawValue: status) else { return }
            updatePipelineStep(at: index, status: stepStatus, result: result, error: error)
            if stepStatus == .running { pipelineExecuting = true }
        case .approvalRequested(let request):
            pendingApprovals.append(request)
            syncActiveConfirmation()
        case .approvalResolved(let approvalId, let approved, _):
            if let request = pendingApprovals.first(where: { $0.id == approvalId }), request.isPipelinePlan {
                pipelineExecuting = approved
            }
            pendingApprovals.removeAll { $0.id == approvalId }
            syncActiveConfirmation()
        }
    }

    private func task(_ id: UUID) -> AgentTask? {
        tasks.first { $0.id == id }
    }

    private func syncActiveConfirmation() {
        activeConfirmation = pendingApprovals.first.map {
            ConfirmationContext(id: $0.id, title: $0.title, body: $0.body, category: $0.category, nonce: $0.nonce,
                                sessionId: $0.sessionId, isPipelinePlan: $0.isPipelinePlan, pendingCount: pendingApprovals.count)
        }
    }

    private func refreshRunning() {
        let running = runningTasks
        runningCount = running.count
        isTaskRunning = !running.isEmpty
        runningTaskInput = running.first?.userInput ?? ""
    }

    /// Indices of pipeline steps the user switched off in the panel, sent
    /// with a plan approval so the runtime skips them.
    var disabledPipelineStepIndices: [Int] {
        pipelineSteps.enumerated().filter { !$0.element.enabled }.map(\.offset)
    }

    var completedTasks: [AgentTask] {
        tasks.filter { $0.status == .completed }
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

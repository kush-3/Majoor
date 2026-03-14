// TaskManager.swift
// Majoor — Task Manager
//
// Manages the list of all tasks (running, completed, failed).
// Stays on @MainActor (default) since it drives SwiftUI views.
// Loads persisted tasks on init, saves on changes.

import Foundation
import Combine

class TaskManager: ObservableObject {

    @Published var tasks: [AgentTask] = []
    @Published var pendingPipelinePlan: String?
    @Published var pendingPipelineTaskId: UUID?
    @Published var pipelineExecuting: Bool = false
    @Published var pipelineSteps: [PipelineStep] = []
    @Published var pipelineStartTime: Date?

    // In-app confirmation UI state
    @Published var pendingConfirmationId: String?
    @Published var pendingConfirmationTitle: String?
    @Published var pendingConfirmationBody: String?

    var runningTasks: [AgentTask] {
        tasks.filter { $0.status == .running }
    }

    var completedTasks: [AgentTask] {
        tasks.filter { $0.status == .completed }
    }

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

    func showConfirmation(id: String, title: String, body: String) {
        pendingConfirmationId = id
        pendingConfirmationTitle = title
        pendingConfirmationBody = body
    }

    func clearConfirmation() {
        pendingConfirmationId = nil
        pendingConfirmationTitle = nil
        pendingConfirmationBody = nil
    }

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

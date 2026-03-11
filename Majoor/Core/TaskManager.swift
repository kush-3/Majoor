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

    var runningTasks: [AgentTask] {
        tasks.filter { $0.status == .running }
    }

    var completedTasks: [AgentTask] {
        tasks.filter { $0.status == .completed }
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

// TaskManager.swift
// Majoor — Task Manager
//
// Manages the list of all tasks (running, completed, failed).
// Stays on @MainActor (default) since it drives SwiftUI views.

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
    
    func addTask(_ task: AgentTask) {
        tasks.insert(task, at: 0)
        if tasks.count > 100 {
            tasks = Array(tasks.prefix(100))
        }
    }
    
    func clearCompleted() {
        tasks.removeAll { $0.status == .completed || $0.status == .failed }
    }
}

// TaskPersistence.swift
// Majoor — Persist Tasks to SQLite

import Foundation
import GRDB

// MARK: - Persistable Task Record

nonisolated struct TaskRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tasks"

    let id: String
    let userInput: String
    var status: String
    var modelUsed: String?
    var stepsJson: String?
    var summary: String?
    var tokensUsed: Int
    var costEstimate: Double
    let createdAt: Date
    var completedAt: Date?
}

// MARK: - Step Serialization

nonisolated struct PersistableStep: Codable, Sendable {
    let timestamp: Date
    let type: String  // "thinking", "toolCall", "toolResult", "response", "error"
    let description: String
    let detail: String?
}

// MARK: - Task Persistence

nonisolated final class TaskPersistence: @unchecked Sendable {

    static let shared = TaskPersistence()
    private let db = DatabaseManager.shared.dbQueue

    private init() {}

    func saveTask(_ task: AgentTask) {
        let steps = task.steps.map { step in
            PersistableStep(
                timestamp: step.timestamp,
                type: stepTypeToString(step.type),
                description: step.description,
                detail: step.detail
            )
        }
        let stepsJson = (try? JSONEncoder().encode(steps)).flatMap { String(data: $0, encoding: .utf8) }

        let record = TaskRecord(
            id: task.id.uuidString,
            userInput: task.userInput,
            status: task.status.rawValue,
            modelUsed: task.modelUsed,
            stepsJson: stepsJson,
            summary: task.summary,
            tokensUsed: task.tokensUsed,
            costEstimate: CostConfig.estimateCost(model: task.modelUsed, tokens: task.tokensUsed),
            createdAt: task.createdAt,
            completedAt: task.completedAt
        )

        do {
            try db.write { db in try record.save(db) }
        } catch {
            MajoorLogger.error("Failed to save task: \(error)")
        }
    }

    func loadRecentTasks(limit: Int = 50) -> [AgentTask] {
        do {
            let records = try db.read { db in
                try TaskRecord.order(Column("createdAt").desc).limit(limit).fetchAll(db)
            }
            return records.compactMap { recordToTask($0) }
        } catch {
            MajoorLogger.error("Failed to load tasks: \(error)")
            return []
        }
    }

    func deleteOldTasks(olderThan days: Int = 30) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM tasks WHERE createdAt < ?", arguments: [cutoff])
            }
        } catch {
            MajoorLogger.error("Failed to delete old tasks: \(error)")
        }
    }

    // MARK: - Conversion

    private func recordToTask(_ record: TaskRecord) -> AgentTask? {
        guard let id = UUID(uuidString: record.id) else { return nil }

        var steps: [TaskStep] = []
        if let json = record.stepsJson, let data = json.data(using: .utf8),
           let persistedSteps = try? JSONDecoder().decode([PersistableStep].self, from: data) {
            steps = persistedSteps.map { ps in
                TaskStep(
                    timestamp: ps.timestamp,
                    type: stringToStepType(ps.type),
                    description: ps.description,
                    detail: ps.detail
                )
            }
        }

        return AgentTask(
            id: id,
            userInput: record.userInput,
            createdAt: record.createdAt,
            status: TaskStatus(rawValue: record.status) ?? .completed,
            summary: record.summary ?? "",
            completedAt: record.completedAt,
            tokensUsed: record.tokensUsed,
            modelUsed: record.modelUsed ?? "",
            steps: steps
        )
    }

    private func stepTypeToString(_ type: TaskStep.StepType) -> String {
        switch type {
        case .thinking: return "thinking"
        case .toolCall: return "toolCall"
        case .toolResult: return "toolResult"
        case .response: return "response"
        case .error: return "error"
        }
    }

    private func stringToStepType(_ str: String) -> TaskStep.StepType {
        switch str {
        case "thinking": return .thinking
        case "toolCall": return .toolCall
        case "toolResult": return .toolResult
        case "response": return .response
        case "error": return .error
        default: return .response
        }
    }
}

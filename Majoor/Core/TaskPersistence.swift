// TaskPersistence.swift
// Majoor — Persist Tasks to SQLite
//
// The persisted shape is TaskSnapshot, a plain value the runtime's
// TaskRecorder produces off the main actor. AgentTask (the SwiftUI model)
// converts to and from it on the main actor.

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

/// The `stepsJson` element shape. StepDTO has the identical fields and encoding.
typealias PersistableStep = StepDTO

// MARK: - Snapshot

/// Everything persistence needs about a task, as a value.
nonisolated struct TaskSnapshot: Sendable, Equatable {
    let id: UUID
    let userInput: String
    let createdAt: Date
    let status: TaskStatus
    let summary: String
    let completedAt: Date?
    let tokensIn: Int
    let tokensOut: Int
    let modelUsed: String
    let steps: [StepDTO]

    var tokensUsed: Int { tokensIn + tokensOut }

    init(id: UUID, userInput: String, createdAt: Date, status: TaskStatus, summary: String, completedAt: Date?,
         tokensIn: Int, tokensOut: Int, modelUsed: String, steps: [StepDTO]) {
        self.id = id; self.userInput = userInput; self.createdAt = createdAt; self.status = status; self.summary = summary
        self.completedAt = completedAt; self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.modelUsed = modelUsed
        self.steps = steps
    }

    /// From the SwiftUI model. AgentTask only tracks a combined token count,
    /// so the split is even; the runtime path carries real counts.
    @MainActor init(_ task: AgentTask) {
        let input = task.tokensUsed / 2
        self.init(id: task.id, userInput: task.userInput, createdAt: task.createdAt, status: task.status, summary: task.summary,
                  completedAt: task.completedAt, tokensIn: input, tokensOut: task.tokensUsed - input, modelUsed: task.modelUsed,
                  steps: task.steps.map(StepDTO.init))
    }

    @MainActor var agentTask: AgentTask {
        AgentTask(id: id, userInput: userInput, createdAt: createdAt, status: status, summary: summary, completedAt: completedAt,
                  tokensUsed: tokensUsed, modelUsed: modelUsed, steps: steps.map(\.taskStep))
    }
}

// MARK: - Task Persistence

nonisolated final class TaskPersistence: @unchecked Sendable {

    static let shared = TaskPersistence(db: DatabaseManager.shared.dbQueue)
    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    func save(_ snapshot: TaskSnapshot) {
        let stepsJson = (try? JSONEncoder().encode(snapshot.steps)).flatMap { String(data: $0, encoding: .utf8) }
        let record = TaskRecord(
            id: snapshot.id.uuidString,
            userInput: snapshot.userInput,
            status: snapshot.status.rawValue,
            modelUsed: snapshot.modelUsed,
            stepsJson: stepsJson,
            summary: snapshot.summary,
            tokensUsed: snapshot.tokensUsed,
            costEstimate: CostConfig.estimateCost(model: snapshot.modelUsed, inputTokens: snapshot.tokensIn, outputTokens: snapshot.tokensOut),
            createdAt: snapshot.createdAt,
            completedAt: snapshot.completedAt
        )
        do {
            try db.write { db in try record.save(db) }
        } catch {
            MajoorLogger.error("Failed to save task: \(error)")
        }
    }

    @MainActor func saveTask(_ task: AgentTask) {
        save(TaskSnapshot(task))
    }

    func loadRecentSnapshots(limit: Int = 50) -> [TaskSnapshot] {
        do {
            let records = try db.read { db in
                try TaskRecord.order(Column("createdAt").desc).limit(limit).fetchAll(db)
            }
            return records.compactMap(Self.snapshot(from:))
        } catch {
            MajoorLogger.error("Failed to load tasks: \(error)")
            return []
        }
    }

    @MainActor func loadRecentTasks(limit: Int = 50) -> [AgentTask] {
        loadRecentSnapshots(limit: limit).map(\.agentTask)
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

    private static func snapshot(from record: TaskRecord) -> TaskSnapshot? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        var steps: [StepDTO] = []
        if let json = record.stepsJson, let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([StepDTO].self, from: data) {
            steps = decoded
        }
        let total = record.tokensUsed
        let input = total / 2
        return TaskSnapshot(
            id: id,
            userInput: record.userInput,
            createdAt: record.createdAt,
            // Fall back to .failed, never .completed: an unrecognized status token
            // must not be resurrected on restart as a green checkmark.
            status: TaskStatus(rawValue: record.status) ?? .failed,
            summary: record.summary ?? "",
            completedAt: record.completedAt,
            tokensIn: input,
            tokensOut: total - input,
            modelUsed: record.modelUsed ?? "",
            steps: steps
        )
    }
}

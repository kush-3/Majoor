// UsageStore.swift
// Majoor — Token Usage & Cost Tracking

import Foundation
import GRDB

// MARK: - Cost Configuration

nonisolated struct CostConfig: Sendable {
    // Per 1M tokens (input / output)
    static let opusInput = 15.0
    static let opusOutput = 75.0
    static let sonnetInput = 3.0
    static let sonnetOutput = 15.0
    static let haikuInput = 0.25
    static let haikuOutput = 1.25

    static func estimateCost(model: String, tokens: Int) -> Double {
        // Rough estimate using average of input/output rates
        let ratePerMillion: Double
        if model.contains("opus") {
            ratePerMillion = (opusInput + opusOutput) / 2
        } else if model.contains("haiku") {
            ratePerMillion = (haikuInput + haikuOutput) / 2
        } else {
            ratePerMillion = (sonnetInput + sonnetOutput) / 2
        }
        return Double(tokens) / 1_000_000 * ratePerMillion
    }

    static func estimateCost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let (inputRate, outputRate): (Double, Double)
        if model.contains("opus") {
            (inputRate, outputRate) = (opusInput, opusOutput)
        } else if model.contains("haiku") {
            (inputRate, outputRate) = (haikuInput, haikuOutput)
        } else {
            (inputRate, outputRate) = (sonnetInput, sonnetOutput)
        }
        return Double(inputTokens) / 1_000_000 * inputRate + Double(outputTokens) / 1_000_000 * outputRate
    }
}

// MARK: - Usage Record

nonisolated struct UsageRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "usageStats"

    var id: Int64?
    let date: String
    let model: String
    var inputTokens: Int
    var outputTokens: Int
    var cost: Double
    var taskCount: Int
}

// MARK: - Usage Store

nonisolated final class UsageStore: @unchecked Sendable {

    static let shared = UsageStore()
    private let db = DatabaseManager.shared.dbQueue

    private init() {}

    /// Thread-safe date formatting (DateFormatter is not thread-safe)
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func recordUsage(model: String, inputTokens: Int, outputTokens: Int) {
        let today = formatDate(Date())
        let cost = CostConfig.estimateCost(model: model, inputTokens: inputTokens, outputTokens: outputTokens)

        do {
            try db.write { db in
                // Atomic upsert via SQL to avoid race conditions
                try db.execute(
                    sql: """
                        INSERT INTO usageStats (date, model, inputTokens, outputTokens, cost, taskCount)
                        VALUES (?, ?, ?, ?, ?, 1)
                        ON CONFLICT(date, model) DO UPDATE SET
                            inputTokens = inputTokens + excluded.inputTokens,
                            outputTokens = outputTokens + excluded.outputTokens,
                            cost = cost + excluded.cost,
                            taskCount = taskCount + 1
                        """,
                    arguments: [today, model, inputTokens, outputTokens, cost]
                )
            }
        } catch {
            MajoorLogger.error("Failed to record usage: \(error)")
        }
    }

    struct UsageSummary: Sendable {
        let totalTokens: Int
        let totalCost: Double
        let taskCount: Int
    }

    func todayUsage() -> UsageSummary {
        usage(since: Calendar.current.startOfDay(for: Date()))
    }

    func weekUsage() -> UsageSummary {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return usage(since: weekAgo)
    }

    func monthUsage() -> UsageSummary {
        let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        return usage(since: monthAgo)
    }

    func usageByModel(days: Int = 30) -> [(model: String, tokens: Int, cost: Double)] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let sinceStr = formatDate(since)

        do {
            let records = try db.read { db in
                try UsageRecord.filter(Column("date") >= sinceStr).fetchAll(db)
            }
            // Group by model
            var grouped: [String: (tokens: Int, cost: Double)] = [:]
            for r in records {
                let existing = grouped[r.model] ?? (tokens: 0, cost: 0)
                grouped[r.model] = (existing.tokens + r.inputTokens + r.outputTokens, existing.cost + r.cost)
            }
            return grouped.map { (model: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
                .sorted { $0.cost > $1.cost }
        } catch {
            return []
        }
    }

    private func usage(since date: Date) -> UsageSummary {
        let sinceStr = formatDate(date)
        do {
            let records = try db.read { db in
                try UsageRecord.filter(Column("date") >= sinceStr).fetchAll(db)
            }
            let tokens = records.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
            let cost = records.reduce(0.0) { $0 + $1.cost }
            let tasks = records.reduce(0) { $0 + $1.taskCount }
            return UsageSummary(totalTokens: tokens, totalCost: cost, taskCount: tasks)
        } catch {
            return UsageSummary(totalTokens: 0, totalCost: 0, taskCount: 0)
        }
    }
}

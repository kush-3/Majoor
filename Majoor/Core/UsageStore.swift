// UsageStore.swift
// Majoor — Token Usage & Cost Tracking

import Foundation
import GRDB

// MARK: - Cost Configuration

nonisolated struct CostConfig: Sendable {
    // Claude, per 1M tokens (input / output) — Opus 5 $5/$25, Sonnet 5 $3/$15, Haiku 4.5 $1/$5.
    // Sonnet 5 has introductory pricing ($2/$10) through 2026-08-31; sticker rates used here.
    static let opusInput = 5.0
    static let opusOutput = 25.0
    static let sonnetInput = 3.0
    static let sonnetOutput = 15.0
    static let haikuInput = 1.0
    static let haikuOutput = 5.0

    /// Claude's rates for a frontier model name.
    static func frontierRates(for model: String) -> (input: Double, output: Double) {
        if model.contains("opus") { return (opusInput, opusOutput) }
        if model.contains("haiku") { return (haikuInput, haikuOutput) }
        return (sonnetInput, sonnetOutput)
    }

    /// Per-tier pricing (plan §3c). Tier L costs nothing; tier P costs what the
    /// owner entered in Settings ▸ Models (0 until set, so an unpriced endpoint
    /// under-reports rather than inventing a number); tier F uses Claude's
    /// table by model name. Callers that know the tier pass it; the rest get
    /// it from the model name through the tier settings.
    static func estimateCost(model: String, inputTokens: Int, outputTokens: Int,
                             tier: ProviderTier? = nil,
                             privateRates: (input: Double, output: Double)? = nil) -> Double {
        let resolved = tier ?? TierSettingsStore.shared.tier(forModel: model)
        let rates: (input: Double, output: Double)
        switch resolved {
        case .local:
            return 0
        case .privateCloud:
            rates = privateRates ?? TierSettingsStore.shared.privateRates
        case .frontier:
            rates = frontierRates(for: model)
        }
        return Double(inputTokens) / 1_000_000 * rates.input + Double(outputTokens) / 1_000_000 * rates.output
    }
}

// MARK: - Usage Record

nonisolated struct UsageRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "usageStats"

    var id: Int64?
    let date: String
    let model: String
    /// `ProviderTier` raw value; "frontier" for every row before migration v8.
    var tier: String
    var inputTokens: Int
    var outputTokens: Int
    var cost: Double
    var taskCount: Int
}

// MARK: - Usage Store

nonisolated final class UsageStore: @unchecked Sendable {

    static let shared = UsageStore(db: DatabaseManager.shared.dbQueue)

    private let db: DatabaseQueue

    /// Tests pass a throwaway queue from `DatabaseManager.openAndMigrate(path:)`.
    init(db: DatabaseQueue) {
        self.db = db
    }

    private static let _dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func formatDate(_ date: Date) -> String {
        Self._dateFormatter.string(from: date)
    }

    /// Adds one call's tokens to today's row for the model. The tier is
    /// recorded alongside; when the caller does not know it, the model name
    /// decides (`TierSettingsStore.tier(forModel:)`).
    func recordUsage(model: String, inputTokens: Int, outputTokens: Int, tier: ProviderTier? = nil) {
        let resolved = tier ?? TierSettingsStore.shared.tier(forModel: model)
        let today = formatDate(Date())
        let cost = CostConfig.estimateCost(model: model, inputTokens: inputTokens, outputTokens: outputTokens, tier: resolved)

        do {
            try db.write { db in
                // Atomic upsert via SQL to avoid race conditions
                try db.execute(
                    sql: """
                        INSERT INTO usageStats (date, model, tier, inputTokens, outputTokens, cost, taskCount)
                        VALUES (?, ?, ?, ?, ?, ?, 1)
                        ON CONFLICT(date, model) DO UPDATE SET
                            tier = excluded.tier,
                            inputTokens = inputTokens + excluded.inputTokens,
                            outputTokens = outputTokens + excluded.outputTokens,
                            cost = cost + excluded.cost,
                            taskCount = taskCount + 1
                        """,
                    arguments: [today, model, resolved.rawValue, inputTokens, outputTokens, cost]
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

    /// One row of the per-model breakdown.
    struct UsageByModel: Sendable, Identifiable {
        let model: String
        let tier: ProviderTier
        let tokens: Int
        let cost: Double
        var id: String { "\(tier.rawValue)|\(model)" }
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

    func usageByModel(days: Int = 30) -> [UsageByModel] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let sinceStr = formatDate(since)

        do {
            let records = try db.read { db in
                try UsageRecord.filter(Column("date") >= sinceStr).fetchAll(db)
            }
            // Group by model and tier
            var grouped: [String: UsageByModel] = [:]
            for r in records {
                let tier = ProviderTier(rawValue: r.tier) ?? .frontier
                let key = "\(tier.rawValue)|\(r.model)"
                let existing = grouped[key]
                grouped[key] = UsageByModel(model: r.model, tier: tier,
                                            tokens: (existing?.tokens ?? 0) + r.inputTokens + r.outputTokens,
                                            cost: (existing?.cost ?? 0) + r.cost)
            }
            return grouped.values.sorted { $0.cost > $1.cost || ($0.cost == $1.cost && $0.tokens > $1.tokens) }
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

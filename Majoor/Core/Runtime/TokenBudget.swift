// TokenBudget.swift
// Majoor — Per-session token ceiling and daily spend cap
//
// The loop re-sends the whole conversation every iteration (no prompt
// caching yet), so tokens grow quickly on long sessions. A session that
// crosses its budget ends with IncompleteReason.budgetExceeded; a day that
// crosses the dollar cap refuses new iterations. Defaults are the PRD's
// placeholders (open question): 2M tokens per session, $25 per day.

import Foundation

nonisolated struct TokenBudget: Sendable, Equatable {

    static let sessionTokensKey = "sessionTokenBudget"
    static let dailyCapUSDKey = "dailyCostCapUSD"
    static let defaultSessionTokens = 2_000_000
    static let defaultDailyCapUSD = 25.0

    var maxTotalTokens: Int

    init(maxTotalTokens: Int = TokenBudget.defaultSessionTokens) {
        self.maxTotalTokens = maxTotalTokens
    }

    /// The configured per-session budget. A value of 0 or less means unlimited.
    static var perSession: TokenBudget {
        let stored = UserDefaults.standard.integer(forKey: sessionTokensKey)
        return TokenBudget(maxTotalTokens: stored == 0 ? defaultSessionTokens : stored)
    }

    static var dailyCapUSD: Double {
        let stored = UserDefaults.standard.double(forKey: dailyCapUSDKey)
        return stored == 0 ? defaultDailyCapUSD : stored
    }

    func isExceeded(by totalTokens: Int) -> Bool {
        maxTotalTokens > 0 && totalTokens > maxTotalTokens
    }

    /// True when today's recorded spend has reached the cap. A cap at or
    /// below zero disables the check.
    static func dailyCapExceeded(todayUSD: Double, cap: Double = dailyCapUSD) -> Bool {
        cap > 0 && todayUSD >= cap
    }

    static func dailyCapExceeded() -> Bool {
        dailyCapExceeded(todayUSD: UsageStore.shared.todayUsage().totalCost)
    }
}

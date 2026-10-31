// ThreadHistoryTests.swift
// MajoorTests — Phase 1 step 2b: thread-keyed history and token budget.

import Foundation
import Testing
@testable import Majoor

/// A settable clock for time-based tests.
nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@Suite("ThreadHistory")
struct ThreadHistoryTests {

    @Test("sessions in the same thread share history; other threads do not see it")
    func threadIsolation() {
        let history = ThreadHistory()
        history.append(thread: "panel", ConversationEntry(userInput: "a", responseText: "ra"))
        history.append(thread: "panel", ConversationEntry(userInput: "b", responseText: "rb", toolSets: ["github"]))
        #expect(history.snapshot(thread: "panel").map(\.userInput) == ["a", "b"])
        #expect(history.snapshot(thread: "imessage:+1555").isEmpty)
        #expect(history.snapshot(thread: "panel").last?.toolSets == ["github"])
    }

    @Test("entries expire after ten minutes and only the newest five are kept")
    func expiryAndCap() {
        let clock = TestClock()
        let history = ThreadHistory(now: { clock.now })
        for i in 1...7 {
            history.append(thread: "t", ConversationEntry(userInput: "\(i)", responseText: "r", timestamp: clock.now))
        }
        #expect(history.snapshot(thread: "t").map(\.userInput) == ["3", "4", "5", "6", "7"])

        clock.advance(ThreadHistory.timeout - 1)
        #expect(history.snapshot(thread: "t").count == 5)
        clock.advance(2)
        #expect(history.snapshot(thread: "t").isEmpty)

        history.append(thread: "t", ConversationEntry(userInput: "fresh", responseText: "r", timestamp: clock.now))
        #expect(history.snapshot(thread: "t").map(\.userInput) == ["fresh"])
        history.prune()
        #expect(history.snapshot(thread: "t").count == 1)
    }

    @Test("response text is capped so injected context stays bounded")
    func responseCap() {
        let history = ThreadHistory()
        history.append(thread: "t", ConversationEntry(userInput: "q", responseText: String(repeating: "x", count: 5_000)))
        #expect(history.snapshot(thread: "t").first?.responseText.count == ThreadHistory.responseCap)
    }

    @Test("clearing a thread leaves the others alone")
    func clear() {
        let history = ThreadHistory()
        history.append(thread: "a", ConversationEntry(userInput: "1", responseText: "r"))
        history.append(thread: "b", ConversationEntry(userInput: "2", responseText: "r"))
        history.clear(thread: "a")
        #expect(history.snapshot(thread: "a").isEmpty)
        #expect(history.snapshot(thread: "b").count == 1)
    }
}

@Suite("TokenBudget")
struct TokenBudgetTests {

    @Test("a session budget is exceeded only above the ceiling; zero means unlimited")
    func sessionBudget() {
        let budget = TokenBudget(maxTotalTokens: 1_000)
        #expect(!budget.isExceeded(by: 1_000))
        #expect(budget.isExceeded(by: 1_001))
        #expect(!TokenBudget(maxTotalTokens: 0).isExceeded(by: 50_000_000))
    }

    @Test("the daily cap compares recorded spend; a non-positive cap disables it")
    func dailyCap() {
        #expect(TokenBudget.dailyCapExceeded(todayUSD: 25, cap: 25))
        #expect(!TokenBudget.dailyCapExceeded(todayUSD: 24.99, cap: 25))
        #expect(!TokenBudget.dailyCapExceeded(todayUSD: 1_000, cap: 0))
    }

    @Test("defaults are the PRD placeholders")
    func defaults() {
        #expect(TokenBudget.defaultSessionTokens == 2_000_000)
        #expect(TokenBudget.defaultDailyCapUSD == 25)
    }
}

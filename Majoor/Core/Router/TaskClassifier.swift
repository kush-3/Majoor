// TaskClassifier.swift
// Majoor — Classify User Input to Route to the Right Model
//
// Tier 1: Keyword pattern matching (instant, free)
// Tier 2: Haiku classifier (fallback for ambiguous inputs)

import Foundation

nonisolated enum TaskCategory: String, Sendable {
    case coding          // → Opus
    case codeReview      // → Opus
    case webResearchDeep // → Opus
    case webResearchQuick // → Sonnet
    case fileManagement  // → Sonnet
    case emailCalendar   // → Sonnet
    case summarization   // → Sonnet
    case general         // → Sonnet (default)

    var modelTier: ModelTier {
        switch self {
        case .coding, .codeReview, .webResearchDeep:
            return .opus
        case .webResearchQuick, .fileManagement, .emailCalendar, .summarization, .general:
            return .sonnet
        }
    }
}

nonisolated enum ModelTier: String, Sendable {
    case opus
    case sonnet
    case haiku
}

nonisolated struct TaskClassifier: Sendable {

    // Keyword groups with associated categories
    private static let patterns: [(keywords: [String], category: TaskCategory)] = [
        // Coding — route to Opus
        (["implement", "refactor", "debug", "fix bug", "write code", "add feature",
          "write script", "write function", "create class", "build a", "compile",
          "fix the", "patch", "rewrite", "optimize code", "add test", "write test"], .coding),

        // Code review — route to Opus
        (["review code", "review pr", "code review", "what changed", "explain this code",
          "read the code", "analyze code", "find bugs"], .codeReview),

        // Git operations that involve code changes — route to Opus
        (["open a pr", "create pr", "commit and push", "fix and commit",
          "branch and implement"], .coding),

        // Deep web research — route to Opus
        (["research", "compare", "analyze", "in-depth", "comprehensive",
          "deep dive", "investigate", "technical comparison"], .webResearchDeep),

        // Quick web search — route to Sonnet
        (["search for", "look up", "find out", "what is", "who is", "google",
          "search the web", "latest news"], .webResearchQuick),

        // Email & Calendar — route to Sonnet
        (["email", "gmail", "inbox", "unread", "send email", "draft email",
          "reply to", "email me", "calendar", "schedule meeting", "meeting",
          "appointment", "event", "what's on my", "schedule a"], .emailCalendar),

        // File management — route to Sonnet
        (["file", "folder", "directory", "organize", "move file", "delete file",
          "rename", "download", "clean up", "sort files"], .fileManagement),

        // Summarization — route to Sonnet
        (["summarize", "summary", "brief", "tldr", "recap", "overview",
          "short version", "key points"], .summarization),
    ]

    /// Classify user input into a task category using keyword matching
    static func classify(_ input: String) -> TaskCategory {
        let lower = input.lowercased()

        var bestMatch: TaskCategory = .general
        var bestScore = 0

        for (keywords, category) in patterns {
            var score = 0
            for keyword in keywords {
                if lower.contains(keyword) {
                    score += 1
                }
            }
            if score > bestScore {
                bestScore = score
                bestMatch = category
            }
        }

        // Simple heuristic: if the input mentions git commands specifically
        if lower.contains("git ") || lower.contains("commit") || lower.contains("push") || lower.contains("pr ") {
            // If it also mentions code changes, use Opus
            if lower.contains("fix") || lower.contains("implement") || lower.contains("add") || lower.contains("write") {
                return .coding
            }
        }

        MajoorLogger.log("Task classified as: \(bestMatch.rawValue) (score: \(bestScore))")
        return bestMatch
    }
}

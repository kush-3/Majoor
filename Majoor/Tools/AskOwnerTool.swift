// AskOwnerTool.swift
// Majoor — "I'm blocked": one question to the owner, on the channel the task came from
//
// PRD §8 / Phase 2 step 6h. The model calls `ask_owner` when it cannot
// proceed without a decision only the owner can make. The tool itself does
// nothing: `AgentLoop` answers it by awaiting `host.ask(...)`, which the
// session routes to its origin channel (iMessage texts the question with a
// code; the panel cannot ask yet and reports no answer). R0, tier-agnostic:
// the loop never withholds it under a privacy preset, because the owner
// decides what to say.

import Foundation

nonisolated struct AskOwnerTool: AgentTool {
    static let toolName = "ask_owner"
    static let defaultTimeoutMinutes = 10
    static let maxTimeoutMinutes = 120

    let name = AskOwnerTool.toolName
    let description = "Ask the user one question when you are genuinely blocked and cannot decide yourself. The question is sent to wherever the task came from (iMessage or the panel) and this call waits for the reply. Do not use it to ask permission: sensitive tools prompt the user on their own. Ask once per blocker, with concrete options when there are a few sensible choices."
    let parameters = [
        ToolParameter(name: "question", description: "One short, specific question. Say what you will do if there is no answer."),
        ToolParameter(name: "options", description: "Optional comma-separated choices, e.g. \"Keep the draft, Delete it\". The user can reply with a number."),
        ToolParameter(name: "timeout_minutes", type: "integer", description: "How long to wait for a reply (default 10, max 120)."),
    ]
    let requiredParameters = ["question"]
    let requiresConfirmation = false
    let isReadOnly = true
    let dataClass: DataClass = .majoorState

    /// Never reached: the loop intercepts `ask_owner` and asks the host.
    func execute(arguments: [String: String]) async throws -> ToolResult {
        ToolResult(success: false, output: "Error: ask_owner can only be answered by the running session")
    }

    // MARK: - Argument parsing (shared with the loop and the tests)

    static func question(from arguments: [String: String]) -> String? {
        let text = (arguments["question"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// "Red, Blue" → ["Red", "Blue"]; newlines and semicolons split too.
    static func options(from raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func timeoutMinutes(from raw: String?) -> Int {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespaces)) else { return defaultTimeoutMinutes }
        return min(max(value, 1), maxTimeoutMinutes)
    }

    /// The tool result the model reads, and the feed step's title.
    static func describe(_ answer: Answer, timeoutMinutes: Int) -> (output: String, stepTitle: String) {
        if answer.timedOut {
            return ("No answer within \(timeoutMinutes) minutes. Continue with your best judgment, or stop and report what is blocked.",
                    "No answer within \(timeoutMinutes) minutes")
        }
        if let option = answer.option {
            if let text = answer.text, text.caseInsensitiveCompare(option) != .orderedSame {
                return ("The user chose \"\(option)\" and said: \(text)", "Your answer")
            }
            return ("The user chose: \(option)", "Your answer")
        }
        if let text = answer.text, !text.isEmpty {
            return ("The user answered: \(text)", "Your answer")
        }
        return ("The user replied without an answer. Continue with your best judgment.", "Your answer")
    }
}

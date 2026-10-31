// InboundCommand.swift
// Majoor — The few exact messages that are commands, not tasks
//
// Only these exact forms are commands: a message that is just "stop"
// (any case) stops everything; "/status" lists sessions; "/stop" stops the
// one running session; "/stop 3" stops session 3. Everything else, however
// much it resembles one ("stop the build and summarize", "/etc/hosts"),
// is a task.

import Foundation

nonisolated enum InboundCommand: Equatable, Sendable {
    case stopAll
    case stop(Int?)
    case status
    case none

    static func parse(_ text: String) -> InboundCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "stop" { return .stopAll }
        if lower == "/status" { return .status }
        if lower == "/stop" { return .stop(nil) }
        if lower.hasPrefix("/stop ") {
            let rest = lower.dropFirst("/stop ".count).trimmingCharacters(in: .whitespaces)
            if let number = Int(rest), number > 0, String(number) == rest { return .stop(number) }
        }
        return .none
    }
}

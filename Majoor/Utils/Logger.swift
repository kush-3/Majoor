// Logger.swift
// Majoor — OSLog-based Logging Utility

import Foundation
import os.log

nonisolated struct MajoorLogger: Sendable {

    private static let general = os.Logger(subsystem: "ai.majoor.agent", category: "general")
    private static let agent = os.Logger(subsystem: "ai.majoor.agent", category: "agent")
    private static let tools = os.Logger(subsystem: "ai.majoor.agent", category: "tools")
    private static let mcp = os.Logger(subsystem: "ai.majoor.agent", category: "mcp")
    private static let database = os.Logger(subsystem: "ai.majoor.agent", category: "database")
    private static let network = os.Logger(subsystem: "ai.majoor.agent", category: "network")

    enum Category: Sendable {
        case general, agent, tools, mcp, database, network
    }

    private static func logger(for category: Category) -> os.Logger {
        switch category {
        case .general: general
        case .agent: agent
        case .tools: tools
        case .mcp: mcp
        case .database: database
        case .network: network
        }
    }

    nonisolated static func log(_ message: String, category: Category = .general, taskId: String? = nil) {
        let formatted = formatted(message, taskId: taskId)
        logger(for: category).info("\(formatted, privacy: .public)")
        #if DEBUG
        print("[Majoor] \(formatted)")
        #endif
    }

    nonisolated static func debug(_ message: String, category: Category = .general, taskId: String? = nil) {
        let formatted = formatted(message, taskId: taskId)
        logger(for: category).debug("\(formatted, privacy: .public)")
        #if DEBUG
        print("[Majoor:Debug] \(formatted)")
        #endif
    }

    nonisolated static func error(_ message: String, category: Category = .general, taskId: String? = nil) {
        let formatted = formatted(message, taskId: taskId)
        logger(for: category).error("\(formatted, privacy: .public)")
        #if DEBUG
        print("[Majoor:ERROR] \(formatted)")
        #endif
    }

    private static func formatted(_ message: String, taskId: String?) -> String {
        guard let taskId else { return message }
        return "[\(taskId)] \(message)"
    }
}

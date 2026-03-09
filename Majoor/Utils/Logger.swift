// Logger.swift
// Majoor — Logging Utility

import Foundation
import os.log

@MainActor
struct MajoorLogger {
    private static let logger = Logger(subsystem: "ai.majoor.agent", category: "general")
    
    nonisolated static func log(_ message: String) {
        #if DEBUG
        print("[Majoor] \(message)")
        #endif
    }
    
    nonisolated static func debug(_ message: String) {
        #if DEBUG
        print("[Majoor:Debug] \(message)")
        #endif
    }
    
    nonisolated static func error(_ message: String) {
        #if DEBUG
        print("[Majoor:ERROR] \(message)")
        #endif
    }
}

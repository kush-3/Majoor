// MemoryModels.swift
// Majoor — Memory Data Models

import Foundation
import GRDB

nonisolated enum MemoryCategory: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case preference  // "user prefers concise emails"
    case fact        // "Sarah = PM at Acme Corp"
    case context     // "myapp uses Next.js + TypeScript"
    case habit       // "user organizes Downloads on Fridays"

    var displayName: String {
        switch self {
        case .preference: return "Preference"
        case .fact: return "Fact"
        case .context: return "Context"
        case .habit: return "Habit"
        }
    }
}

nonisolated struct Memory: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memories"

    let id: String
    var category: MemoryCategory
    var content: String
    var sourceTaskId: String?
    var relevanceScore: Double
    var createdAt: Date
    var lastAccessedAt: Date
    var accessCount: Int

    init(
        id: String = UUID().uuidString,
        category: MemoryCategory,
        content: String,
        sourceTaskId: String? = nil,
        relevanceScore: Double = 1.0,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date(),
        accessCount: Int = 0
    ) {
        self.id = id
        self.category = category
        self.content = content
        self.sourceTaskId = sourceTaskId
        self.relevanceScore = relevanceScore
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.accessCount = accessCount
    }
}

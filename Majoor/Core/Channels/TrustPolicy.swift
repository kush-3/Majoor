// TrustPolicy.swift
// Majoor — Who may give Majoor instructions
//
// PRD §5.7 T1: only the owner can issue commands. The panel and a paired
// control client are the owner by construction. Text from a messaging
// service counts only when its sender, normalized, matches a configured
// owner handle. Everything else is data.

import Foundation
import GRDB

nonisolated enum TrustPolicy {

    /// Phone numbers become digits with a leading +, ten-digit US numbers
    /// get +1; email addresses are lowercased; anything else is trimmed.
    static func normalize(handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return trimmed.lowercased() }
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty, trimmed.allSatisfy({ $0.isNumber || "+-() .".contains($0) }) else {
            return trimmed.lowercased()
        }
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return "+" + digits
    }

    static func isOwner(sender: String, trust: ChannelTrust, owners: [String]) -> Bool {
        switch trust {
        case .local, .authenticatedClient:
            return true
        case .remoteText:
            let normalized = normalize(handle: sender)
            guard !normalized.isEmpty else { return false }
            return owners.contains { normalize(handle: $0) == normalized }
        }
    }
}

/// `contacts_policy` rows (migration v6). Phase 1 uses one trust value,
/// "owner"; VIP and other levels are Phase 2.
nonisolated struct ContactPolicyRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "contacts_policy"
    let handle: String
    var trust: String
    var isVIP: Bool
    let createdAt: Date
}

nonisolated final class ContactPolicyStore: @unchecked Sendable {

    static let shared = ContactPolicyStore(db: DatabaseManager.shared.dbQueue)
    static let ownerTrust = "owner"

    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    func owners() -> [String] {
        (try? db.read { db in
            try ContactPolicyRecord.filter(Column("trust") == Self.ownerTrust).fetchAll(db).map(\.handle)
        }) ?? []
    }

    func setTrust(handle: String, trust: String, isVIP: Bool = false) {
        let normalized = TrustPolicy.normalize(handle: handle)
        guard !normalized.isEmpty else { return }
        do {
            try db.write { db in
                if var existing = try ContactPolicyRecord.fetchOne(db, key: normalized) {
                    existing.trust = trust
                    existing.isVIP = isVIP
                    try existing.update(db)
                } else {
                    try ContactPolicyRecord(handle: normalized, trust: trust, isVIP: isVIP, createdAt: Date()).insert(db)
                }
            }
        } catch {
            MajoorLogger.error("Failed to save contact policy for \(normalized): \(error)")
        }
    }

    func remove(handle: String) {
        let normalized = TrustPolicy.normalize(handle: handle)
        _ = try? db.write { db in try ContactPolicyRecord.deleteOne(db, key: normalized) }
    }

    func all() -> [ContactPolicyRecord] {
        (try? db.read { db in try ContactPolicyRecord.order(Column("createdAt")).fetchAll(db) }) ?? []
    }
}

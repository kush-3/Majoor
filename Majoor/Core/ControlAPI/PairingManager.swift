// PairingManager.swift
// Majoor — Pairing codes and client tokens
//
// Pairing: the runtime shows an 8-character code for five minutes; the
// client sends it once and receives a 256-bit token that is never shown
// again. The runtime stores only the token's SHA-256. Five failed pairing
// attempts in fifteen minutes lock pairing until the window passes.

import Foundation
import CryptoKit
import GRDB

nonisolated struct PairedClientRecord: Codable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "paired_clients"

    let clientId: String
    let name: String
    let tokenHash: Data
    let createdAt: Date
    var lastSeenAt: Date?
    var revokedAt: Date?

    var id: String { clientId }
    var isRevoked: Bool { revokedAt != nil }
}

nonisolated final class ClientStore: @unchecked Sendable {

    static let shared = ClientStore(db: DatabaseManager.shared.dbQueue)

    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    func insert(_ record: PairedClientRecord) {
        do { try db.write { db in try record.insert(db) } }
        catch { MajoorLogger.error("Failed to save paired client: \(error)") }
    }

    func find(clientId: String) -> PairedClientRecord? {
        try? db.read { db in try PairedClientRecord.fetchOne(db, key: clientId) }
    }

    func all() -> [PairedClientRecord] {
        (try? db.read { db in try PairedClientRecord.order(Column("createdAt")).fetchAll(db) }) ?? []
    }

    func touch(clientId: String, at date: Date = Date()) {
        _ = try? db.write { db in
            try db.execute(sql: "UPDATE paired_clients SET lastSeenAt = ? WHERE clientId = ?", arguments: [date, clientId])
        }
    }

    func revoke(clientId: String, at date: Date = Date()) {
        _ = try? db.write { db in
            try db.execute(sql: "UPDATE paired_clients SET revokedAt = ? WHERE clientId = ? AND revokedAt IS NULL", arguments: [date, clientId])
        }
    }
}

actor PairingManager {

    nonisolated enum RedeemError: Error, Sendable, Equatable {
        case noCode, expired, wrongCode, lockedOut
    }

    nonisolated struct PendingCode: Sendable, Equatable {
        let code: String
        let expiresAt: Date
    }

    static let codeLifetime: TimeInterval = 300
    static let lockoutWindow: TimeInterval = 900
    static let lockoutThreshold = 5
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    private let store: ClientStore
    private var pending: PendingCode?
    private var failures: [Date] = []

    init(store: ClientStore) {
        self.store = store
    }

    // MARK: Codes

    func mintCode(now: Date = Date()) -> PendingCode {
        var generator = SystemRandomNumberGenerator()
        let code = String((0..<8).map { _ in Self.alphabet[Int.random(in: 0..<Self.alphabet.count, using: &generator)] })
        let minted = PendingCode(code: code, expiresAt: now.addingTimeInterval(Self.codeLifetime))
        pending = minted
        return minted
    }

    func currentCode(now: Date = Date()) -> PendingCode? {
        guard let pending, pending.expiresAt > now else { return nil }
        return pending
    }

    func cancelCode() { pending = nil }

    var isLockedOut: Bool { recentFailures(now: Date()) >= Self.lockoutThreshold }

    private func recentFailures(now: Date) -> Int {
        failures.removeAll { now.timeIntervalSince($0) > Self.lockoutWindow }
        return failures.count
    }

    /// Burns the code on success and returns the one-time token.
    func redeem(code: String, deviceName: String, now: Date = Date()) throws -> PairOk {
        if recentFailures(now: now) >= Self.lockoutThreshold { throw RedeemError.lockedOut }
        guard let pending else { failures.append(now); throw RedeemError.noCode }
        guard pending.expiresAt > now else { self.pending = nil; failures.append(now); throw RedeemError.expired }
        guard Self.constantTimeEquals(Data(code.uppercased().utf8), Data(pending.code.utf8)) else {
            failures.append(now)
            throw RedeemError.wrongCode
        }
        self.pending = nil
        failures.removeAll()

        var generator = SystemRandomNumberGenerator()
        let tokenBytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let token = Data(tokenBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let clientId = UUID().uuidString
        let name = String(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        store.insert(PairedClientRecord(clientId: clientId, name: name.isEmpty ? "Unnamed device" : name,
                                        tokenHash: Self.hash(token), createdAt: now, lastSeenAt: now, revokedAt: nil))
        MajoorLogger.log("🔗 Paired control client \(clientId) (\(name))")
        return PairOk(clientId: clientId, token: token)
    }

    // MARK: Tokens

    func authenticate(clientId: String, token: String, now: Date = Date()) -> Bool {
        guard let record = store.find(clientId: clientId), !record.isRevoked else { return false }
        guard Self.constantTimeEquals(Self.hash(token), record.tokenHash) else { return false }
        store.touch(clientId: clientId, at: now)
        return true
    }

    func revoke(clientId: String) {
        store.revoke(clientId: clientId)
    }

    func clients() -> [PairedClientRecord] { store.all() }

    // MARK: Helpers

    static func hash(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

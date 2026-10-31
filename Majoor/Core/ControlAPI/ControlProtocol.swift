// ControlProtocol.swift
// Majoor — Control API wire format, protocol v1
//
// JSON text frames over a WebSocket. Envelope: { v, id?, replyTo?, type,
// body }. Requests carry a client-chosen id; replies echo it as replyTo.
// Events are unsolicited and carry the same SessionEvent type the panel
// renders from, so a remote client and the local UI see identical data.

import Foundation

nonisolated enum ControlProtocol {
    static let version = 1
    static let maximumFrameBytes = 1_048_576
    static let defaultPort: UInt16 = 47821
    static let helloDeadline: Duration = .seconds(5)

    static let settingsAllowlist: Set<String> = [
        "permissionMode", "maxConcurrentSessions", "sessionTokenBudget", "dailySpendCapUSD", "showNotifications",
    ]
}

nonisolated enum ControlMessageType: String, Codable, Sendable {
    // client → server
    case pair, hello, subscribe, submit, stop, ping
    case approvalAnswer = "approval.answer"
    case sessionsList = "sessions.list"
    case settingsGet = "settings.get"
    case settingsSet = "settings.set"
    // server → client
    case pairOk = "pair.ok"
    case helloOk = "hello.ok"
    case snapshot, event, sessions, settings, pong, error, bye
    case submitAck = "submit.ack"
    case approvalOk = "approval.ok"
    case stopOk = "stop.ok"
    case settingsOk = "settings.ok"
}

nonisolated struct ControlFrame: Codable, Sendable, Equatable {
    var v: Int
    var id: String?
    var replyTo: String?
    let type: ControlMessageType
    var body: JSONValue

    init(type: ControlMessageType, body: JSONValue = .object([:]), id: String? = nil, replyTo: String? = nil) {
        self.v = ControlProtocol.version
        self.id = id
        self.replyTo = replyTo
        self.type = type
        self.body = body
    }

    init<T: Encodable>(type: ControlMessageType, body: T, id: String? = nil, replyTo: String? = nil) throws {
        self.init(type: type, body: try JSONValue.encoding(body), id: id, replyTo: replyTo)
    }

    func body<T: Decodable>(as: T.Type) throws -> T {
        try body.decoded(as: T.self)
    }

    func encoded() throws -> Data { try JSONEncoder.wire.encode(self) }

    static func decode(_ data: Data) throws -> ControlFrame {
        try JSONDecoder.wire.decode(ControlFrame.self, from: data)
    }

    static func error(_ code: ControlErrorCode, _ message: String, replyTo: String? = nil) -> ControlFrame {
        ControlFrame(type: .error, body: .object(["code": .string(code.rawValue), "message": .string(message)]), replyTo: replyTo)
    }
}

nonisolated enum ControlErrorCode: String, Codable, Sendable {
    case unauthorized, badRequest = "bad_request", badNonce = "bad_nonce", unknown, expired
    case needsLocalApproval = "needs_local_approval", notAllowed = "not_allowed", unavailable, tooManyConnections = "too_many_connections"
    case pairingFailed = "pairing_failed", lockedOut = "locked_out"
}

// MARK: - Bodies

nonisolated struct PairRequest: Codable, Sendable, Equatable {
    let code: String
    let deviceName: String
}

nonisolated struct PairOk: Codable, Sendable, Equatable {
    let clientId: String
    /// Shown once; only its hash is stored on the runtime.
    let token: String
}

nonisolated struct HelloRequest: Codable, Sendable, Equatable {
    let clientId: String
    let token: String
    let appVersion: String
    let protocolVersion: Int

    enum CodingKeys: String, CodingKey { case clientId, token, appVersion, protocolVersion = "protocol" }
}

nonisolated struct HelloOk: Codable, Sendable, Equatable {
    let runtimeId: String
    let serverVersion: String
    let seq: Int
    let mode: String
}

nonisolated struct SubscribeRequest: Codable, Sendable, Equatable {
    var sinceSeq: Int?
}

nonisolated struct SnapshotBody: Codable, Sendable {
    let sessions: [SessionInfo]
    let pendingApprovals: [ApprovalRequest]
    let recentTasks: [TaskSnapshot]
    let settings: [String: JSONValue]
    let dayUSD: Double
    let seq: Int
}

nonisolated struct SubmitRequest: Codable, Sendable, Equatable {
    let text: String
    var threadKey: String?
    let clientRequestId: String
}

nonisolated struct SubmitAck: Codable, Sendable, Equatable {
    let sessionId: SessionID
    let shortId: Int
}

nonisolated struct ApprovalAnswerRequest: Codable, Sendable, Equatable {
    let approvalId: String
    let nonce: String
    /// "approve" or "deny"
    let decision: String
    var feedback: String?
    var skipSteps: [Int]?
}

nonisolated struct StopRequest: Codable, Sendable, Equatable {
    var sessionId: SessionID?
}

nonisolated struct StopOk: Codable, Sendable, Equatable {
    let stopped: [Int]
}

nonisolated struct SessionsBody: Codable, Sendable {
    let sessions: [SessionInfo]
}

nonisolated struct SettingsGetRequest: Codable, Sendable, Equatable {
    var keys: [String]?
}

nonisolated struct SettingsBody: Codable, Sendable, Equatable {
    let values: [String: JSONValue]
}

nonisolated struct SettingsSetRequest: Codable, Sendable, Equatable {
    let key: String
    let value: JSONValue
}

nonisolated struct ByeBody: Codable, Sendable, Equatable {
    let reason: String
}

// MARK: - Settings over the API

/// Reads and writes the allowlisted settings. A client may tighten the
/// permission mode but never loosen it: a compromised laptop must not be
/// able to turn approvals off (PRD open question 3, decided tighten-only).
nonisolated enum ControlSettings {

    static let maxConcurrentKey = "maxConcurrentSessions"
    static let showNotificationsKey = "showNotifications"

    static func values(for keys: [String]? = nil) -> [String: JSONValue] {
        let wanted = keys.map { Set($0).intersection(ControlProtocol.settingsAllowlist) } ?? ControlProtocol.settingsAllowlist
        var result: [String: JSONValue] = [:]
        let defaults = UserDefaults.standard
        for key in wanted {
            switch key {
            case "permissionMode": result[key] = .string(PermissionMode.current.rawValue)
            case maxConcurrentKey:
                let stored = defaults.integer(forKey: maxConcurrentKey)
                result[key] = .number(Double(stored == 0 ? 3 : stored))
            case "sessionTokenBudget": result[key] = .number(Double(TokenBudget.perSession.maxTotalTokens))
            case "dailySpendCapUSD": result[key] = .number(TokenBudget.dailyCapUSD)
            case showNotificationsKey:
                result[key] = .bool(defaults.object(forKey: showNotificationsKey) == nil ? true : defaults.bool(forKey: showNotificationsKey))
            default: break
            }
        }
        return result
    }

    private static func rank(_ mode: PermissionMode) -> Int {
        switch mode {
        case .manual: return 0
        case .standard: return 1
        case .auto: return 2
        }
    }

    /// Pure check: nil when the write would be accepted, else the error code.
    static func validate(key: String, value: JSONValue, currentMode: PermissionMode) -> ControlErrorCode? {
        guard ControlProtocol.settingsAllowlist.contains(key) else { return .notAllowed }
        switch key {
        case "permissionMode":
            guard let raw = value.stringValue, let mode = PermissionMode(rawValue: raw) else { return .badRequest }
            return rank(mode) > rank(currentMode) ? .needsLocalApproval : nil
        case maxConcurrentKey:
            guard let n = value.intValue, (1...10).contains(n) else { return .badRequest }
        case "sessionTokenBudget":
            guard let n = value.intValue, n >= 0 else { return .badRequest }
        case "dailySpendCapUSD":
            guard let d = value.doubleValue, d >= 0 else { return .badRequest }
        case showNotificationsKey:
            guard value.boolValue != nil else { return .badRequest }
        default:
            return .notAllowed
        }
        return nil
    }

    static func set(key: String, value: JSONValue) -> ControlErrorCode? {
        if let code = validate(key: key, value: value, currentMode: PermissionMode.current) { return code }
        let defaults = UserDefaults.standard
        switch key {
        case "permissionMode": defaults.set(value.stringValue, forKey: PermissionMode.defaultsKey)
        case maxConcurrentKey: defaults.set(value.intValue, forKey: maxConcurrentKey)
        case "sessionTokenBudget": defaults.set(value.intValue, forKey: TokenBudget.sessionTokensKey)
        case "dailySpendCapUSD": defaults.set(value.doubleValue, forKey: TokenBudget.dailyCapUSDKey)
        case showNotificationsKey: defaults.set(value.boolValue, forKey: showNotificationsKey)
        default: return .notAllowed
        }
        return nil
    }
}

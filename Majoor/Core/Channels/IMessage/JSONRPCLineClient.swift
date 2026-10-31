// JSONRPCLineClient.swift
// Majoor — JSON-RPC 2.0 over a child process's stdin/stdout, one JSON per line
//
// The thin sibling of MCPClient for `imsg rpc`: the same technique (a
// Process with three pipes, a detached blocking reader, continuations per
// request id with timeouts, fail-all on EOF) with three deliberate
// differences: a Sendable JSONValue instead of [String: Any], server
// notifications surfaced as a stream, and a capped, resyncing line framer.
// MCPClient itself is untouched; only its PATH helpers are shared.

import Foundation

nonisolated enum JSONRPCError: Error, Sendable, Equatable {
    case notRunning
    case startFailed(String)
    case timeout
    case closed
    case remote(code: Int, message: String)
    case invalidResponse(String)

    var userMessage: String {
        switch self {
        case .notRunning: return "The helper process is not running"
        case .startFailed(let detail): return "Could not start the helper: \(detail)"
        case .timeout: return "The helper did not answer in time"
        case .closed: return "The helper exited"
        case .remote(let code, let message): return "\(message) (\(code))"
        case .invalidResponse(let detail): return "Bad reply from the helper: \(detail)"
        }
    }
}

nonisolated struct JSONRPCNotification: Sendable, Equatable {
    let method: String
    let params: JSONValue
}

/// What the iMessage channel needs from its helper, so tests can supply a
/// fake and the real thing can be a child process.
nonisolated protocol JSONRPCTransport: Sendable {
    func start() async throws
    func stop() async
    var isRunning: Bool { get async }
    func call(_ method: String, params: JSONValue, timeout: Duration) async throws -> JSONValue
    /// Server-initiated messages. The stream ends when the transport exits.
    func notifications() async -> AsyncStream<JSONRPCNotification>
}

actor JSONRPCLineClient: JSONRPCTransport {

    static let defaultTimeout: Duration = .seconds(30)
    static let killGrace: Duration = .seconds(2)

    private let command: String
    private let arguments: [String]
    private let label: String
    private var process: Process?
    private var stdin: FileHandle?
    private var readTask: Task<Void, Never>?
    private var framer = NewlineJSONFramer()
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<JSONRPCNotification>.Continuation] = [:]

    init(command: String, arguments: [String], label: String? = nil) {
        self.command = command
        self.arguments = arguments
        self.label = label ?? command
    }

    var isRunning: Bool { process?.isRunning ?? false }

    /// Where the helper binary was found, or nil. GUI apps do not inherit
    /// the shell PATH, so this looks in the usual places and asks the login shell.
    static func resolve(_ command: String) -> String? {
        command.hasPrefix("/") ? (FileManager.default.isExecutableFile(atPath: command) ? command : nil) : MCPClient.resolveCommand(command)
    }

    // MARK: Lifecycle

    func start() async throws {
        if let process, process.isRunning { return }
        let proc = Process()
        guard let path = Self.resolve(command) else {
            throw JSONRPCError.startFailed("\(command) not found. Install it with: brew install steipete/tap/imsg")
        }
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = MCPClient.augmentedPath(existing: env["PATH"])
        proc.environment = env

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        let label = self.label
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                MajoorLogger.log("\(label) stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))")
            }
        }
        do {
            try proc.run()
        } catch {
            throw JSONRPCError.startFailed(error.localizedDescription)
        }
        process = proc
        stdin = stdinPipe.fileHandleForWriting
        framer = NewlineJSONFramer()
        let stdout = stdoutPipe.fileHandleForReading
        readTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = stdout.availableData   // blocking; never on the actor
                if data.isEmpty {
                    await self?.processEnded()
                    break
                }
                await self?.ingest(data)
            }
        }
        MajoorLogger.log("\(label) started (pid \(proc.processIdentifier))")
    }

    func stop() async {
        readTask?.cancel()
        readTask = nil
        if let proc = process, proc.isRunning {
            try? stdin?.close()   // EOF: imsg exits cleanly when stdin closes
            proc.terminate()
            try? await Task.sleep(for: Self.killGrace)
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdin = nil
        failAll(JSONRPCError.closed)
        finishSubscribers()
    }

    private func processEnded() {
        MajoorLogger.log("\(label) exited")
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdin = nil
        failAll(JSONRPCError.closed)
        finishSubscribers()
    }

    // MARK: Requests

    func call(_ method: String, params: JSONValue, timeout: Duration = JSONRPCLineClient.defaultTimeout) async throws -> JSONValue {
        guard let stdin, process?.isRunning == true else { throw JSONRPCError.notRunning }
        nextId += 1
        let id = nextId
        var frame: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method)]
        if case .object(let dict) = params, !dict.isEmpty { frame["params"] = params }
        var data = try JSONValue.object(frame).data()
        data.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.fail(id, JSONRPCError.timeout)
            }
            do {
                try stdin.write(contentsOf: data)
            } catch {
                fail(id, JSONRPCError.closed)
            }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    // MARK: Notifications

    func notifications() -> AsyncStream<JSONRPCNotification> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(4096)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func finishSubscribers() {
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: Inbound

    private func ingest(_ data: Data) {
        for line in framer.push(data) {
            guard let value = try? JSONValue(data: line) else {
                MajoorLogger.log("\(label): ignored non-JSON line (\(line.count) bytes)")
                continue
            }
            dispatch(value)
        }
    }

    private func dispatch(_ value: JSONValue) {
        if let id = value["id"]?.intValue, value["method"] == nil {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = value["error"], !error.isNull {
                continuation.resume(throwing: JSONRPCError.remote(code: error["code"]?.intValue ?? -1,
                                                                 message: error["message"]?.stringValue ?? "error"))
            } else {
                continuation.resume(returning: value["result"] ?? .null)
            }
            return
        }
        if let method = value["method"]?.stringValue {
            let notification = JSONRPCNotification(method: method, params: value["params"] ?? .object([:]))
            for continuation in subscribers.values { continuation.yield(notification) }
        }
    }
}

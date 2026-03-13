// MCPClient.swift
// Majoor — MCP Client (JSON-RPC over stdio)
//
// Actor that spawns an MCP server subprocess, communicates via JSON-RPC 2.0
// over stdin/stdout, discovers tools, and executes tool calls.

import Foundation

// MARK: - MCP Data Types

nonisolated struct MCPToolDefinition: Sendable {
    let name: String
    let description: String
    let inputSchema: MCPInputSchema?
}

nonisolated struct MCPInputSchema: Sendable {
    let properties: [String: MCPPropertySchema]
    let required: [String]
}

nonisolated struct MCPPropertySchema: Sendable {
    let type: String
    let description: String
    let enumValues: [String]?
}

nonisolated struct MCPToolResult: Sendable {
    let content: String
    let isError: Bool
}

// MARK: - MCPClient Actor

actor MCPClient {

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var requestId: Int = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var buffer = Data()
    private(set) var discoveredTools: [MCPToolDefinition] = []
    let serverName: String

    enum MCPError: LocalizedError {
        case notRunning
        case startFailed(String)
        case initializeFailed(String)
        case invalidResponse(String)
        case toolCallFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notRunning: return "MCP server is not running"
            case .startFailed(let msg): return "MCP server failed to start: \(msg)"
            case .initializeFailed(let msg): return "MCP initialization failed: \(msg)"
            case .invalidResponse(let msg): return "Invalid MCP response: \(msg)"
            case .toolCallFailed(let msg): return "MCP tool call failed: \(msg)"
            case .timeout: return "MCP request timed out"
            }
        }
    }

    init(serverName: String) {
        self.serverName = serverName
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - Lifecycle

    func start(command: String, args: [String], env: [String: String]) async throws {
        let proc = Process()

        // Resolve command path — if it's a bare name like "npx", find it
        if command.hasPrefix("/") {
            proc.executableURL = URL(fileURLWithPath: command)
            proc.arguments = args
        } else {
            // GUI apps don't inherit shell PATH, so resolve the command manually
            if let resolved = Self.resolveCommand(command) {
                proc.executableURL = URL(fileURLWithPath: resolved)
                proc.arguments = args
            } else {
                // Fallback to /usr/bin/env (may fail if PATH is too minimal)
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = [command] + args
            }
        }

        // Merge env with current process environment + augmented PATH
        var processEnv = ProcessInfo.processInfo.environment
        processEnv["PATH"] = Self.augmentedPath(existing: processEnv["PATH"])
        for (k, v) in env { processEnv[k] = v }
        proc.environment = processEnv

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Log stderr in background
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                MajoorLogger.log("MCP[\(self.serverName)] stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        do {
            try proc.run()
        } catch {
            throw MCPError.startFailed(error.localizedDescription)
        }

        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading

        // Start background reader on a detached task so it doesn't block the actor.
        // availableData is a blocking call — running it on the actor's executor
        // would prevent all other actor methods (isRunning, listTools, etc.) from executing.
        let stdout = stdoutPipe.fileHandleForReading
        let name = serverName
        readTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = stdout.availableData
                if data.isEmpty {
                    MajoorLogger.log("MCP[\(name)] stdout EOF — process terminated")
                    break
                }
                await self?.handleIncomingData(data)
            }
        }

        MajoorLogger.log("MCP[\(serverName)] process started (pid: \(proc.processIdentifier))")

        // Send initialize request
        let initResult = try await sendRequest(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": [
                "name": "Majoor",
                "version": "0.5.0"
            ] as [String: Any]
        ])

        MajoorLogger.log("MCP[\(serverName)] initialized: \(initResult.keys.joined(separator: ", "))")

        // Send initialized notification (no response expected)
        sendNotification(method: "notifications/initialized", params: [:])

        // Discover tools
        try await refreshTools()
    }

    func shutdown() async {
        readTask?.cancel()
        readTask = nil

        if let proc = process, proc.isRunning {
            // Try graceful shutdown first
            sendNotification(method: "notifications/cancelled", params: ["reason": "shutdown"])
            proc.terminate()

            // Give it a moment to terminate
            try? await Task.sleep(nanoseconds: 500_000_000)
            if proc.isRunning {
                proc.terminate()
            }
        }

        stdinHandle = nil
        stdoutHandle = nil
        process = nil
        pending.removeAll()
        buffer = Data()

        MajoorLogger.log("MCP[\(serverName)] shut down")
    }

    // MARK: - Tool Discovery

    func refreshTools() async throws {
        let result = try await sendRequest(method: "tools/list", params: [:])

        guard let toolsArray = result["tools"] as? [[String: Any]] else {
            MajoorLogger.error("MCP[\(serverName)] tools/list returned no tools array")
            discoveredTools = []
            return
        }

        discoveredTools = toolsArray.compactMap { parseTool($0) }
        MajoorLogger.log("MCP[\(serverName)] discovered \(discoveredTools.count) tool(s)")
    }

    func listTools() async throws -> [MCPToolDefinition] {
        if discoveredTools.isEmpty {
            try await refreshTools()
        }
        return discoveredTools
    }

    // MARK: - Tool Execution

    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        let result = try await sendRequest(method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ])

        let isError = result["isError"] as? Bool ?? false

        // Parse content array
        var outputParts: [String] = []
        if let contentArray = result["content"] as? [[String: Any]] {
            for item in contentArray {
                if let text = item["text"] as? String {
                    outputParts.append(text)
                } else if let type = item["type"] as? String {
                    outputParts.append("[\(type) content]")
                }
            }
        }

        let output = outputParts.isEmpty ? "No output" : outputParts.joined(separator: "\n")
        return MCPToolResult(content: output, isError: isError)
    }

    // MARK: - JSON-RPC Communication

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let stdinHandle, process?.isRunning == true else {
            throw MCPError.notRunning
        }

        requestId += 1
        let id = requestId

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: request)
        // MCP stdio transport uses newline-delimited JSON (NOT Content-Length like LSP)
        guard var message = jsonData as Data? else {
            throw MCPError.invalidResponse("Failed to encode request")
        }
        message.append(contentsOf: [0x0A]) // append \n

        // Wait for response with timeout
        // IMPORTANT: Store continuation BEFORE writing to stdin to avoid race condition.
        // The detached read task could receive the response before the continuation is stored.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            pending[id] = continuation
            stdinHandle.write(message)

            // Timeout after 30 seconds
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let cont = pending.removeValue(forKey: id) {
                    cont.resume(throwing: MCPError.timeout)
                }
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) {
        guard let stdinHandle, process?.isRunning == true else { return }

        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]

        guard var jsonData = try? JSONSerialization.data(withJSONObject: notification) else { return }
        // MCP stdio: newline-delimited JSON
        jsonData.append(contentsOf: [0x0A]) // \n
        stdinHandle.write(jsonData)
    }

    // MARK: - Read Loop

    /// Called from the detached read task when new data arrives on stdout.
    func handleIncomingData(_ data: Data) {
        MajoorLogger.log("MCP[\(serverName)] received \(data.count) bytes")
        if let raw = String(data: data, encoding: .utf8) {
            MajoorLogger.log("MCP[\(serverName)] raw: \(String(raw.prefix(500)))")
        }
        buffer.append(data)
        processBuffer()
    }

    private func processBuffer() {
        // MCP stdio transport: newline-delimited JSON — each line is a complete JSON-RPC message
        while true {
            guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
                // No complete line yet — wait for more data
                break
            }

            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            // Skip empty lines
            if lineData.isEmpty { continue }

            // Parse JSON-RPC message
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                // Could be a non-JSON line (some servers emit debug text) — skip it
                if let text = String(data: lineData, encoding: .utf8) {
                    MajoorLogger.log("MCP[\(serverName)] skipping non-JSON line: \(String(text.prefix(200)))")
                }
                continue
            }

            MajoorLogger.log("MCP[\(serverName)] parsed JSON-RPC: id=\(json["id"] ?? "nil"), method=\(json["method"] ?? "nil"), hasResult=\(json["result"] != nil), hasError=\(json["error"] != nil)")

            if let id = json["id"] as? Int {
                let hasPending = pending[id] != nil
                MajoorLogger.log("MCP[\(serverName)] response for id=\(id), pending=\(hasPending)")

                if let error = json["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "Unknown error"
                    let code = error["code"] as? Int ?? -1
                    if let continuation = pending.removeValue(forKey: id) {
                        continuation.resume(throwing: MCPError.toolCallFailed("[\(code)] \(message)"))
                    }
                } else if let result = json["result"] as? [String: Any] {
                    if let continuation = pending.removeValue(forKey: id) {
                        continuation.resume(returning: result)
                    }
                } else {
                    if let continuation = pending.removeValue(forKey: id) {
                        continuation.resume(returning: [:])
                    }
                }
            }
            // Notifications from server (no id) — log and ignore for now
            else if let method = json["method"] as? String {
                MajoorLogger.log("MCP[\(serverName)] notification: \(method)")
            }
        }
    }

    // MARK: - Tool Parsing

    private func parseTool(_ dict: [String: Any]) -> MCPToolDefinition? {
        guard let name = dict["name"] as? String else { return nil }
        let description = dict["description"] as? String ?? ""

        var schema: MCPInputSchema?
        if let inputSchema = dict["inputSchema"] as? [String: Any],
           let props = inputSchema["properties"] as? [String: [String: Any]] {
            var properties: [String: MCPPropertySchema] = [:]
            for (propName, propDict) in props {
                let type = propDict["type"] as? String ?? "string"
                let desc = propDict["description"] as? String ?? ""
                let enumVals = propDict["enum"] as? [String]
                properties[propName] = MCPPropertySchema(type: type, description: desc, enumValues: enumVals)
            }
            let required = inputSchema["required"] as? [String] ?? []
            schema = MCPInputSchema(properties: properties, required: required)
        }

        return MCPToolDefinition(name: name, description: description, inputSchema: schema)
    }

    // MARK: - PATH Resolution

    /// Common directories where Node.js/npx/npm are installed on macOS.
    /// GUI apps inherit a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) and miss these.
    private static let extraPathDirs = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "\(NSHomeDirectory())/.nvm/versions/node/default/bin",
        "\(NSHomeDirectory())/.volta/bin",
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/Library/pnpm",
    ]

    /// Try to find a command in common PATH locations.
    private static func resolveCommand(_ command: String) -> String? {
        let searchPaths = extraPathDirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for dir in searchPaths {
            let fullPath = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        // Also try resolving via the user's shell
        if let shellResolved = resolveViaShell(command) {
            return shellResolved
        }
        return nil
    }

    /// Run the user's login shell to resolve a command path (handles nvm, etc.).
    private static func resolveViaShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-c", "which \(command)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, proc.terminationStatus == 0 {
                return path
            }
        } catch {}
        return nil
    }

    /// Augment the existing PATH with common Node.js locations.
    static func augmentedPath(existing: String?) -> String {
        let base = existing ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existingDirs = Set(base.split(separator: ":").map(String.init))
        let missing = extraPathDirs.filter { !existingDirs.contains($0) }
        if missing.isEmpty { return base }
        return (missing + [base]).joined(separator: ":")
    }
}

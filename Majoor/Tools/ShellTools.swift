// ShellTools.swift
// Majoor — Shell & Code Execution Tools
//
// Execute shell commands and scripts via Process API.
// All commands go through CommandSanitizer before execution.

import Foundation

// MARK: - Execute Shell Command

nonisolated struct ExecuteShellTool: AgentTool {
    let name = "execute_shell"
    let description = "Execute a shell command and return its output. Use for git, build tools, scripts, etc. Dangerous commands are blocked."
    let parameters = [
        ToolParameter(name: "command", description: "The shell command to execute (e.g., 'ls -la', 'git status', 'python3 script.py')"),
        ToolParameter(name: "working_directory", description: "Directory to run the command in. Defaults to home directory.")
    ]
    let requiredParameters = ["command"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let command = arguments["command"] else {
            return ToolResult(success: false, output: "Error: 'command' is required")
        }

        // Safety check
        let validation = CommandSanitizer.validate(command: command)
        guard validation.isAllowed else {
            return ToolResult(success: false, output: "⛔ Command blocked: \(validation.reason ?? "security policy")")
        }

        let workDir: String
        if let dir = arguments["working_directory"] {
            workDir = NSString(string: dir).expandingTildeInPath
        } else {
            workDir = NSHomeDirectory()
        }

        guard FileManager.default.fileExists(atPath: workDir) else {
            return ToolResult(success: false, output: "Error: Working directory not found: \(workDir)")
        }

        return await runShellCommand(command, workingDirectory: workDir, timeout: 30)
    }
}

// MARK: - Execute Script

nonisolated struct ExecuteScriptTool: AgentTool {
    let name = "execute_script"
    let description = "Execute a script in Python, Node.js, Ruby, or Bash. Writes code to a temp file and runs it."
    let parameters = [
        ToolParameter(name: "language", description: "Script language: python, node, ruby, bash", enumValues: ["python", "node", "ruby", "bash"]),
        ToolParameter(name: "code", description: "The script code to execute"),
        ToolParameter(name: "working_directory", description: "Directory to run the script in. Defaults to home directory.")
    ]
    let requiredParameters = ["language", "code"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let language = arguments["language"], let code = arguments["code"] else {
            return ToolResult(success: false, output: "Error: 'language' and 'code' are required")
        }

        let interpreterMap: [String: (command: String, ext: String)] = [
            "python": ("python3", "py"),
            "node": ("node", "js"),
            "ruby": ("ruby", "rb"),
            "bash": ("bash", "sh"),
        ]

        guard let interpreter = interpreterMap[language.lowercased()] else {
            return ToolResult(success: false, output: "Error: Unsupported language '\(language)'. Use: python, node, ruby, bash")
        }

        // Bash scripts are shell command sequences — run them through the same
        // sanitizer as execute_shell, so a blocked command can't simply be
        // wrapped in a script. Interpreted languages are gated by the
        // confirmation policy instead (substring-scanning arbitrary code would
        // be both bypassable and false-positive-prone).
        if language.lowercased() == "bash" {
            let validation = CommandSanitizer.validate(command: code)
            guard validation.isAllowed else {
                return ToolResult(success: false, output: "⛔ Script blocked: \(validation.reason ?? "security policy")")
            }
        }

        // Write script to temp file
        let tempDir = NSTemporaryDirectory()
        let scriptPath = (tempDir as NSString).appendingPathComponent("majoor_script_\(UUID().uuidString).\(interpreter.ext)")

        do {
            try code.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            return ToolResult(success: false, output: "Error writing temp script: \(error.localizedDescription)")
        }

        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

        let workDir: String
        if let dir = arguments["working_directory"] {
            workDir = NSString(string: dir).expandingTildeInPath
        } else {
            workDir = NSHomeDirectory()
        }

        let command = "\(interpreter.command) \(scriptPath)"
        return await runShellCommand(command, workingDirectory: workDir, timeout: 60)
    }
}

// MARK: - Read Project Structure

nonisolated struct ReadProjectStructureTool: AgentTool {
    let name = "read_project_structure"
    let description = "Get an overview of a project/codebase directory tree. Respects .gitignore and skips common non-essential directories."
    let parameters = [
        ToolParameter(name: "path", description: "Root path of the project"),
        ToolParameter(name: "max_depth", type: "integer", description: "Max directory depth. Default 3.")
    ]
    let requiredParameters = ["path"]
    let requiresConfirmation = false
    let isReadOnly = true

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["path"] else {
            return ToolResult(success: false, output: "Error: 'path' is required")
        }
        let maxDepth = Int(arguments["max_depth"] ?? "3") ?? 3
        let expanded = NSString(string: path).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expanded) else {
            return ToolResult(success: false, output: "Error: Path not found: \(path)")
        }

        let skipDirs: Set<String> = [
            "node_modules", ".git", ".build", "DerivedData", "Pods",
            "__pycache__", ".pytest_cache", ".mypy_cache", "venv", ".venv",
            "dist", "build", ".next", ".nuxt", "coverage", ".tox",
            ".idea", ".vscode", "target", "vendor"
        ]

        var output = "Project: \(path)\n\n"
        var fileCount = 0
        var dirCount = 0

        func walk(dir: String, depth: Int, prefix: String) {
            guard depth <= maxDepth else { return }
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(atPath: dir).sorted() else { return }
            let filtered = items.filter { !$0.hasPrefix(".") || $0 == ".gitignore" || $0 == ".env.example" }

            for (index, item) in filtered.enumerated() {
                let fullPath = (dir as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)

                let isLast = index == filtered.count - 1
                let connector = isLast ? "└── " : "├── "
                let newPrefix = prefix + (isLast ? "    " : "│   ")

                if isDir.boolValue {
                    if skipDirs.contains(item) {
                        output += "\(prefix)\(connector)📁 \(item)/ (skipped)\n"
                    } else {
                        dirCount += 1
                        output += "\(prefix)\(connector)📁 \(item)/\n"
                        walk(dir: fullPath, depth: depth + 1, prefix: newPrefix)
                    }
                } else {
                    fileCount += 1
                    output += "\(prefix)\(connector)\(fileIcon(for: item)) \(item)\n"
                }
            }
        }

        walk(dir: expanded, depth: 1, prefix: "")
        output += "\n\(dirCount) directories, \(fileCount) files"

        return ToolResult(success: true, output: output)
    }
}

// MARK: - Run Tests

nonisolated struct RunTestsTool: AgentTool {
    let name = "run_tests"
    let description = "Run a project's test suite. Auto-detects the test command or you can specify one."
    let parameters = [
        ToolParameter(name: "path", description: "Project root directory"),
        ToolParameter(name: "command", description: "Test command to run. If omitted, auto-detects based on project type.")
    ]
    let requiredParameters = ["path"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["path"] else {
            return ToolResult(success: false, output: "Error: 'path' is required")
        }
        let expanded = NSString(string: path).expandingTildeInPath

        let testCommand: String
        if let cmd = arguments["command"] {
            testCommand = cmd
        } else {
            testCommand = detectTestCommand(at: expanded)
        }

        if testCommand.isEmpty {
            return ToolResult(success: false, output: "Could not detect test command. Specify one with the 'command' parameter.")
        }

        let validation = CommandSanitizer.validate(command: testCommand)
        guard validation.isAllowed else {
            return ToolResult(success: false, output: "⛔ Test command blocked: \(validation.reason ?? "security policy")")
        }

        return await runShellCommand(testCommand, workingDirectory: expanded, timeout: 120)
    }

    private func detectTestCommand(at path: String) -> String {
        let fm = FileManager.default
        // Node.js
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("package.json")) {
            return "npm test"
        }
        // Python
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("pytest.ini")) ||
           fm.fileExists(atPath: (path as NSString).appendingPathComponent("setup.py")) ||
           fm.fileExists(atPath: (path as NSString).appendingPathComponent("pyproject.toml")) {
            return "python3 -m pytest -v"
        }
        // Swift
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("Package.swift")) {
            return "swift test"
        }
        // Rust
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("Cargo.toml")) {
            return "cargo test"
        }
        // Go
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("go.mod")) {
            return "go test ./..."
        }
        return ""
    }
}

// MARK: - Shared Shell Runner

/// Streams a pipe into capped head + rolling-tail buffers (512 KB each) via
/// readabilityHandler — its own GCD queue, not the cooperative pool. The pipe is
/// always drained so the child never blocks on a full buffer, and only the
/// middle of oversized output is discarded: the tail is kept because that's
/// where build/test failure summaries print. A runaway command previously
/// ballooned the app to gigabytes by buffering its entire output. EOF is exposed
/// as a DispatchGroup so callers can wait with a deadline — a background
/// grandchild that inherited the pipe and never exits must not hang the agent loop.
private nonisolated final class CappedPipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var head = Data()
    private var tail = Data()
    private var totalBytes = 0
    private var finished = false
    private let headCap: Int
    private let tailCap: Int
    private let handle: FileHandle
    let eofGroup = DispatchGroup()

    init(pipe: Pipe, headCap: Int = 512_000, tailCap: Int = 512_000) {
        self.headCap = headCap
        self.tailCap = tailCap
        self.handle = pipe.fileHandleForReading
        eofGroup.enter()
        handle.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = h.availableData
            if chunk.isEmpty {
                self.finishReading(keepDraining: false)
            } else {
                self.append(chunk)
            }
        }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        totalBytes += chunk.count
        let headRoom = headCap - head.count
        if headRoom >= chunk.count {
            head.append(chunk)
            return
        }
        if headRoom > 0 { head.append(chunk.prefix(headRoom)) }
        tail.append(chunk.dropFirst(max(0, headRoom)))
        // Evict lazily at 2× cap to amortize the copy. Data(…) forces a real
        // copy — a bare .suffix() slice would share (and keep growing) the old
        // backing store, silently retaining the entire stream.
        if tail.count > tailCap * 2 {
            tail = Data(tail.suffix(tailCap))
        }
    }

    /// EOF removes the handler. The deadline path (keepDraining) instead swaps
    /// in a discard-only handler that holds the pipe open until the writer
    /// exits — otherwise a deliberately backgrounded child (`npm run dev &`)
    /// would be SIGPIPE-killed on its next write when the read end closes.
    private func finishReading(keepDraining: Bool) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        if keepDraining {
            let handle = self.handle
            handle.readabilityHandler = { _ in
                if handle.availableData.isEmpty {
                    handle.readabilityHandler = nil
                }
            }
        } else {
            handle.readabilityHandler = nil
        }
        eofGroup.leave()
    }

    /// Stop capturing (idempotent) and return the captured text plus how many
    /// middle bytes were discarded. Pass abandon=true only when the process
    /// never launched (there is no writer to keep the pipe open for).
    func settle(abandon: Bool = false) -> (text: String, droppedBytes: Int) {
        finishReading(keepDraining: !abandon)
        lock.lock()
        defer { lock.unlock() }
        if tail.count > tailCap { tail = Data(tail.suffix(tailCap)) }
        let dropped = totalBytes - head.count - tail.count
        var data = head
        if !tail.isEmpty {
            // dropped == 0 means head and tail are contiguous — no marker
            if dropped > 0 {
                data.append(Data("\n[... middle of output omitted ...]\n".utf8))
            }
            data.append(tail)
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (text, dropped)
    }
}

/// Resume-once guard for continuations raced between multiple completion paths.
private nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func tryTake() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

nonisolated func runShellCommand(_ command: String, workingDirectory: String, timeout: TimeInterval) async -> ToolResult {
    MajoorLogger.log("🐚 Shell: \(command) (in \(workingDirectory))")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

    // Inherit user's PATH
    var env = ProcessInfo.processInfo.environment
    if let path = env["PATH"] {
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(path)"
    }
    process.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Install capture before launch so no early output is missed
    let stdoutCapture = CappedPipeCapture(pipe: stdoutPipe)
    let stderrCapture = CappedPipeCapture(pipe: stderrPipe)

    do {
        try process.run()
    } catch {
        _ = stdoutCapture.settle(abandon: true)
        _ = stderrCapture.settle(abandon: true)
        return ToolResult(success: false, output: "Failed to start process: \(error.localizedDescription)")
    }

    // Timeout: SIGTERM the zsh wrapper, then SIGKILL if it ignores the request
    let timeoutTask = Task {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if process.isRunning {
            process.terminate()
        }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // Wait for process exit without blocking a cooperative thread.
    // Set terminationHandler unconditionally — Foundation calls it retroactively
    // even if the process already exited, avoiding TOCTOU race on isRunning.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        process.terminationHandler = { _ in continuation.resume() }
    }
    timeoutTask.cancel()

    // Wait for both streams to reach EOF, but only briefly now that the process
    // has exited — a grandchild that inherited the pipe (e.g. `something &`)
    // would otherwise hold the read open indefinitely.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let once = OnceFlag()
        let bothStreams = DispatchGroup()
        bothStreams.enter()
        stdoutCapture.eofGroup.notify(queue: .global()) { bothStreams.leave() }
        bothStreams.enter()
        stderrCapture.eofGroup.notify(queue: .global()) { bothStreams.leave() }
        bothStreams.notify(queue: .global()) {
            if once.tryTake() { continuation.resume() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            if once.tryTake() { continuation.resume() }
        }
    }

    let (stdout, stdoutDropped) = stdoutCapture.settle()
    let (stderr, stderrDropped) = stderrCapture.settle()

    let exitCode = process.terminationStatus
    let success = exitCode == 0

    var output = ""
    if !stdout.isEmpty {
        output += stdout
    }
    if !stderr.isEmpty {
        output += output.isEmpty ? stderr : "\n--- stderr ---\n\(stderr)"
    }
    let dropped = stdoutDropped + stderrDropped
    if dropped > 0 {
        output += "\n[... output exceeded the 1 MB capture limit; \(dropped) additional bytes were discarded ...]"
    }
    if output.isEmpty {
        output = success ? "(no output)" : "Process exited with code \(exitCode)"
    }

    // Truncate very long output
    if output.count > 10000 {
        let head = String(output.prefix(4000))
        let tail = String(output.suffix(4000))
        output = "\(head)\n\n... [truncated \(output.count - 8000) characters] ...\n\n\(tail)"
    }

    if !success {
        output = "Exit code: \(exitCode)\n\(output)"
    }

    return ToolResult(success: success, output: output)
}

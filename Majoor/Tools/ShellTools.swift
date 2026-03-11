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

    do {
        try process.run()
    } catch {
        return ToolResult(success: false, output: "Failed to start process: \(error.localizedDescription)")
    }

    // Timeout handling
    let timeoutTask = Task {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if process.isRunning {
            process.terminate()
        }
    }

    process.waitUntilExit()
    timeoutTask.cancel()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

    let exitCode = process.terminationStatus
    let success = exitCode == 0

    var output = ""
    if !stdout.isEmpty {
        output += stdout
    }
    if !stderr.isEmpty {
        output += output.isEmpty ? stderr : "\n--- stderr ---\n\(stderr)"
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

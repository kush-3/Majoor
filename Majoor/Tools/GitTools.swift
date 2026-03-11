// GitTools.swift
// Majoor — Git & PR Tools
//
// Uses system git and gh CLI for operations.
// Safety: Never commits to main/master/develop. Always uses agent/ branch prefix.

import Foundation

// MARK: - Git Status

nonisolated struct GitStatusTool: AgentTool {
    let name = "git_status"
    let description = "Check the current git status of a repository. Shows branch, staged/unstaged changes, and untracked files."
    let parameters = [
        ToolParameter(name: "repo_path", description: "Path to the git repository")
    ]
    let requiredParameters = ["repo_path"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["repo_path"] else {
            return ToolResult(success: false, output: "Error: 'repo_path' is required")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        return await runShellCommand("git status", workingDirectory: expanded, timeout: 10)
    }
}

// MARK: - Git Diff

nonisolated struct GitDiffTool: AgentTool {
    let name = "git_diff"
    let description = "View current changes in a git repository. Shows unstaged changes by default, or staged changes with staged=true."
    let parameters = [
        ToolParameter(name: "repo_path", description: "Path to the git repository"),
        ToolParameter(name: "staged", type: "boolean", description: "Show staged changes instead. Default false."),
        ToolParameter(name: "file", description: "Specific file to diff. Optional.")
    ]
    let requiredParameters = ["repo_path"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["repo_path"] else {
            return ToolResult(success: false, output: "Error: 'repo_path' is required")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        var cmd = "git diff"
        if arguments["staged"] == "true" { cmd += " --cached" }
        if let file = arguments["file"] { cmd += " -- \(file)" }
        return await runShellCommand(cmd, workingDirectory: expanded, timeout: 10)
    }
}

// MARK: - Git Log

nonisolated struct GitLogTool: AgentTool {
    let name = "git_log"
    let description = "View recent commit history of a repository."
    let parameters = [
        ToolParameter(name: "repo_path", description: "Path to the git repository"),
        ToolParameter(name: "count", type: "integer", description: "Number of commits to show. Default 10.")
    ]
    let requiredParameters = ["repo_path"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["repo_path"] else {
            return ToolResult(success: false, output: "Error: 'repo_path' is required")
        }
        let count = arguments["count"] ?? "10"
        let expanded = NSString(string: path).expandingTildeInPath
        return await runShellCommand("git log --oneline --graph -\(count)", workingDirectory: expanded, timeout: 10)
    }
}

// MARK: - Git Create Branch

nonisolated struct GitBranchTool: AgentTool {
    let name = "git_create_branch"
    let description = "Create and checkout a new git branch. Branch name is automatically prefixed with 'agent/' for safety."
    let parameters = [
        ToolParameter(name: "repo_path", description: "Path to the git repository"),
        ToolParameter(name: "branch_name", description: "Branch name (will be prefixed with 'agent/' automatically)")
    ]
    let requiredParameters = ["repo_path", "branch_name"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["repo_path"], let name = arguments["branch_name"] else {
            return ToolResult(success: false, output: "Error: 'repo_path' and 'branch_name' are required")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        let branchName = name.hasPrefix("agent/") ? name : "agent/\(name)"
        return await runShellCommand("git checkout -b \(branchName)", workingDirectory: expanded, timeout: 10)
    }
}

// MARK: - Git Checkout

nonisolated struct GitCheckoutTool: AgentTool {
    let name = "git_checkout"
    let description = "Switch to an existing git branch."
    let parameters = [
        ToolParameter(name: "repo_path", description: "Path to the git repository"),
        ToolParameter(name: "branch", description: "Branch name to switch to")
    ]
    let requiredParameters = ["repo_path", "branch"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["repo_path"], let branch = arguments["branch"] else {
            return ToolResult(success: false, output: "Error: 'repo_path' and 'branch' are required")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        return await runShellCommand("git checkout \(branch)", workingDirectory: expanded, timeout: 10)
    }
}

// MARK: - Git Commit

nonisolated struct GitCommitTool: AgentTool {
    let name = "git_commit"
    let description = "Stage specified files and create a git commit. Cannot commit to main/master/develop."
    let parameters = [
        ToolParameter(name: "repo_path", description: "Path to the git repository"),
        ToolParameter(name: "message", description: "Commit message"),
        ToolParameter(name: "files", description: "Space-separated list of files to stage (e.g., 'src/main.ts src/utils.ts'). Use '.' to stage all changes.")
    ]
    let requiredParameters = ["repo_path", "message", "files"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["repo_path"],
              let message = arguments["message"],
              let files = arguments["files"] else {
            return ToolResult(success: false, output: "Error: 'repo_path', 'message', and 'files' are required")
        }
        let expanded = NSString(string: path).expandingTildeInPath

        // Safety: check current branch
        let branchResult = await runShellCommand("git branch --show-current", workingDirectory: expanded, timeout: 5)
        let currentBranch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let protectedBranches = ["main", "master", "develop", "production"]
        if protectedBranches.contains(currentBranch) {
            return ToolResult(success: false, output: "⛔ Cannot commit to protected branch '\(currentBranch)'. Create a new branch first with git_create_branch.")
        }

        // Stage files
        let stageResult = await runShellCommand("git add \(files)", workingDirectory: expanded, timeout: 10)
        if !stageResult.success {
            return ToolResult(success: false, output: "Failed to stage files: \(stageResult.output)")
        }

        // Commit
        let escapedMessage = message.replacingOccurrences(of: "'", with: "'\\''")
        return await runShellCommand("git commit -m '\(escapedMessage)'", workingDirectory: expanded, timeout: 15)
    }
}

// MARK: - Git Push

nonisolated struct GitPushTool: AgentTool {
    let name = "git_push"
    let description = "Push the current branch to the remote repository."
    let parameters = [
        ToolParameter(name: "repo_path", description: "Path to the git repository"),
        ToolParameter(name: "set_upstream", type: "boolean", description: "Set upstream tracking (-u). Default true for new branches.")
    ]
    let requiredParameters = ["repo_path"]
    let requiresConfirmation = true  // Push is a visible-to-others action

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["repo_path"] else {
            return ToolResult(success: false, output: "Error: 'repo_path' is required")
        }
        let expanded = NSString(string: path).expandingTildeInPath

        // Get current branch
        let branchResult = await runShellCommand("git branch --show-current", workingDirectory: expanded, timeout: 5)
        let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let protectedBranches = ["main", "master", "develop", "production"]
        if protectedBranches.contains(branch) {
            return ToolResult(success: false, output: "⛔ Cannot push to protected branch '\(branch)'.")
        }

        let setUpstream = arguments["set_upstream"] != "false"
        let cmd = setUpstream ? "git push -u origin \(branch)" : "git push"
        return await runShellCommand(cmd, workingDirectory: expanded, timeout: 30)
    }
}

// MARK: - Create Pull Request

nonisolated struct GitCreatePRTool: AgentTool {
    let name = "git_create_pr"
    let description = "Create a pull request on GitHub using the gh CLI. Requires gh to be installed and authenticated."
    let parameters = [
        ToolParameter(name: "repo_path", description: "Path to the git repository"),
        ToolParameter(name: "title", description: "PR title"),
        ToolParameter(name: "body", description: "PR description/body"),
        ToolParameter(name: "base", description: "Base branch to merge into. Default 'main'.")
    ]
    let requiredParameters = ["repo_path", "title", "body"]
    let requiresConfirmation = true

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["repo_path"],
              let title = arguments["title"],
              let body = arguments["body"] else {
            return ToolResult(success: false, output: "Error: 'repo_path', 'title', and 'body' are required")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        let base = arguments["base"] ?? "main"

        // Check gh is available
        let ghCheck = await runShellCommand("which gh", workingDirectory: expanded, timeout: 5)
        if !ghCheck.success {
            return ToolResult(success: false, output: "Error: 'gh' CLI not found. Install it: brew install gh")
        }

        let escapedTitle = title.replacingOccurrences(of: "'", with: "'\\''")
        let escapedBody = body.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "gh pr create --title '\(escapedTitle)' --body '\(escapedBody)' --base \(base)"
        return await runShellCommand(cmd, workingDirectory: expanded, timeout: 30)
    }
}

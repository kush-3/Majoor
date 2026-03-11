// CommandSanitizer.swift
// Majoor — Shell Command Safety Layer
//
// Validates and sanitizes shell commands before execution.
// Blocks dangerous patterns, enforces directory boundaries.

import Foundation

nonisolated struct CommandSanitizer: Sendable {

    // Commands that are always blocked
    private static let blockedCommands: [String] = [
        "rm -rf /", "rm -rf /*", "rm -rf ~", "rm -rf ~/*",
        "sudo", "su ", "su\n",
        "mkfs", "dd if=", "format",
        "chmod -R 777 /", "chmod -R 777 ~",
        "chown -R", "> /dev/sda",
        ":(){ :|:& };:",  // fork bomb
        "wget http", "curl http",  // raw downloads (use web tools instead)
        "shutdown", "reboot", "halt",
        "launchctl unload", "killall Finder", "killall Dock",
        "defaults delete", "networksetup",
        "csrutil", "nvram",
    ]

    // Patterns matched via regex
    private static let blockedPatterns: [String] = [
        #"rm\s+-[a-zA-Z]*[rR][a-zA-Z]*[fF].*\s+/"#,   // rm -rf /...
        #">\s*/etc/"#,                                     // overwrite system config
        #">\s*/System/"#,
        #"chmod\s+777\s+/"#,
        #"pip\s+install\s+--user"#,                        // system-level installs need review
        #"npm\s+install\s+-g"#,
    ]

    // Directories the agent should never touch
    private static let offLimitsPaths: [String] = [
        "/System", "/Library", "/Applications",
        "/usr", "/bin", "/sbin", "/etc", "/var",
        "/private", "/dev", "/cores",
    ]

    private static let offLimitsHomePaths: [String] = [
        ".ssh", ".gnupg", ".aws", ".config/gcloud",
        ".kube", ".docker", "Library/Keychains",
    ]

    struct ValidationResult: Sendable {
        let isAllowed: Bool
        let reason: String?
    }

    static func validate(command: String) -> ValidationResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check blocked commands
        for blocked in blockedCommands {
            if trimmed.lowercased().contains(blocked.lowercased()) {
                return ValidationResult(isAllowed: false, reason: "Blocked command pattern: '\(blocked)'")
            }
        }

        // Check blocked regex patterns
        for pattern in blockedPatterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return ValidationResult(isAllowed: false, reason: "Command matches blocked pattern")
            }
        }

        // Check off-limits paths
        for path in offLimitsPaths {
            // Allow reading (cat, ls, head, etc.) but block writing/deleting
            let writePatterns = ["rm ", "mv ", "cp ", "> ", ">> ", "chmod ", "chown ", "touch ", "mkdir "]
            for wp in writePatterns {
                if trimmed.contains(wp) && trimmed.contains(path) {
                    return ValidationResult(isAllowed: false, reason: "Cannot modify system path: \(path)")
                }
            }
        }

        // Check off-limits home paths
        let home = NSHomeDirectory()
        for subpath in offLimitsHomePaths {
            let fullPath = (home as NSString).appendingPathComponent(subpath)
            if trimmed.contains(fullPath) || trimmed.contains("~/\(subpath)") {
                return ValidationResult(isAllowed: false, reason: "Cannot access sensitive path: ~/\(subpath)")
            }
        }

        return ValidationResult(isAllowed: true, reason: nil)
    }

    /// Check if a command is considered destructive (needs extra caution from the agent)
    static func isDestructive(command: String) -> Bool {
        let destructivePatterns = ["rm ", "rm\t", "rmdir", "git push", "git reset", "drop ", "delete ", "truncate "]
        let lower = command.lowercased()
        return destructivePatterns.contains { lower.contains($0) }
    }
}

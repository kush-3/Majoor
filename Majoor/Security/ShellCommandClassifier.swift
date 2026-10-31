// ShellCommandClassifier.swift
// Majoor — Shell Command Risk Classification
//
// CommandSanitizer decides what must never run. This classifier answers a
// different question, for the permission gate: does a shell command carry the
// same power as a tool that prompts for confirmation? `git push` through
// execute_shell is git_push; `rm` is delete_file; `./x.py` or `python3 x.py`
// is execute_script. Before this existed, execute_shell was a universal escape
// hatch around the whole sensitive set (found 2026-08-03, closed 2026-10-31).
//
// Scope: command-position analysis of each simple command in a list or
// pipeline, after unwrapping `env`, `xargs`, `nohup`, `exec`, variable
// assignments and system-bin paths. Quotes and backslashes are honored so
// `"r"m` and `r\m` resolve to rm. Environment variables and git config keys
// that change what a later command executes (GIT_SSH_COMMAND, PATH=., LD/DYLD
// injection, core.sshCommand, core.hooksPath, …) are flagged as well. This is
// not a full shell parser: anything it cannot see through (command
// substitution or a variable in command position) is flagged rather than
// ignored. Known, accepted gaps: `make <target>` and `npm run <script>` run
// project-defined code and are left prompt-free because flagging them would
// make routine development unusable.

import Foundation

nonisolated enum ShellCommandClassifier {

    nonisolated struct Verdict: Sendable {
        let isSensitive: Bool
        /// One human-readable reason per matched command, for the prompt body.
        let reasons: [String]
    }

    static let protectedBranches: Set<String> = ["main", "master", "develop", "production"]

    private static let interpreters: Set<String> = [
        "python", "python2", "python3", "node", "nodejs", "ruby", "perl", "deno", "bun",
        "uv", "uvx", "osascript", "php", "pwsh", "lua", "tclsh", "rscript",
    ]
    private static let awks: Set<String> = ["awk", "gawk", "mawk", "nawk"]
    private static let editors: Set<String> = ["vim", "vi", "nvim", "ex", "view", "emacs", "gvim", "mvim"]
    private static let shells: Set<String> = ["bash", "sh", "zsh", "fish", "dash", "ksh", "source", "."]
    private static let wrappers: Set<String> = [
        "env", "nohup", "time", "nice", "command", "builtin", "exec", "caffeinate", "timeout", "gtimeout", "stdbuf",
        "sudo", "doas",   // blocked by the sanitizer anyway; classified through for defense in depth
    ]
    /// Wrapper flags that consume the following token (`exec -a name`, `nice -n 5`, `env -u VAR`, `timeout -s SIG`).
    private static let wrapperValueFlags: Set<String> = [
        "-a", "-n", "-u", "-C", "-P", "-s", "-k", "--signal", "--kill-after", "--chdir", "--unset",
    ]
    private static let deleters: Set<String> = ["rm", "rmdir", "unlink", "shred", "srm", "trash"]
    private static let remoteExec: Set<String> = ["ssh", "scp", "sftp", "nc", "netcat", "ncat", "socat", "telnet"]
    private static let mailers: Set<String> = ["mail", "mailx", "sendmail", "msmtp"]
    private static let systemBinDirs = [
        "/bin/", "/usr/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "/sbin/", "/usr/sbin/", "/opt/local/bin/",
    ]
    /// Project build wrappers that live in the repo and are routine to run:
    /// `./gradlew build`, `./mvnw package`, `./configure`. Every other
    /// `./file` or `dir/file` in command position is "run this file".
    private static let buildWrappers: Set<String> = ["gradlew", "mvnw", "configure", "autogen.sh"]
    /// Subcommands of packaging tools that put something on the internet.
    private static let publishVerbs: [String: Set<String>] = [
        "npm": ["publish", "unpublish", "deprecate"], "pnpm": ["publish"], "yarn": ["publish"],
        "cargo": ["publish", "yank"], "twine": ["upload"], "gem": ["push", "yank"], "docker": ["push"],
        "poetry": ["publish"], "flit": ["publish"], "hatch": ["publish"],
    ]
    private static let ghReadVerbs: Set<String> = [
        "view", "list", "status", "diff", "checks", "clone", "search", "ls", "download", "verify",
        "checkout", "watch", "logs",
    ]
    /// Environment variables that change what a later command executes or
    /// where it reads its configuration from.
    private static let dangerousEnv: Set<String> = [
        "GIT_SSH", "GIT_SSH_COMMAND", "GIT_EXTERNAL_DIFF", "GIT_PAGER", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR",
        "GIT_PROXY_COMMAND", "GIT_ASKPASS", "GIT_DIR", "GIT_WORK_TREE",
        "LD_PRELOAD", "LD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
        "BASH_ENV", "ENV", "ZDOTDIR", "PROMPT_COMMAND", "SHELL", "HOME", "CDPATH", "IFS",
        "PYTHONSTARTUP", "PYTHONPATH", "PERL5OPT", "PERL5LIB", "RUBYOPT", "RUBYLIB", "NODE_OPTIONS",
        "EDITOR", "VISUAL", "PAGER",
    ]
    /// git config keys (prefixes) whose values are commands, or that redirect
    /// where code and pushes go.
    private static let dangerousGitKeyPrefixes = [
        "core.sshcommand", "core.fsmonitor", "core.pager", "core.editor", "core.hookspath", "core.gitproxy",
        "core.askpass", "uploadpack.", "receivepack.", "protocol.", "diff.external", "alias.", "credential.",
        "gpg.", "sequence.editor", "filter.", "http.proxy", "https.proxy", "url.", "remote.", "include.",
        "includeif.", "sendemail.", "ssh.variant", "mergetool.", "difftool.", "browser.", "man.", "pager.",
    ]
    private static let dangerousGitKeyFragments = [".textconv", ".driver", ".command", ".process", ".clean", ".smudge", ".cmd", ".path"]

    // MARK: - Public

    static func classify(_ command: String) -> Verdict {
        var reasons: [String] = []
        for segment in segments(of: command) {
            if let reason = classifyTokens(tokens(of: segment)), !reasons.contains(reason) {
                reasons.append(reason)
            }
        }
        return Verdict(isSensitive: !reasons.isEmpty, reasons: reasons)
    }

    /// Mirrors GitPushTool's protected-branch guard for pushes issued through
    /// the shell. Returns a block reason when any `git push` in the command
    /// targets a protected branch. `cd` segments are tracked so
    /// `cd repo && git push` resolves the current branch of the right repo;
    /// `sh -c '…'` is searched recursively; `--all`/`--mirror` count as every
    /// local branch.
    static func protectedPushViolation(in command: String, workingDirectory: String) async -> String? {
        var dir = workingDirectory
        for segment in segments(of: command) {
            let toks = unwrap(tokens(of: segment)).tokens
            guard let cmd = toks.first else { continue }
            let args = Array(toks.dropFirst())
            if cmd == "cd" {
                if let target = args.first(where: { !$0.hasPrefix("-") }) {
                    dir = resolve(target, relativeTo: dir)
                } else {
                    dir = NSHomeDirectory()
                }
                continue
            }
            if shells.contains(cmd.lowercased()), let inline = inlineScript(args) {
                if let violation = await protectedPushViolation(in: inline, workingDirectory: dir) { return violation }
                continue
            }
            guard cmd == "git" else { continue }

            var repoDir = dir
            var rest = args
            var sub: String? = nil
            while !rest.isEmpty {
                let a = rest.removeFirst()
                if a == "-C" {
                    if let p = rest.first { rest.removeFirst(); repoDir = resolve(p, relativeTo: repoDir) }
                    continue
                }
                if ["-c", "--git-dir", "--work-tree", "--namespace", "--config-env"].contains(a) {
                    if !rest.isEmpty { rest.removeFirst() }
                    continue
                }
                if a.hasPrefix("-") { continue }
                sub = a
                break
            }
            guard sub == "push" else { continue }

            if rest.contains(where: { ["--all", "--mirror", "--branches"].contains($0) }) {
                let r = await runShellCommand("git for-each-ref --format='%(refname:short)' refs/heads/", workingDirectory: repoDir, timeout: 5)
                let locals = r.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                if let hit = locals.first(where: { protectedBranches.contains($0) }) {
                    return "Cannot push to protected branch '\(hit)' (push --all/--mirror includes it)."
                }
                continue
            }

            var positional: [String] = []
            var i = 0
            while i < rest.count {
                let a = rest[i]
                if ["--repo", "-o", "--push-option", "--receive-pack", "--exec"].contains(a) { i += 2; continue }
                if a.hasPrefix("-") { i += 1; continue }
                positional.append(a)
                i += 1
            }
            let refspecs = Array(positional.dropFirst())   // the first positional is the remote
            var targets: [String] = []
            if refspecs.isEmpty {
                targets.append("HEAD")
            } else {
                for spec in refspecs {
                    var s = spec
                    if s.hasPrefix("+") { s.removeFirst() }
                    let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    let dst = parts.count == 2 ? String(parts[1]) : s
                    targets.append(dst.isEmpty ? String(parts[0]) : dst)
                }
            }
            for target in targets {
                var name = target.replacingOccurrences(of: "refs/heads/", with: "")
                if name == "HEAD" || name.isEmpty || name.hasPrefix("HEAD") {
                    let r = await runShellCommand("git branch --show-current", workingDirectory: repoDir, timeout: 5)
                    name = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if protectedBranches.contains(name) {
                    return "Cannot push to protected branch '\(name)'."
                }
            }
        }
        return nil
    }

    // MARK: - Segmenting

    /// Splits a command line into simple commands at `; & | ( ) newline` and
    /// backticks, honoring quotes and backslash escapes. A `$(` or backtick
    /// that opens in command position is emitted as the marker segment "$("
    /// so the classifier can flag "the command to run is computed at runtime".
    static func segments(of command: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character? = nil
        var escaped = false
        var inBacktick = false

        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { result.append(t) }
            current = ""
        }

        for ch in command {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && quote != "'" { current.append(ch); escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; current.append(ch); continue }
            if ch == "`" {
                let before = current.trimmingCharacters(in: .whitespaces)
                if !inBacktick && before.isEmpty { result.append("$(") }
                inBacktick.toggle()
                flush()
                continue
            }
            if ch == "(" {
                let before = current.trimmingCharacters(in: .whitespaces)
                if before == "$" {
                    current = ""
                    result.append("$(")
                } else if before.hasSuffix("$") {
                    // `echo $(…)`: substitution as an argument. The inner command
                    // still gets its own segment; the outer one loses the `$`.
                    current = String(before.dropLast())
                }
                flush()
                continue
            }
            if ";&|)\n".contains(ch) { flush(); continue }
            current.append(ch)
        }
        flush()
        return result
    }

    /// Whitespace-splits one simple command, stripping quotes and escapes so
    /// `"r"m` and `r\m` both become `rm`.
    static func tokens(of segment: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character? = nil
        var escaped = false
        var inToken = false
        for ch in segment {
            if escaped { current.append(ch); escaped = false; inToken = true; continue }
            if ch == "\\" && quote != "'" { escaped = true; inToken = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inToken = true; continue }
            if ch.isWhitespace {
                if inToken { result.append(current); current = ""; inToken = false }
                continue
            }
            current.append(ch)
            inToken = true
        }
        if inToken { result.append(current) }
        return result
    }

    // MARK: - Unwrapping

    private struct Unwrapped {
        var tokens: [String]
        /// Set when a stripped `VAR=value` prefix is itself a way to run code.
        var envReason: String?
    }

    /// Drops leading `VAR=value`, wrapper commands (with their flags and flag
    /// values), `env -S 'inline command'`, and `xargs [flags]` so the real
    /// command sits at index 0.
    private static func unwrap(_ input: [String]) -> Unwrapped {
        var toks = input
        var envReason: String? = nil
        var budget = 32   // the loop re-enters on `env -S`; never spin
        while let first = toks.first, budget > 0 {
            budget -= 1
            if isAssignment(first) {
                if envReason == nil { envReason = dangerousAssignmentReason(first) }
                toks.removeFirst()
                continue
            }
            let lower = first.lowercased()
            if wrappers.contains(lower) {
                toks.removeFirst()
                let takesNumber = (lower == "timeout" || lower == "gtimeout" || lower == "nice")
                var reentered = false
                while let f = toks.first, f.hasPrefix("-") || (takesNumber && Int(f) != nil) {
                    toks.removeFirst()
                    if lower == "env", f == "-S" || f == "--split-string" || (f.hasPrefix("-S") && f.count > 2) {
                        // `env -S 'python3 x.py'`: the value is a command line of its own
                        let inline = (f.hasPrefix("-S") && f.count > 2) ? String(f.dropFirst(2)) : (toks.isEmpty ? "" : toks.removeFirst())
                        toks = tokens(of: inline) + toks
                        reentered = true
                        break
                    }
                    if wrapperValueFlags.contains(f), !toks.isEmpty { toks.removeFirst() }
                }
                _ = reentered
                continue
            }
            if lower == "xargs" {
                toks.removeFirst()
                while let f = toks.first, f.hasPrefix("-") {
                    toks.removeFirst()
                    if ["-I", "-n", "-P", "-d", "-L", "-s", "-E"].contains(f), !toks.isEmpty { toks.removeFirst() }
                }
                continue
            }
            break
        }
        return Unwrapped(tokens: toks, envReason: envReason)
    }

    private static func isAssignment(_ tok: String) -> Bool {
        guard let eq = tok.firstIndex(of: "="), eq != tok.startIndex else { return false }
        let name = tok[..<eq]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !(name.first?.isNumber ?? true)
    }

    private static func dangerousAssignmentReason(_ tok: String) -> String? {
        guard let eq = tok.firstIndex(of: "=") else { return nil }
        let name = String(tok[..<eq])
        let value = String(tok[tok.index(after: eq)...])
        if name == "PATH" {
            // A relative or empty entry makes a planted file in the cwd runnable by its bare name.
            let entries = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let relative = entries.contains { $0.isEmpty || !($0.hasPrefix("/") || $0.hasPrefix("$") || $0.hasPrefix("~")) }
            return relative ? "PATH that includes a relative directory" : nil
        }
        if dangerousEnv.contains(name) || name.hasPrefix("GIT_CONFIG") || name.hasPrefix("DYLD_") || name.hasPrefix("LD_") {
            return "sets \(name), which changes what runs"
        }
        return nil
    }

    private static func resolve(_ path: String, relativeTo base: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : (base as NSString).appendingPathComponent(expanded)
    }

    /// For `sh -c '…'`, `bash -lc '…'`: the inline script, if any.
    private static func inlineScript(_ args: [String]) -> String? {
        guard let i = args.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }) else { return nil }
        return i + 1 < args.count ? args[i + 1] : ""
    }

    private static func isDangerousGitKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return dangerousGitKeyPrefixes.contains(where: { k.hasPrefix($0) })
            || dangerousGitKeyFragments.contains(where: { k.contains($0) })
    }

    // MARK: - Classification

    private static func classifyTokens(_ input: [String]) -> String? {
        let unwrapped = unwrap(input)
        if let reason = unwrapped.envReason { return reason }
        guard let cmd = unwrapped.tokens.first else { return nil }
        let args = Array(unwrapped.tokens.dropFirst())

        if cmd == "$(" { return "command chosen at runtime (command substitution)" }
        if cmd.hasPrefix("$") { return "command chosen at runtime (variable in command position)" }

        // Paths in command position: `./x`, `../x`, `~/x`, `/abs/x`, `dir/x`.
        // System bin directories are stripped and the basename judged again
        // (so `/usr/bin/env python3 x.py` unwraps to python3); anything else
        // is "run this file", which is execute_script, except project build
        // wrappers and node_modules/.bin tools.
        if cmd.contains("/") {
            if let dir = systemBinDirs.first(where: { cmd.hasPrefix($0) }) {
                let base = String(cmd.dropFirst(dir.count))
                if base.isEmpty || base.contains("/") { return "executes a file (\(cmd))" }
                return classifyTokens([base] + args)
            }
            let base = (cmd as NSString).lastPathComponent
            if buildWrappers.contains(base) || cmd.contains("node_modules/.bin/") { return nil }
            return "executes a file (\(cmd))"
        }

        let lower = cmd.lowercased()
        if interpreters.contains(lower) { return "runs \(cmd) code" }
        if shells.contains(lower) {
            // `sh -c '…'` / `bash -lc '…'`: the inline script is a command line
            // of its own and is classified recursively, so `bash -c 'rm x'` is
            // judged as `rm x`.
            if let inline = inlineScript(args) { return classify(inline).reasons.first }
            if args.contains(where: { !$0.hasPrefix("-") }) { return "runs a shell script via \(cmd)" }
            return nil
        }
        if awks.contains(lower) {
            let runs = args.contains { $0.contains("system(") || $0.contains("getline") || $0.contains("|") || $0 == "-f" || $0.hasPrefix("--file") }
            return runs ? "awk program that runs commands" : nil
        }
        if editors.contains(lower) {
            let runs = args.contains {
                $0.hasPrefix("-c") || $0.hasPrefix("+") || $0.hasPrefix("--cmd") || $0.hasPrefix("--eval") || $0 == "-S"
                    || $0.hasPrefix("-s") || $0 == "--batch" || $0 == "--script" || $0 == "-l" || $0 == "--load"
            }
            return runs ? "editor running commands (\(cmd))" : nil
        }
        if deleters.contains(lower) { return "deletes files (\(cmd))" }
        if lower == "find" && args.contains(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir"].contains($0) }) {
            return "find with -delete/-exec"
        }
        if lower == "git" { return classifyGit(args) }
        if lower == "gh" { return classifyGH(args) }
        if remoteExec.contains(lower) { return "talks to a remote host (\(cmd))" }
        if lower == "rsync" {
            if args.contains(where: { $0 == "-e" || $0.hasPrefix("--rsh") || $0.hasPrefix("--rsync-path") }) { return "rsync running a program" }
            if args.contains(where: { !$0.hasPrefix("-") && $0.contains(":") }) { return "rsync to a remote host" }
            return nil
        }
        if lower == "tar", args.contains(where: { $0.hasPrefix("--to-command") || $0.hasPrefix("--use-compress-program") || $0 == "-I" || $0.hasPrefix("--rsh-command") || $0.hasPrefix("--checkpoint-action") }) {
            return "tar running a program"
        }
        if mailers.contains(lower) { return "sends email (\(cmd))" }
        if lower == "curl" || lower == "wget" { return "talks to the internet directly (\(cmd)); fetch_webpage is the gated path" }
        if lower == "security" { return "reads or changes the Keychain" }
        if lower == "shortcuts", args.first == "run" { return "runs a Shortcut" }
        if lower == "crontab" && !args.contains("-l") { return "installs a cron job" }
        if lower == "launchctl", let sub = args.first(where: { !$0.hasPrefix("-") }),
           ["load", "unload", "bootstrap", "bootout", "submit", "enable", "disable", "kickstart"].contains(sub) {
            return "changes launchd jobs (launchctl \(sub))"
        }
        if let verbs = publishVerbs[lower], let sub = args.first(where: { !$0.hasPrefix("-") }), verbs.contains(sub) {
            return "publishes to a registry (\(cmd) \(sub))"
        }
        return nil
    }

    private static func classifyGit(_ args: [String]) -> String? {
        var rest = args
        var sub: String? = nil
        while !rest.isEmpty {
            let a = rest.removeFirst()
            if a == "-c" || a == "--config-env" {
                // `git -c core.sshCommand=… fetch` runs the value. Judge the key.
                if let kv = rest.first {
                    rest.removeFirst()
                    let key = String(kv.split(separator: "=", maxSplits: 1).first ?? "")
                    if isDangerousGitKey(key) { return "git -c \(key) (config that runs a command or redirects git)" }
                }
                continue
            }
            if a.hasPrefix("-c") && a.count > 2 && !a.hasPrefix("--") {
                let key = String(a.dropFirst(2).split(separator: "=", maxSplits: 1).first ?? "")
                if isDangerousGitKey(key) { return "git -c \(key) (config that runs a command or redirects git)" }
                continue
            }
            if ["-C", "--git-dir", "--work-tree", "--namespace"].contains(a) {
                if !rest.isEmpty { rest.removeFirst() }
                continue
            }
            if a.hasPrefix("-") { continue }
            sub = a
            break
        }
        guard let sub else { return nil }
        switch sub {
        case "push":
            if rest.contains(where: { $0 == "--delete" || $0 == "-d" || ($0.hasPrefix(":") && $0.count > 1) }) {
                return "git push that deletes a remote branch"
            }
            return "git push"
        case "config":
            let readFlags: Set<String> = ["--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l", "--show-origin", "--show-scope", "get", "list"]
            if rest.contains(where: { readFlags.contains($0) }) { return nil }
            if rest.contains(where: { $0 == "-e" || $0 == "--edit" }) { return "git config --edit (opens an editor)" }
            if let key = rest.first(where: { isDangerousGitKey($0) }) { return "git config \(key) (config that runs a command or redirects git)" }
            if rest.contains(where: { $0 == "--global" || $0 == "--system" }) { return "git config outside this repository" }
            return nil
        case "clean":
            return "git clean (deletes untracked files)"
        case "reset":
            return (rest.contains("--hard") || rest.contains("--merge")) ? "git reset --hard (discards changes)" : nil
        case "checkout":
            return (rest.contains("--") || rest.contains("-f") || rest.contains("--force")) ? "git checkout that discards changes" : nil
        case "restore":
            let stagedOnly = rest.contains("--staged") && !rest.contains("--worktree") && !rest.contains("-W")
            return stagedOnly ? nil : "git restore (discards working-tree changes)"
        case "branch":
            return (rest.contains("-D") || (rest.contains("--delete") && rest.contains("--force"))) ? "git branch -D" : nil
        case "stash":
            return (rest.first == "drop" || rest.first == "clear") ? "git stash \(rest.first ?? "")" : nil
        case "rm":
            return rest.contains("--cached") ? nil : "git rm (deletes files)"
        case "remote":
            return (rest.first == "remove" || rest.first == "rm" || rest.first == "set-url") ? "git remote \(rest.first ?? "")" : nil
        case "worktree":
            return rest.first == "remove" ? "git worktree remove" : nil
        case "difftool", "mergetool":
            return rest.contains(where: { $0 == "-x" || $0.hasPrefix("--extcmd") || $0 == "-t" || $0.hasPrefix("--tool") }) ? "git \(sub) running a program" : nil
        case "send-email":
            return "git send-email (sends email)"
        case "daemon", "instaweb":
            return "git \(sub) (starts a server)"
        case "filter-branch", "filter-repo", "replace":
            return "git history rewrite (\(sub))"
        default:
            return nil
        }
    }

    private static func classifyGH(_ args: [String]) -> String? {
        let positional = args.filter { !$0.hasPrefix("-") }
        guard let group = positional.first?.lowercased() else { return nil }
        let verb = positional.count > 1 ? positional[1].lowercased() : ""
        switch group {
        case "api":
            let mutating: Set<String> = ["POST", "PUT", "PATCH", "DELETE"]
            var i = 0
            while i < args.count {
                let a = args[i]
                if (a == "-X" || a == "--method"), i + 1 < args.count, mutating.contains(args[i + 1].uppercased()) {
                    return "gh api \(args[i + 1].uppercased())"
                }
                if a.hasPrefix("--method="), mutating.contains(String(a.dropFirst(9)).uppercased()) {
                    return "gh api \(String(a.dropFirst(9)).uppercased())"
                }
                if ["-f", "-F", "--field", "--raw-field", "--input"].contains(a)
                    || a.hasPrefix("--field=") || a.hasPrefix("--raw-field=") || a.hasPrefix("--input=") {
                    return "gh api with a request body"
                }
                i += 1
            }
            return nil
        case "auth":
            return verb == "status" ? nil : "gh auth \(verb)"
        case "extension", "ext":
            return ["install", "upgrade", "remove", "exec"].contains(verb) ? "gh extension \(verb)" : nil
        case "browse", "completion", "config", "help", "alias", "cache", "search", "status":
            return nil
        default:
            // pr, issue, release, repo, gist, secret, variable, workflow, run, label, project, ruleset, …
            return ghReadVerbs.contains(verb) ? nil : "gh \(group) \(verb)".trimmingCharacters(in: .whitespaces)
        }
    }
}

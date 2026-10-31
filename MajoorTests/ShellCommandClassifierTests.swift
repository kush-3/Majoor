// ShellCommandClassifierTests.swift
// MajoorTests — the permission gate's view of shell commands.
//
// Every "sensitive" case here is a command that reaches an action the
// dedicated tools would prompt for; several were found by adversarial
// review on 2026-10-31 and must stay flagged. Every "routine" case is a
// command developers run all day and must never prompt in Standard mode.

import Foundation
import Testing
@testable import Majoor

@Suite("ShellCommandClassifier")
struct ShellCommandClassifierTests {

    nonisolated static let sensitive: [String] = [
        // git push and friends
        "git push origin feature", "git -C ~/proj push", "cd proj && git push", "git push", "git push origin :feature",
        "git push --all origin", "bash -lc 'git push'", "git -c user.name=x push origin main",
        // deletions and discards
        "ls; rm -rf build", "rm file.txt", "echo hi | xargs rm", #"xargs -I {} sh -c "rm {}""#, "find . -name '*.log' -delete",
        #"find . -exec rm {} \;"#, "git clean -fd", "git reset --hard HEAD~1", "git checkout -- .", "git branch -D feature",
        "git restore file.txt", "git stash drop", "git rm file", "bash -c 'rm x'", "sudo rm x", #""r"m x"#, #"r\m x"#,
        // interpreters and script files
        "python3 script.py", "/usr/bin/python3 -m pytest", "./run.py", "~/bin/tool", "scripts/deploy.sh", "bash setup.sh",
        "sh <(curl x)", "source env.sh", ". ./env.sh", "FOO=1 env python3 x.py", "timeout 10 python3 x.py", "nohup node server.js &",
        "echo ok && /Users/kush/tmp/evil", "/usr/bin/env python3 x.py", "env -S 'python3 x.py'", "env -S'python3 x.py'",
        "exec -a innocent python3 x.py", "timeout -k 5 10 python3 x.py", "nice -n 5 ruby x.rb",
        #"osascript -e 'tell app "Mail" to activate'"#, #"awk 'BEGIN{system("id")}'"#, "vim -c ':!id'", "ex -sc '!id|q' f",
        #"emacs --batch --eval '(shell-command "id")'"#,
        // things the shell can do that no tool can
        "gh pr create --title x", "gh api -X POST repos/x/y/issues", "gh api --method=DELETE repos/x", "gh issue comment 3 -b hi",
        "gh extension install foo/bar", "npm publish", "ssh host 'ls'", "nc host 80", "curl -sL https://x", "wget -q https://x",
        "security find-generic-password -w", "crontab -e", "launchctl load x.plist", "mail -s hi a@b.c", #"shortcuts run "Send Message""#,
        "rsync -e 'sh -c id' a b", "rsync -a src host:dst", "tar -cf x --use-compress-program=id .",
        // indirection the classifier cannot see through
        "$(which rm) -rf x", "`rm x`", "$CMD arg", "PATH=. qax", "PATH=.:$PATH qax", "PATH= qax", "cd proj && env PATH=.:/bin build",
        // environment and git config that run code
        "git -c core.sshCommand='echo x' fetch origin", "git -ccore.sshCommand=x fetch", "GIT_SSH_COMMAND='echo x' git fetch origin",
        "git config core.hooksPath /tmp/h", "git -c protocol.ext.allow=always fetch ext::sh", "git config --global alias.co '!id'",
        "git config --global user.name x", "git config set core.pager id", "HOME=/tmp/evil git status", "DYLD_INSERT_LIBRARIES=x ls",
        "env -i GIT_SSH=x git fetch", "git difftool -x id", "git send-email x",
    ]

    nonisolated static let routine: [String] = [
        "ls -la", "git status", "git commit -m 'x'", "git log --format=%H", "git fetch origin", "git merge main", "git rebase main",
        "npm test", "npm install", "npm run build", "swift build", "make", "make test", "cmake --build .", "xcodebuild -scheme X build",
        "cat file.txt | grep foo", "gh pr list", "gh pr view 12", "gh api repos/x/y", "gh repo clone x/y", "gh pr checkout 4",
        "gh auth status", "gh run list", "git restore --staged file", "git checkout -b feature", "git checkout main", "git branch -d feature",
        "git remote -v", "git stash", "git rm --cached file", "git -C ~/proj status", "git config user.email x@y", "git config --get user.name",
        "git config --list", "git config -l", "git -c color.ui=false status", "git -c user.name=x commit -m y",
        "mkdir -p build && echo done", "echo $(date)", "echo `date`", "find . -name '*.swift'", "grep -r 'rm' .", "echo rm",
        #"echo "don't rm""#, "ls ~/Documents/rm", "/usr/bin/git status", "/usr/bin/env ls", "xargs -n 1 echo", "launchctl list", "crontab -l",
        "bash -c 'ls'", "docker build .", "env", "env FOO=1 ls", "time make", "timeout -k 5 10 ls", "nice -n 5 ls", "exec ls", "vim file.txt",
        "./gradlew build", "./mvnw package", "./configure --prefix=/x", "node_modules/.bin/jest", "awk '{print $1}' file",
        "cat f | awk '{print $2}'", "PATH=/usr/bin:/bin ls", "PATH=/opt/x:$PATH ls", "FOO=bar ls", "tar -czf x.tgz dir", "rsync -a src/ dst/",
    ]

    @Test("flags commands an equivalent tool would prompt for", arguments: sensitive)
    func flagsSensitive(command: String) {
        let verdict = ShellCommandClassifier.classify(command)
        #expect(verdict.isSensitive, "expected sensitive: \(command)")
    }

    @Test("leaves routine development commands alone", arguments: routine)
    func leavesRoutineAlone(command: String) {
        let verdict = ShellCommandClassifier.classify(command)
        #expect(!verdict.isSensitive, "false positive: \(command) -> \(verdict.reasons)")
    }

    @Test("explains why, for the confirmation prompt")
    func reasonsAreHumanReadable() {
        #expect(ShellCommandClassifier.classify("git push origin x").reasons == ["git push"])
        #expect(ShellCommandClassifier.classify("rm -rf build").reasons == ["deletes files (rm)"])
        #expect(ShellCommandClassifier.classify("ls").reasons.isEmpty)
    }

    @Test("protected-branch guard mirrors git_push, through cd, sh -c, env -S, --all and refspecs")
    func protectedBranchGuard() async throws {
        let repo = NSTemporaryDirectory() + "majoor-clsf-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let setup = await runShellCommand(
            "git init -q -b master . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git branch -q main && git checkout -q -b feature",
            workingDirectory: repo, timeout: 20)
        try #require(setup.success, "repo setup failed: \(setup.output)")

        let blocked: [String] = [
            "git push origin main", "git push origin feature:main", "git push -f origin HEAD:refs/heads/master",
            "git push --all origin", "git push --mirror origin", "bash -c 'git push origin main'", "env -S 'git push origin main'",
            "sh -c 'cd . && git push origin master'", "git -c user.name=x push origin main", "xargs git push origin main",
        ]
        let allowed: [String] = ["git push", "git push origin feature", "git push -u origin feature", "bash -c 'git push origin feature'"]
        for command in blocked {
            let violation = await ShellCommandClassifier.protectedPushViolation(in: command, workingDirectory: repo)
            #expect(violation != nil, "should block: \(command)")
        }
        for command in allowed {
            let violation = await ShellCommandClassifier.protectedPushViolation(in: command, workingDirectory: repo)
            #expect(violation == nil, "should allow: \(command) -> \(violation ?? "")")
        }
    }
}

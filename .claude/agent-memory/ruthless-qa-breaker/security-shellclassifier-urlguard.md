---
name: security-shellclassifier-urlguard
description: Attack surface notes for ShellCommandClassifier (Standard-mode shell gate), protectedPushViolation, and URLGuard (SSRF) — the recurring bypass classes and what's already solid.
metadata:
  type: project
---

The 2026-10-31 shell-gate + SSRF fixes. Re-run these attack classes on any change to
`Majoor/Security/ShellCommandClassifier.swift` or `URLGuard.swift`.

**ShellCommandClassifier — recurring bypass classes (all confirmed-running at the shell, classify()==not-sensitive):**
- *Command injected through a tool's own options, never in command position.* `git -c core.sshCommand='<cmd>' fetch`, `GIT_SSH_COMMAND='<cmd>' git fetch`, `git -c protocol.ext.allow=always fetch ext::sh -c <cmd>`, `git config core.hooksPath <dir>`. classifyGit only inspects the subcommand; the dangerous payload rides in options/env it skips.
- *Wrapper/assignment stripping that leaves a bare word.* `/usr/bin/env python3 x.py` (systemBinDir strip yields "env" but never re-unwraps), `env -S 'python3 x.py'`, `exec -a <name> python3 x.py` (the `-a` value is left as the "command"). unwrap() is the weak point.
- *Interpreters not in the `interpreters` set.* `awk/gawk 'BEGIN{system()}'`, `vim/vi/ex -c '!cmd'` / `ex -sc '!cmd|q'`, `emacs --batch --eval`. Any program with a shell-out escape.
- *Relative exec via PATH.* `PATH=. x` runs a planted cwd file (bare `cd dir; x` does NOT — zsh needs `./`).
- NOT bypasses in this env (verified): `{rm,x}` brace expansion (zsh won't expand in command position), bare word after cd.

**protectedPushViolation gaps (it's the UNCONDITIONAL protected-branch block, mirroring GitPushTool):**
- `git push --all` / `--mirror` push main while the guard resolves the current (non-protected) branch.
- `bash -c 'git push origin main'` — the guard uses segments() at top level and never recurses into `sh/bash -c` (classify() does, so it still prompts in Standard, but the hard block is defeated).

**URLGuard — solid; the design choice that makes it robust:** checkResolved() runs the same getaddrinfo CFNetwork uses, so alt-encodings (127.1, 0x7f000001, 2130706433, 0177.0.0.1) can't create a parser differential — both the guard and the connect see the same address. v4-mapped/NAT64/CGNAT/metadata/link-local all covered.
- Residual (low): IPv4-compatible IPv6 `::127.0.0.1`/`::7f00:1` and 6to4 `2002:7f00:1::` → isNonPublic=false (the `::ffff:` mapped form IS blocked — inconsistent). Deprecated/not-routed-to-loopback on macOS, so low practical risk.
- DNS rebinding between check and connect is acknowledged-residual by design (pinning would break TLS).

**False-positive cost in Standard mode:** every `./relative` or `dir/exe` classifies as "executes a file" → `./gradlew`, `./mvnw`, `./configure`, `./scripts/*.sh` all prompt. Asymmetric with execute_script(bash), which only prompts on sensitive *content*.

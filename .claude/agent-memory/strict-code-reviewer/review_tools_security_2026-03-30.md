---
name: Tools & Security Domain Review
description: Findings from reviewing all 34 tools, CommandSanitizer, and KeychainManager — shell injection, deadlock, path validation gaps
type: project
---

Reviewed ToolProtocol.swift, FileTools.swift, ShellTools.swift, GitTools.swift, WebTools.swift, CalendarTools.swift, EmailTools.swift, CommandSanitizer.swift, KeychainManager.swift on 2026-03-30.

**Critical findings:**
- Git tools interpolate unsanitized user input directly into shell commands (branch names, file paths, commit messages) — shell injection risk. Git tools never go through CommandSanitizer.
- `runShellCommand` has a deadlock: calls `waitUntilExit()` before reading pipe data. If child fills 64KB pipe buffer, both parent and child block.
- `WriteFileTool` (and Move/Copy/CreateDirectory) have zero path validation — can write to ~/.ssh, /etc, etc. CommandSanitizer only covers shell commands.
- `ExecuteScriptTool` bypasses CommandSanitizer by design (writes script to temp file).
- CommandSanitizer blocklist uses naive `contains` matching — false positives ("su " matches any string containing "su ") and trivially bypassable.
- `FetchMultipleURLsTool` uses `try!` which will crash on network errors.

**Why:** These are security and reliability issues in the tool execution layer — the primary interface between an LLM and the user's system.

**How to apply:** When reviewing changes to Tools/ or Security/, verify shell escaping on all interpolated arguments, check that file tools validate paths against sensitive directories, and ensure no force-unwraps in async tool execution paths.

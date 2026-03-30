---
name: Fix Session Review - Data Races, Security, FTS5
description: Review of fixes for data races (AgentLoop, AnthropicProvider), shell injection (GitTools), pipe deadlock (ShellTools), FTS5 rowid (DatabaseManager), MCP timeout leaks. Found new bugs in termination handler race, DateFormatter thread safety, FTS5 delete trigger missing rowid, git add still unsanitized.
type: project
---

Reviewed fix session on 2026-03-30 targeting issues from earlier code review rounds.

**Bugs found in the fixes:**
1. ShellTools `runShellCommand` — race between `isRunning` check and `terminationHandler` assignment can hang forever
2. FileTools/UsageStore cached `DateFormatter` statics are not thread-safe (used from nonisolated concurrent contexts)
3. FTS5 contentless delete trigger missing `rowid` — deletes/updates silently fail, index grows unboundedly
4. GitTools `git add \(files)` — files parameter still unsanitized (shellEscape applied to other args but not this one)

**Good patterns observed:**
- NSLock in AgentLoop never held across await — correct discipline
- Actor isolation fix via parameter passing (steps param) instead of cross-isolation access
- shellEscape uses proper POSIX single-quote wrapping
- MCP timeout tasks properly cancelled on response arrival

**How to apply:** These are recurring patterns — DateFormatter thread safety and "fixed some but not all injection sites" are common in this codebase. Future reviews should specifically check for both.

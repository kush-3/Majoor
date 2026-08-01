---
name: review-permission-modes-2026-08-01
description: Second-pass permission-modes review — confirmation registration race vs denyAll, pre-normalization policy args, extensionless interpreter bypass, await-covered isolation warnings
metadata:
  type: project
---

Second-pass review of the permission-modes feature (PermissionMode.swift + AgentLoop confirmation gate). Findings that generalize:

**Why:** this codebase's confirmation flow suspends a `CheckedContinuation` with no cancellation handler, and the permission gate now runs an async Haiku judge BEFORE registering the continuation — any "drain pending confirmations" mechanism (denyAll) races with registration.

**How to apply — recurring traps to re-check in future reviews:**
- `ConfirmationManager.requestConfirmation` registers its continuation only when suspension happens; anything that resolves/denies "all pending" (denyAll on stop) misses a request that is still upstream (e.g. inside the Auto-mode judge call). Check `Task.isCancelled` both before registering and after resuming, before `tool.execute`.
- `handleToolCalls` iterates a batch with NO cancellation check between calls — a denied/stopped confirmation `continue`s into executing sibling tools. FileManager/EKEventStore tools are synchronous and ignore Task cancellation (URLSession-based ones self-cancel).
- Any policy/gate that inspects `call.arguments` runs BEFORE `normalizeArguments` — LLM alias keys ("cmd" → "command") bypass argument-inspecting gates while the tool still executes. Normalize first, then gate.
- Interpreter-detection regexes anchored on file extensions are bypassable (python/node run extensionless files); CommandSanitizer separately blocks `-c`/`-e` and pipe-to-interpreter, but not `-m`, `./x.py`, `uv/deno/bun/perl/osascript`.
- Swift isolation-warning quirk (Swift 5 mode + SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor): MainActor statics accessed INSIDE an awaited call expression produce no warning; hoisting the same access into a plain `let` binding produces one. This is why the category-routing refactor added 3 warnings and pipelineApproved removal removed 1. Fix pattern: mark immutable `static let` String constants `nonisolated`.
- xcodebuild duplicates identical diagnostics nondeterministically across batches — always compare warning sets `sort -u` by unique (file, message), never raw counts. Also: first build attempt against a "fresh" derivedDataPath was silently incremental (34 vs 245 SwiftCompile lines) — verify SwiftCompile count before trusting a warning tally.
- MCP tool-name read-only heuristics must be checked against ~/.majoor/mcp_tool_cache.json: Slack (`slack_*`) and Notion (`API-*`) verbs are prefixed, so `hasPrefix("get_")`-style checks match 0 of their 30 tools.

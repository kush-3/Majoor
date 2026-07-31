---
name: audit-adaptive-thinking-roundtrip-2026-07-31
description: Concurrency audit of the adaptive-thinking round-trip + MCP/AppDelegate hygiene change — patterns validated correct, do not re-flag
metadata:
  type: project
---

Audited the uncommitted adaptive-thinking round-trip (Models/LLMProvider/AnthropicProvider/
AgentLoop/ChatManager) plus MCP + AppDelegate hygiene on 2026-07-31. **Zero data races,
deadlocks, or continuation leaks found.**

**Validated correct — do not re-flag:**
- `LLMResponse.toolCalls/.mixed` carrying `rawContent: [AnthropicContentBlock]` is fully
  value-typed. `AnthropicContentBlock` is `nonisolated ... Sendable`; its only non-trivial
  member is `[String: AnyCodable]?`, and `AnyCodable.value` is `any Sendable` holding only
  Bool/Int/Double/String/nested-AnyCodable. No reference smuggled across domains.
- Adding `var thinking/signature/data` to `AnthropicContentBlock` keeps the memberwise init
  source-compatible: `var` optionals get an implicit `nil` default (the `let` fields above
  them do not), and they are declared last so the existing 7-arg call order is unchanged.
- `AgentLoop.handleToolCalls(assistantContent:)` echoing response blocks verbatim keeps
  tool_use ↔ tool_result 1:1 (every parsed `ToolCall` appends exactly one tool_result,
  including the user-declined path). `rawContent` never enters `MainActor.run` or the
  lock-protected `conversationHistory` (which stores strings only).
- Streaming path ignores `thinking_delta` (only `text_delta` is handled) and returns
  `.text`; ChatManager has no tool loop, so no signature round-trip is required there.
- `Task.detached` → `MemoryStore.shared.archiveOld()` at launch: safe. `_ = DatabaseManager.shared`
  runs synchronously on MainActor first, and `static let` singletons are `swift_once`-guarded,
  so `dbQueue` cannot be observed half-initialized even if that line were removed.
  `MajoorLogger` is `nonisolated` over `os.Logger` statics — safe from a detached task.

**Known remaining hazard (pre-existing, not introduced):** two concurrent
`MCPServerManager.startServer(name:)` calls for the same server can each install a client
into `clients[name]`; the loser is dropped from the dict without `shutdown()`, orphaning its
child process, and its health-monitor Task is replaced without being cancelled. Reachable
when the crash-restart monitor fires while the user clicks Start/Restart in Settings.
Fix shape if it ever bites: an in-flight `Set<String>` guard at the top of `startServer`.

**How to apply:** these are settled — spend audit budget elsewhere. The isolation map in the
brief held exactly as documented; see [[project-isolation-enforcement]] for why a green
build is not evidence.

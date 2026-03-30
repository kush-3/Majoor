---
name: Full codebase review post-redesign
description: Bugs found in ChatManager cancel flow and FTS5 rowid mismatch; concurrency model validated as correct
type: project
---

Full codebase review completed 2026-03-30 after UI redesign + fix session.

**Bugs found:**
1. ChatManager.cancelStreaming() race: after cancel, the catch block appends spurious "Error: cancelled" message. Fix: guard Task.isCancelled in catch.
2. FTS5 contentless rowid mismatch: insert trigger doesn't pin rowid to memories.rowid, so delete trigger's old.rowid targets wrong FTS5 entry. Fix: explicitly set rowid on insert.

**Validated as correct:**
- NSLock on AgentLoop.conversationHistory
- stateLock on AnthropicProvider apiKey + circuit breaker
- terminationHandler set after pipe reads (Foundation does call retroactively)
- MCPClient failAllPending covers EOF + shutdown
- ConfirmationManager actor with CheckedContinuation
- shellEscape applied to all user inputs in GitTools
- MainActor non-reentrancy prevents cancelStreaming race with catch block's MainActor.run

**Why:** Comprehensive audit requested by user after multiple rounds of fixes in one day.
**How to apply:** These two bugs should be fixed in the next commit. Monitor FTS5 for stale search results in the meantime.

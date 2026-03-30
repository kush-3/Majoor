---
name: Infrastructure Review Findings (2026-03-30)
description: Key issues found in Majoor infrastructure layer — FTS5 rowid bug, MCP timeout leak, cost calc inaccuracy, @unchecked Sendable patterns
type: project
---

Reviewed 16 infrastructure files. Key findings:

- **FTS5 rowid instability**: `memories` table uses TEXT primary key but FTS5 content table references implicit `rowid` which is unstable across VACUUM. Needs migration to fix.
- **MCP timeout task leak**: Each JSON-RPC request creates a 30s timeout Task that's never cancelled on success. Pending dict should track timeout tasks.
- **Cost estimation inaccuracy**: `TaskPersistence.saveTask` uses averaged input/output rate (single `tokens` param). Opus output is 5x input — averaging is wildly off.
- **@unchecked Sendable pattern**: 8+ classes use this. Most are justified (hold only thread-safe DatabaseQueue or use NSLock). Pattern is correct but undocumented.
- **N+1 memory touches**: `MemoryRetriever.relevantContext` does N individual write transactions to touch memories. Should batch.
- **MCP stderr handler captures actor self**: Should capture `serverName` locally instead.
- **DateFormatter allocated per call** in `UsageStore.formatDate`.
- **Memory extraction is brittle**: `contains("remember")` matches mid-sentence. Should anchor to prefix.

**Why:** These are latent correctness/performance bugs that compound with usage growth.
**How to apply:** Reference these when reviewing changes to DB, MCP, or memory systems. FTS5 and timeout leak are highest priority fixes.

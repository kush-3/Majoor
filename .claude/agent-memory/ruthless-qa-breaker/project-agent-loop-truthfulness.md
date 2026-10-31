---
name: agent-loop-truthfulness-workstream
description: The 2026-08 "truthful loop" change to how Majoor decides a task succeeded — what it closed, and the false-success scenarios that survive it.
metadata:
  type: project
---

Stage 1 of the truthful-loop design (`TRUTHFUL-LOOP.md`, local-only) shipped 2026-08-03: `.truncated`
added to `LLMResponse`, a single `fail()` exit, max-iterations throws instead of completing, and the
provider stops fabricating text on `stop_reason: max_tokens`.

**Why:** fire-and-forget task mode means a false "Task Complete" is never caught by the user — the
menu-bar check and the persisted SQLite row are the only signal, and both were optimistic.

**How to apply:** when reviewing anything that decides task outcome, re-run these attacks. Ones 1–2
and 4–5 still land against the shipped code.

1. **Cheerful failure** — every tool fails, the model narrates it in a clean `end_turn`, task records
   as success. `ToolResult.success` still isn't consulted at the decision point. Accepted by design.
2. **Polite refusal as normal text** — structurally identical to real success; needs tool-failure
   counts surfaced, not more `stop_reason` plumbing.
3. **Cancel race at the success write** — CLOSED. The liveness check now sits *inside* the same
   `MainActor.run` hop that writes `.completed` and persists, so `stopRunningTask` cannot interleave.
   Any future refactor that splits that hop reopens it.
4. **Salvaged-partial completion** (new) — a `max_tokens` cut stashes text in `truncatedPrefix`; if
   the continuation turn returns text-free content (thinking-only, or empty), the prefix alone
   satisfies the non-empty-answer guard and a cut-off draft is filed as the completed answer. Guard
   the *current* turn's text, not the concatenation.
5. **Pipeline denial** (still open) — user declines the plan, model asks "what would you like
   instead?", that clean `end_turn` completes the task green. The app has `confirmResult.approved ==
   false` in scope and doesn't use it.

Also re-check on any outcome change: the pipeline step verdict still string-sniffs tool output
(`hasPrefix("error")`), which matches neither MCP failures nor `Exit code: N`; and `fail()` writes
status without token/model attribution, so failed rows persist 0 tokens / "" model / $0 cost while
`UsageStore` totals stay correct — the two tables disagree.

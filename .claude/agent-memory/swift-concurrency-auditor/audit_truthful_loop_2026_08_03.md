---
name: audit-truthful-loop-2026-08-03
description: Truthful-loop audit — AgentLoop has TWO failure-write paths, not one; AppDelegate's catch-arm mapping decides whether a stop reads as "stopped" or "incomplete"
metadata:
  type: project
---

Auditing the truthful-completion change (`TRUTHFUL-LOOP.md` stage 1, 2026-08-03) surfaced two
structural facts that keep mattering and are easy to re-derive wrong.

**1. `AgentLoop.execute()` has two independent failure writers.** The new `fail()` helper is
documented as "the one place a run becomes `.failed`", but the pre-existing `do/catch` around
`provider.complete` (`Core/AgentLoop.swift`, the `catch let error as LLMError` / bare `catch`
pair) writes `.failed` + `persistTask` itself and never calls `fail()`. Any claim of the form
"all failures go through X" in this file must be checked against that catch as well.

**Why:** the transport catch predates `fail()` and sets `tokensUsed`/`modelUsed` (which `fail()`
does not), so it can't simply be deleted — the two paths are complementary, not redundant.

**How to apply:** when a change adds a terminal path, verify it against *both* writers, and check
which one lands last on the cancel path (the loop's MainActor hop is enqueued after
`AppDelegate.stopRunningTask` finishes, so the loop wins ties).

**2. The error type thrown out of `execute()` selects the user-visible outcome.**
`AppDelegate.handleCommand`'s catch arms map: `CancellationError` → `.idle` + "Task Stopped";
`LLMError.incomplete` → `.attention` + "Task Incomplete" + forced `showPanel()`; any other
`LLMError` → `.error` + "Task Failed"; anything else → generic error with
`error.localizedDescription` persisted as the task summary. `.attention` has no revert timer
(unlike `.success`), so it sticks until the next task starts.

**How to apply:** picking the thrown type is a UX decision, not just a plumbing one. Throwing
`LLMError.incomplete(reason: .cancelled)` for a user Stop silently reclassifies it from
"stopped" to "incomplete".

**Verified this session (language semantics, not project code):** `MainActor.run`'s body runs in
the *enclosing task's* context — `Task.isCancelled` read inside it reflects that task, which is
what makes the check-and-write-in-one-hop cancel-race fix sound. `await MainActor.run` is also
not a cancellation-throwing suspension point, so a `fail()`-style helper still completes its
write after the task is cancelled.

Isolation premise re-checked and still true: [[project-isolation-enforcement]] (`SWIFT_VERSION = 5.0`).

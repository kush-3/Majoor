---
name: review-freeze-fix-2026-08-01
description: Second-pass review of the memory-freeze fix (CappedPipeCapture, trim recovery, read_file size guard) — what held up and what gaps remain
metadata:
  type: project
---

Reviewed the second pass of the 7-9GB freeze fix (ShellTools CappedPipeCapture, AgentLoop trim strategy 2, FileTools size guard, AnthropicProvider overflow pattern).

**Validated as correct** (don't re-flag): CappedPipeCapture's finished-gate makes finishReading single-shot; drain closure captures only the FileHandle (capture object releasable; daemon leak = 1 FD + handle + closure, eofGroup still balanced via settle); `Data(suffix)` copy is real (ContiguousBytes path). Trim strategy 1 livelock guard (`> 500 + marker.count`) is exact and monotonic. Strategy 2 `return false` unreachable at count ≥ 5 given the loop's strict alternation.

**Gaps found (2026-08-01, check if fixed):**
1. Trim branch 1 mis-fires on pipeline-without-seeded-history: `[u_task, a_plan, u_approval, ...]` is structurally identical to a seeded-history front pair, so removeFirst(2) deletes task+plan and anchors on the synthetic approval. Clean fix: track seeded `historyPairCount` from execute() and only allow branch 1 while > 0.
2. read_file FIFO/non-regular file: st_size 0 passes the 5MB guard, then String(contentsOfFile:) open() blocks forever (no per-tool timeout in handleToolCalls). Fix: require `.type == .typeRegular` from the same attributesOfItem call.
3. settle() inserts "[... middle of output omitted ...]" even when droppedBytes == 0 (output 512KB–1.5MB, head/tail contiguous).

**Why:** these are the residual doors back into the hang/goal-loss bug class this fix targets.
**How to apply:** when reviewing AgentLoop trim or tool-execution changes, re-check synthetic pipeline messages are distinguishable from seeded history, and that no tool can block indefinitely (there is still no per-tool timeout).

**Recurring pattern to watch:** truncation caps are layered inconsistently — read_file caps at 50k chars but the loop caps tool results at 30k (head/tail splice), so tool-level caps above 30k are dead letters. See [[review-full-codebase-2026-03-30]].

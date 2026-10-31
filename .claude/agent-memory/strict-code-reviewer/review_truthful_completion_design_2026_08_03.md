---
name: review-truthful-completion-design-2026-08-03
description: Judged 4 designs for the "agent loop lies about success" bug; verified Swift compile facts (definite-init in loops, memberwise-init optional-var defaults) and the exact tool_use/tool_result 400 trap all but one design missed.
metadata:
  type: project
---

Judged four competing designs for the AgentLoop false-success bug (fabricated
`max_tokens` recovery in AnthropicProvider + unguarded `.completed` write).
Winner: the "Truthful Terminal States" design (new `LLMResponse.truncated` case +
`fail()` + effort ladder), grafted with the id-filtering fix from the
"Honest Provider Boundary" design.

**Why:** the smallest change that makes truncated tool calls *structurally*
unable to reach `handleToolCalls`, closes the stop-race with one
`Task.checkCancellation()`, and needs no GRDB migration / no new `TaskStatus` /
no UI file.

**How to apply:** when reviewing any future truncation-recovery or
outcome-status work in this repo, check these five things first — they are the
ones designs got wrong:

1. **`parseResponse` silently drops `tool_use` blocks missing `id` or `name`**
   (`AnthropicProvider.swift:357-376`), but `rawContent` still contains them.
   Echoing `rawContent` verbatim and building `tool_result`s from the parsed
   `[ToolCall]` array leaves an unanswered `tool_use` → guaranteed HTTP 400
   (`Each 'tool_use' block must have a corresponding 'tool_result'`). Filter
   `rawContent` to `$0.type != "tool_use" || $0.id != nil` and derive result ids
   from what survives.
2. **`AppDelegate.stopRunningTask` (`:225`) writes `.failed` in memory and never
   persists**, and can be overwritten back to `.completed` by a late response.
   Either delete that write (single-writer) or guard the `.completed` write with
   `try Task.checkCancellation()`. Doing neither leaves the false-success path open.
3. **`.text("")` and `stop_reason == "refusal"` with partial text** are two
   separate false-success paths. An emptiness guard alone does not cover a
   mid-output refusal.
4. **Widening `LLMProvider.complete`'s return tuple touches 3 call sites**, not 2:
   `AgentLoop:186`, `ModelRouter:91`, `PermissionMode:106` (+ `ChatManager:67`
   for `stream`). An additive protocol method with a default impl avoids all of it.
5. **Cancellation is currently misclassified**: `CancellationError` from
   `URLSession.data` falls into the generic `catch` at `AnthropicProvider.swift:138`,
   is wrapped as `.networkError`, and is **retried 3× with backoff**. A
   `catch is CancellationError { throw CancellationError() }` as the *first*
   catch clause fixes it.

**Verified Swift facts (tested with `swiftc -emit-sil`, not `-typecheck` — DI is
a SIL pass and `-typecheck` does not run it):**
- `let x: T` declared before a loop and assigned on every `break`-ing path **does**
  compile; a path that breaks without assigning is a hard error
  (`constant 'x' used before being initialized`). So definite-initialization is a
  real compiler-enforced mechanism for "every exit must set an outcome".
- Adding `var isError: Bool?` **last** in `AnthropicContentBlock` keeps every
  existing memberwise call site compiling (optional `var`s get an implicit `nil`
  default), and callers may skip the intervening `thinking`/`signature`/`data`
  labels as long as argument order is preserved. `encodeIfPresent` omits nil.
- `throw await someAsyncFn()`, `continue <label>` from inside a `catch` inside the
  labeled loop, and multi-pattern `case .a(_, let t), .b(let t)` bindings all compile.

**Verified API facts (claude-api skill, not memory):** `output_config.effort` is
GA, no beta header, `low|medium|high|xhigh|max` — and it **errors on Haiku 4.5**,
so any effort-ladder code must guard the classifier/consent-check provider.
`stop_details` is populated only when `stop_reason == "refusal"`. Assistant prefill
is a 400 on Claude 5 models, so a cut-off turn can only be re-elicited, never resumed.

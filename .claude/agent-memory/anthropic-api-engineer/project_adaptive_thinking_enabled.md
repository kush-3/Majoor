---
name: adaptive-thinking-enabled
description: Adaptive thinking is now ON for Majoor's Claude 5 models — the thinkingOverride disable workaround was removed, superseding the "thinking must be disabled" invariant in the agent definition
metadata:
  type: project
---

Majoor now sends **no `thinking` field at all**, so `claude-opus-5` / `claude-sonnet-5`
run adaptive thinking. The `thinkingOverride` disable workaround in
`AnthropicProvider`, and the `AnthropicThinkingConfig` type + `AnthropicRequest.thinking`
field, were all removed (NEXT-FIXES.md item 4, done 2026-07-31).

**Why:** the override existed only because `AgentLoop.handleToolCalls` rebuilt assistant
turns from parsed text + tool calls, dropping thinking blocks — which the API 400s
mid-tool-loop. That blocker is gone: the loop now echoes `response.content` verbatim as
the assistant turn, and `AnthropicContentBlock` round-trips `thinking` / `signature` /
`data` losslessly.

**How to apply:**
- **This supersedes the "Thinking is explicitly disabled on Claude 5-family models"
  invariant in the anthropic-api-engineer agent definition.** That invariant's own
  stated prerequisite ("until the loop echoes raw response content blocks verbatim")
  is now met. Do not re-add a disable override on the strength of the old wording —
  verify against the code first.
- Two system-prompt rules that were disabled-thinking mitigations (plain-text tool
  calls, thinking-tag leakage) were deleted from `AgentLoop` at the same time. Do not
  reintroduce them; on Opus 5 those failure modes are specific to thinking being *off*,
  and a "don't reason" style instruction actively worsens tag leakage.
- If thinking ever must be turned off again, the correct lever is a low/medium
  `output_config.effort`, not `thinking: {type: "disabled"}` — and disabled thinking
  400s on Opus 5 above `high` effort anyway.

Related: [[maxtokens-thinking-truncation]]

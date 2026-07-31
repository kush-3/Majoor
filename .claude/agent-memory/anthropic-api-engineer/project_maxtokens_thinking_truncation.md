---
name: maxtokens-thinking-truncation
description: maxTokens 16384 now covers thinking + output tokens together, raising truncation risk on the non-streaming agent-loop path
metadata:
  type: project
---

`AnthropicProvider.maxTokens` (16384) is a ceiling on **thinking + response text
combined**, not response text alone. Since adaptive thinking went on
([[adaptive-thinking-enabled]]), the effective budget for visible output shrank by
however much the model decides to think.

**Why it matters here:** the non-streaming `complete()` path has a truncation-recovery
branch — when `stop_reason == "max_tokens"` and tool_use blocks are present, it abandons
the tool calls and returns a "breaking this into smaller steps" text response, which
*ends the task*. Thinking makes that branch more reachable, and it fails soft (task looks
completed) rather than loud.

**How to apply:** if users report agent tasks ending early with a "breaking into smaller
steps" summary, this is the first thing to check — look for `⚠️ Response truncated
(max_tokens)` in the logs before suspecting anything else. `maxTokens` cannot simply be
raised: >~16K on non-streaming risks HTTP timeouts (invariant 6), so the real fix is
either moving the agent loop to the streaming path or lowering effort.

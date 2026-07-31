---
name: review-model-refresh-2026-07-31
description: Claude 5 model refresh + Sparkle release pipeline review — version-grep reads Debug config, thinking override validated correct
metadata:
  type: project
---

Review of the claude-opus-5/sonnet-5/haiku-4-5 migration + Sparkle appcast pipeline (uncommitted, 2026-07-31).

**Key finding (unfixed at review time):** `Scripts/build-dmg.sh:30` extracts `MARKETING_VERSION` via `grep | head -1`, which reads the **Debug** config (pbxproj line ~291) while the script builds **Release** (line ~340). The two configs had already drifted once (Release 1.0.0/3 vs Debug 1.0.1/2). If drift recurs, the DMG filename and `--download-url-prefix .../v$VERSION/` diverge from the version generate_appcast stamps from the Release bundle → Sparkle enclosure URL 404s.

**Validated correct (do not re-flag):**
- `AnthropicProvider.thinkingOverride` sending `thinking: {"type":"disabled"}` for claude-opus-5/sonnet-5 prefixes is the right call: those models default to adaptive thinking, and AgentLoop rebuilds assistant turns without thinking blocks (400s mid-tool-loop). Disabled-at-default-effort(high) is accepted per API rules. Concurrency-safe: reads only immutable `let model`.
- AgentLoop system prompt rules #14/#15 are verbatim the Anthropic-documented mitigations for disabled-thinking failure modes (plain-text tool calls, `<thinking>` tag leakage). Rule 15's generic wording (not naming thinking tags) is intentionally correct — naming the tags is documented as less effective.
- Synthesized Codable on AnthropicRequest omits nil `thinking` via encodeIfPresent; wire shape verified.
- CostConfig $5/$25 (Opus 5), $3/$15 (Sonnet 5), $1/$5 (Haiku 4.5) match published pricing. Note: Sonnet 5 intro pricing $2/$10 runs through 2026-08-31.

**Why:** future 6-family model bumps will silently deactivate `thinkingOverride` (hasPrefix on 5-family literals) — the tool-loop 400s would return.
**How to apply:** when reviewing the next model migration in this repo, check thinkingOverride's prefix gate and the build-dmg.sh version extraction first.

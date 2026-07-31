---
name: majoor-doc-drift-patterns
description: Where Majoor's CLAUDE.md/README have drifted historically and how to verify each claim fast
metadata:
  type: project
---

CLAUDE.md has two overlapping sections: a concise spec (top, ends around the first "# CLAUDE.md — Majoor"
heading) and a much longer near-duplicate spec below it. Every factual claim in the short section is
repeated in the long section in different prose/formatting. When fixing drift, both copies must be
found and edited — grep for the number/string, don't assume one hit means done.

**Why:** the file has been edited inconsistently before (fixed in one copy, not the other), which is
exactly the kind of silent drift this audit exists to catch.

**How to apply:** after any correction, `grep -n` the old (wrong) value across CLAUDE.md and README.md
to confirm zero remaining hits before finishing.

## Verified ground-truth locations (as of 2026-07-31, repo at commit range through 18716af + uncommitted changes)

- Tool count: count array literal in `ToolRegistry.defaultTools()` in `Majoor/Tools/ToolProtocol.swift`
  — was 34, is now 35 (added one tool between sessions). Cross-check with
  `grep -rn ": AgentTool" Majoor/Tools/ | wc -l` to confirm registry matches conformances.
- `maxIterations` in `Majoor/Core/AgentLoop.swift` — was 25, is now 75. This number appears 3x in
  CLAUDE.md (concise bullet, duplicate-section pipeline list, duplicate-section "LLM Loop" block).
- Dependencies: `Majoor.xcodeproj/project.pbxproj` `XCRemoteSwiftPackageReference` entries — GRDB.swift
  (SQLite ORM) has been joined by Sparkle 2 (auto-updates, added for the Sparkle pipeline work). Exact
  resolved versions live in `Majoor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  (GRDB 7.10.0, Sparkle 2.9.0 as of this audit) — the pbxproj itself only pins minimum versions
  (`upToNextMajorVersion`), so cite Package.resolved for the exact patch version, not pbxproj.
- `APIConfig.swift` (repo root has `Majoor/APIConfig.swift`, gitignored, NOT tracked by git — confirmed
  via `git ls-files`): Anthropic + Tavily keys are Keychain-backed (`KeychainManager`), resolved with
  `?? ""` (no hardcoded fallback). Only `appGoogleClientId`/`appGoogleClientSecret` are hardcoded
  app-level fallbacks for Gmail OAuth. A `APIConfig.swift.example` template exists at repo root;
  README already documented the `cp` step before this audit — CLAUDE.md did not, so it was the one
  needing the fix.
- `Majoor/Core/Router/ModelRouter.swift` + `TaskClassifier.swift`: routing is hybrid, not a pure
  category→model table. `TaskCategory.modelTier` gives a keyword-fast-path mapping (only
  opus/sonnet, never haiku) used when `TaskClassifier.classifyWithConfidence` score ≥ 2
  (`confidenceThreshold` in TaskClassifier.swift). Below that threshold, `ModelRouter.classifyWithLLM`
  fires a Haiku-model call (`haikuModel`, NOT sonnet — despite a stale header comment in
  ModelRouter.swift itself claiming "Sonnet LLM classifies ambiguous inputs" — that's a code-comment
  bug, out of scope for a docs-only audit, flagged to the user instead of silently trusted).
- TaskClassifier.swift keyword count: counted 79 keywords across 8 patterns/categories (coding 17,
  codeReview 8, git-ops→coding 5, webResearchDeep 8, webResearchQuick 8, emailCalendar 15,
  fileManagement 10, summarization 8). Doc claim "72+ keywords across 8 categories" remains true
  (79 ≥ 72) — left unedited, but re-verify the exact count next time rather than trusting this note,
  since it will drift as keywords are added.
- `conversationTimeoutSeconds` in AgentLoop.swift = 600s = 10 minutes — matches doc, unedited.
- DB: `Majoor/Core/Database/DatabaseManager.swift` — path and three tables (memories, tasks,
  usageStats) still accurate; there's also an FTS5 virtual table `memories_fts` but that's an
  implementation detail, not one of the "three tables" the docs describe to users.
- File org: actual top-level dirs under `Majoor/` are `Core/, Tools/, UI/, Settings/, Security/,
  Utils/` (plus Assets.xcassets and loose top-level files). No `Models/` or `Services/` — CLAUDE.md's
  "File Organization" tree (in the duplicate long section only — the short section has no tree) still
  had the old `Models/`/`Services/` names; fixed.
- Settings tabs: `Majoor/Settings/SettingsView.swift` TabView has exactly 6 tabs (General, Accounts,
  Integrations, Memory, Usage, About). README's architecture-tree comment said "7-tab" — this was
  drift NOT on the user's known list; found independently by reading the actual TabView body instead
  of trusting the doc comment.
- MCP known-servers list (`Majoor/Settings/MCPSettingsView.swift` `knownServers`) — names match docs
  (github, slack, linear, notion). Per-server tool counts (26/8/22/5) are NOT hardcoded anywhere in
  the app; they're discovered live via `client.listTools()` at connection time. Left the doc numbers
  unedited since nothing in-repo contradicts them and they describe external MCP servers' surface
  area, not Majoor's own code — but flag to the user that these numbers are not independently
  verifiable from this repo and will silently drift if the external servers change.
- Adaptive thinking (added same session as this audit): `AnthropicRequest` sends no `thinking` field
  (see comment in `Majoor/Core/Models.swift` line ~10) — opus-5/sonnet-5 run adaptive thinking by
  default. `AgentLoop.handleToolCalls` echoes `assistantContent: [AnthropicContentBlock]` verbatim
  (not rebuilt from parsed text/tool-calls) so `thinking`/`redacted_thinking` blocks + signatures
  survive the tool loop, per `AnthropicContentBlock`'s comment in Models.swift (~line 63-70). CLAUDE.md
  didn't previously mention this in its Agent-Loop/LLM-Loop steps at all (not a false claim, just a
  gap) — added a short clause rather than a new section, per the user's minimal-diff instruction.

## Process note

RELEASING.md was explicitly out of scope unless something in it was wrong. Checked it against
`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in pbxproj (1.0.2 / build 4) — RELEASING.md's example
version numbers and "Auto-update works from 1.0.2 (build 4) onward" note are consistent with current
pbxproj state, so it was left untouched. [[majoor-project-state]]

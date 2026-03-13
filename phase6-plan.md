# Phase 6 — Polish & Launch Prep

**Goal:** Production-ready quality, onboarding experience, pipeline UX polish, and distribution-ready app. Phase 6 transforms Majoor from a working prototype into a shippable product.

**Branch:** `kush/phase-6-implementation`

---

## Implementation Status

### 6C — Error Handling & Recovery: COMPLETE
**Implementation order was: 6C → 6A → 6B → 6D → 6E → 6F**

**Files modified (7):**
- `Core/LLMProvider.swift` — Added `noInternet`, `contextOverflow`, `serverOverloaded` error cases. Added `isTransient` and `shouldOpenSettings` computed properties for error classification.
- `Core/AnthropicProvider.swift` — Network errors now classify via `URLError.code`: `.notConnectedToInternet` → `LLMError.noInternet` (fail fast), `.timedOut` → retry with backoff. 400 errors detect context overflow by parsing error message for "too many tokens"/"context length". 529 → `serverOverloaded`. Rate limit logging improved with retry-after header.
- `Core/AgentLoop.swift` — Context overflow recovery: on `.contextOverflow`, calls `trimConversationForRecovery()` which first truncates tool_result blocks to 500 chars, then removes oldest user+assistant message pairs. Auth errors (`.invalidAPIKey`) fail immediately without retry. All errors produce clean `errorDescription` messages.
- `Core/MCP/MCPServerManager.swift` — Crash recovery now uses exponential backoff (5s, 10s, 20s, 40s, 80s) with max 5 restarts. After max restarts, sends notification "X Integration Failed" and stops retrying. Health check interval changed from 10s to 30s. Recovery is silent (no "recovered" notification) — only permanent failure notifies user.
- `Core/MCP/MCPToolBridge.swift` — Detects 401/403/auth errors in MCP tool results and returns user-friendly messages: "GitHub: authentication failed. Your token may have expired. Update it in Settings > Integrations."
- `UI/StatusBarController.swift` — Error state persists until user clicks the icon (no more 3s auto-dismiss). All states have tooltip messages. Added `errorMessage` property and `currentState` tracking. Click on error icon → acknowledges and returns to idle.
- `Core/NotificationManager.swift` — New `AUTH_ERROR` category with "Open Settings" action button. New `majoorOpenSettings` notification name. New `actionOpenSettings` action ID. Settings window opens when user taps the action.
- `AppDelegate.swift` — `handleLLMError()` method provides specific notifications per error type. Auth errors use `AUTH_ERROR` category (with "Open Settings" button). Transient errors (rate limit, overloaded, network) say "retried multiple times" to indicate recovery was attempted. Listens for `majoorOpenSettings` notification.

**Key design decisions:**
- Only notify user when recovery fails or user action is needed (auth errors, no internet)
- Silent retry for transient errors (429, 529, network timeout) — AnthropicProvider handles internally
- Silent MCP crash recovery with backoff — only notify if max restarts exceeded
- Context overflow: trim silently, only notify if trimming can't save it

### 6A — Onboarding Flow: COMPLETE

**New files (2):**
- `UI/Onboarding/OnboardingView.swift` (~310 LOC) — 5-step wizard: Welcome → API Key → Integrations → Permissions → Ready. API key validation via real Haiku API call. Paste from clipboard button. Optional Tavily key in disclosure group. Calendar permission request via EventKit. Summary screen showing what's connected. Progress dots at bottom. 500x400 non-resizable window.
- `UI/Onboarding/OnboardingStepViews.swift` (~160 LOC) — `IntegrationCard` reusable component. Token input with save/skip per service. Extra credential support (e.g. Slack Team ID). Connects to MCP server on save and shows tool count. Used by onboarding.

**Files modified (4):**
- `APIConfig.swift` — Full rewrite. All keys (Anthropic, Tavily, Google OAuth client ID/secret) now resolve via Keychain first, hardcoded fallback second. Added keychain key constants (`majoor_anthropic_api_key`, etc.), `save*()` methods, and `hasUser*` computed properties. Original hardcoded values moved to private `hardcoded*` constants.
- `AppDelegate.swift` — Checks `UserDefaults.bool(forKey: "hasCompletedOnboarding")` on launch; shows onboarding window if false. Added `showOnboarding()` method (creates 500x400 NSWindow). Removed stale `KeychainManager.shared.deleteAPIKey(for: .anthropic)` call. Added `onboardingWindow` property.
- `Settings/MCPSettingsView.swift` — `defaultConfig(for:)` renamed to `static func defaultServerConfig(for:)` so `IntegrationCard` in onboarding can also use it. Internal callers updated to `Self.defaultServerConfig(for:)`.
- `Settings/SettingsView.swift` — Added "Run Setup Wizard" button in General tab that calls `AppDelegate.showOnboarding()`. Version string updated from "0.4.0 — Phase 4" to "0.6.0 — Phase 6".

**Key design decisions:**
- All API keys migrate to Keychain with hardcoded fallback (makes app distributable)
- Onboarding re-runnable from Settings > General > "Run Setup Wizard"
- API key validated with minimal Haiku API call (1 token, cost ~$0.0001)
- MCP tokens: saved to Keychain → server started → tool count shown within 3s timeout

### 6B — Pipeline Progress UI + Inline Plan Editing + Smart Router: COMPLETE

**Pipeline Progress UI (rewrite):**
- `Core/Models.swift` — Added `PipelineStep` struct (with `planDescription`, `status`, `toolCalls`, `result`, `error`, `enabled`) and `PipelineStepStatus` enum (pending/running/completed/failed/skipped). `enabled` field supports inline step toggling.
- `Core/TaskManager.swift` — Added `@Published pipelineSteps: [PipelineStep]`, `@Published pipelineStartTime: Date?`. New methods: `setPipelineSteps()`, `updatePipelineStep(at:status:result:error:)`, `addToolCallToPipelineStep(at:toolName:)`, `togglePipelineStep(at:)`. `clearPipelinePlan()` now also resets steps and start time.
- `UI/PipelineProgressView.swift` — Full rewrite (~180 LOC). Observes `taskManager.pipelineSteps` via `@EnvironmentObject`. Shows per-step icons (circle.dashed → ProgressView spinner → checkmark.circle.fill/xmark.circle.fill). Result text and errors shown inline. Footer shows "Step X of Y" with live elapsed timer using `TimelineView`. Overall status icon in header (green check, orange warning, or spinner).

**Inline Plan Editing (remove-only):**
- `UI/MainPanelView.swift` — `PipelinePlanView` rewritten. Shows numbered steps with toggle buttons (checkmark.circle.fill when enabled, circle when disabled). Disabled steps show strikethrough text. Footer says "Toggle steps to skip. Approve via notification." Shows "X/Y steps" count in header.
- `Core/AgentLoop.swift` — When pipeline approved, checks `taskManager.pipelineSteps` for disabled entries. Tells LLM "User approved but wants to SKIP step(s): X, Y. Execute the remaining steps only." Marks skipped steps as `.skipped` in UI.

**Pipeline Step Matching (AgentLoop):**
- `parsePipelineSteps(from:)` — Extracts numbered lines (`1. Do X`, `1) Do X`) and bulleted lines (`- Do X`) from plan text into `PipelineStep` objects.
- `matchToolToPipelineStep(_:arguments:)` — Multi-tier matching: (1) already-running step with same tool, (2) keyword-to-tool mapping table (`stepToolMapping` with 18 keyword→tool_prefix entries), (3) direct tool name match in description, (4) single pending step shortcut, (5) first pending step (sequential fallback).
- `stepToolMapping` covers: commit, push, pr/pull request, issue/ticket, slack/post/message, notion/page, email, calendar, branch, merge, status, diff.
- Tool calls update matched step to `.running`, tool results update to `.completed` or `.failed` (based on output starting with "Error").

**Hybrid Smart Router:**
- `Core/Router/TaskClassifier.swift` — Added `classifyWithConfidence()` returning `(category, score)`. `confidenceThreshold = 2`. Added `isConfident()` and `detectMentionedServices()` (scans for "github", "slack", "linear", "notion" keywords). Git heuristic now returns score >= 3 for confident routing.
- `Core/Router/ModelRouter.swift` — New `routeHybrid()` method: keywords handle obvious cases (score >= 2) → returns provider + tool sets. Ambiguous inputs (score < 2) → calls `classifyWithLLM()` which asks Haiku to return `{"model": "opus|sonnet|haiku", "tools": ["local", ...]}`. `defaultToolSets()` maps categories to MCP server names (coding → github, general with "finished"/"done" language → all services). Uses Haiku (not Sonnet) for classification to minimize cost.
- `Core/AgentLoop.swift` — `execute()` now calls `ModelRouter.routeHybrid()` instead of keyword-only `TaskClassifier.classify()` + `ModelRouter.provider()`. Filters MCP tools by the `toolSets` array from routing, reducing tokens sent per API call.

### 6D — Performance & Battery Optimization: COMPLETE

**Files modified (6):**
- `Core/MCP/MCPServerManager.swift` — Removed `loadConfigs()`, idle timeout monitor, `recordToolCall()`, and `lastToolCallTime` tracking. Servers start eagerly via `startAll()` on launch and stay running. `ensureRunning(_:)` kept as safety net for mid-session crash recovery. `serverSummary()` reverted to only show running servers. `configuredServerNames()` still available.
- `Core/MCP/MCPToolBridge.swift` — `executeWithRawJSON()` calls `ensureRunning()` as a safety net (restarts crashed servers before tool calls). Removed `recordToolCall()` call.
- `Core/AgentLoop.swift` — Conversation history capped at 5 entries (was unlimited within 10-min window). Response text truncated to 1000 chars (was 2000). Tool summaries capped at 10 per entry. Both storage points (normal completion + max iterations) updated.
- `AppDelegate.swift` — `startAll()` on launch (eager start). `willSleepNotification` stops all MCP servers. `didWakeNotification` restarts all MCP servers immediately.
- `Core/Memory/MemoryRetriever.swift` — Added `MemoryRetrievalCache` (thread-safe, NSLock, 60s TTL, max 20 entries). `relevantContext()` checks cache first before querying SQLite. Cache key is normalized (lowercase + trimmed). Stale entries evicted when cache exceeds 20 entries.
- `UI/StatusBarController.swift` — Added `observePowerState()`: stops pulse timer on system sleep (no wasted CPU), re-starts it on wake if still in `.working` state.

**Key design decisions:**
- Eager start: all configured servers start on app launch, stay running until sleep/quit
- `ensureRunning()` kept as safety net — if a server crashes mid-session, it auto-restarts before the next tool call
- Power-aware: sleep stops all servers, wake restarts all servers immediately
- No idle timeout — servers stay on while the app is active
- Conversation history: 5 entries × 1000 chars + 10 tool summaries ≈ bounded memory footprint
- Memory retrieval cache: 60s TTL avoids redundant SQLite queries for rapid sequential tasks
- Status bar animation: stops on sleep, avoids timer ticks when system is suspended
### 6E — App Notarization & Distribution: COMPLETE

**New files (1):**
- `Scripts/build-dmg.sh` — Single script for build + sign + notarize + staple. Auto-detects version and team ID from pbxproj. `--notarize` flag triggers notarization (requires `APPLE_ID` and `APP_PASSWORD` env vars). Without the flag, produces an unsigned DMG. Outputs to `dist/Majoor-X.Y.Z.dmg`.

**Modified files (4):**
- `Majoor/Majoor.entitlements` — Added `cs.allow-unsigned-executable-memory` (for shell/Process execution), `cs.disable-library-validation` (for MCP server subprocesses), `network.client` (for API calls). Calendar entitlement was already present.
- `Majoor.xcodeproj/project.pbxproj` — `MARKETING_VERSION` updated to 0.6.0 (both Debug and Release). `RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY` and `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION` set to YES (matches entitlements). Hardened runtime was already enabled.
- `Majoor/Info.plist` — Added `CFBundleShortVersionString` (= `$(MARKETING_VERSION)`) and `CFBundleVersion` (= `$(CURRENT_PROJECT_VERSION)`) so version is readable at runtime.
- `Majoor/Settings/SettingsView.swift` — About tab now reads version from `Bundle.main.infoDictionary` instead of hardcoded string. Shows "Version X.Y.Z (build)" format.

**Key design decisions:**
- Single script (`build-dmg.sh`) handles the full pipeline — no separate notarize.sh needed
- Notarization is opt-in via `--notarize` flag so local dev builds are fast
- Version and team ID auto-extracted from pbxproj — no manual config needed
- Entitlements match what the app actually needs: shell execution, MCP subprocesses, network, calendar
### 6F — Auto-Update Mechanism: COMPLETE

**New dependency:**
- Sparkle 2.9.0 via SPM (`https://github.com/sparkle-project/Sparkle`, upToNextMajorVersion from 2.0.0)

**New files (1):**
- `Core/UpdateManager.swift` — `ObservableObject` wrapper around `SPUStandardUpdaterController`. Publishes `canCheckForUpdates` via Combine. Exposes `checkForUpdates()`, `automaticallyChecksForUpdates` get/set, and `lastUpdateCheckDate`. Sparkle starts automatically on init.

**Modified files (4):**
- `Majoor.xcodeproj/project.pbxproj` — Added Sparkle SPM package reference, build file, framework link, and product dependency. Now 2 dependencies: GRDB + Sparkle.
- `Majoor/Info.plist` — Added `SUFeedURL` pointing to `https://kush-3.github.io/majoor-releases/appcast.xml` (GitHub Pages appcast).
- `Majoor/AppDelegate.swift` — Added `updateManager = UpdateManager()` property. Sparkle initializes on app launch.
- `Majoor/Settings/SettingsView.swift` — General tab: added "Updates" section with "Automatically check for updates" toggle (syncs with Sparkle's setting) and "Check for Updates" button with last-checked timestamp. Reads `UpdateManager` from AppDelegate.

**Key design decisions:**
- Sparkle 2.x (standard macOS update framework) — handles download, verification, and installation
- Appcast hosted on GitHub Pages (`kush-3/majoor-releases`) — free, simple, version-controlled
- Auto-check enabled by default, togglable in Settings
- SUFeedURL in Info.plist (Sparkle's standard config location)

---

## Resolved Open Questions

1. **Apple Developer Program** — User likely has it; 6E/6F will be implemented but deferred if cert not available.
2. **Tool subset filtering** — Implemented as part of 6B hybrid router. Keyword detection + LLM fallback for ambiguous cases. No new TaskClassifier categories needed.
3. **Onboarding re-entry** — Yes, "Run Setup Wizard" button added in Settings > General.
4. **MCP idle timeout** — Fixed at 10 minutes (not configurable). To be implemented in 6D.
5. **Pipeline step editing** — Implemented as remove-only toggle in 6B. Users can disable steps before approving. No add/reorder.

---

## What's Carrying Over from Phase 5

**Pipeline Progress View (5D)** was deprioritized during Phase 5 to focus on getting all 4 MCP servers working. The current `PipelineProgressView.swift` exists but needs refinement — it maps `TaskStep` entries to visual pipeline steps but lacks the polished UX originally planned (per-step status icons, step grouping by plan item, retry on failure). This is folded into 6B below.

---

## Sub-phases & File Plan

### 6A — Onboarding Flow (First-Run Setup Wizard)

**Goal:** A new user opens Majoor for the first time and is guided through API key setup, MCP token configuration, and permission grants — without touching config files or Terminal.

**New files:**
- `Majoor/UI/Onboarding/OnboardingView.swift` — Root onboarding container with step navigation
- `Majoor/UI/Onboarding/OnboardingStepViews.swift` — Individual step views (welcome, API key, integrations, permissions, done)

**Modified files:**
- `Majoor/AppDelegate.swift` — Check `UserDefaults.hasCompletedOnboarding` on launch; show onboarding window if false
- `Majoor/Settings/MCPSettingsView.swift` — Extract token-input logic into a reusable component that onboarding can also use

**Onboarding Steps:**

| Step | Screen | What Happens |
|------|--------|-------------|
| 1 | **Welcome** | App name, one-line description, "Get Started" button |
| 2 | **Anthropic API Key** | Text field + paste button. Validates key with a test API call (lightweight `messages` request). Shows green checkmark on success. Link to Anthropic Console to create a key. |
| 3 | **Integrations (optional)** | Cards for GitHub, Slack, Linear, Notion. Each has a token field + "Skip" option. Only GitHub is recommended; others say "Set up later in Settings." For Slack, show both Bot Token and Team ID fields. |
| 4 | **Permissions** | Request Calendar access (EventKit). Show current status with "Grant Access" button. Explain why it's needed. Skip if already granted. |
| 5 | **Ready** | Summary of what's connected. "Open Majoor" button. Sets `hasCompletedOnboarding = true`. |

**Design notes:**
- Window size: 500x400, centered, non-resizable
- Each step has Back/Next navigation (except step 1 which only has Next)
- Steps 3 and 4 are skippable — the app works with just an API key
- Progress dots at the bottom showing current step
- The onboarding window is a standard `NSWindow`, not the floating panel

**Validation behavior:**
- API key: Make a minimal API call (`model: "claude-haiku-4-5-20251001"`, `max_tokens: 1`, `messages: [{"role": "user", "content": "hi"}]`). If 200, show checkmark. If 401, show "Invalid key." If network error, show "Can't reach API — check your connection."
- MCP tokens: Save to Keychain, start the server, check if tools are discovered within 10s. Show tool count on success.

---

### 6B — Pipeline Progress UI (Carried from Phase 5D)

**Goal:** When a pipeline is executing, show a clear, real-time progress view with per-step status instead of a flat list of tool calls.

**Modified files:**
- `Majoor/UI/PipelineProgressView.swift` — Rewrite with proper step tracking
- `Majoor/UI/MainPanelView.swift` — Integrate improved progress view
- `Majoor/Core/Models.swift` — Add `PipelineStep` model

**PipelineStep model:**
```swift
struct PipelineStep: Identifiable, Sendable {
    let id = UUID()
    let planDescription: String    // "Create PR 'Add auth' on kush/majoor"
    var status: PipelineStepStatus // pending → running → completed → failed → skipped
    var toolCalls: [String]        // Tool names used for this step
    var result: String?            // Brief result text
    var error: String?             // Error if failed
}

enum PipelineStepStatus: Sendable {
    case pending, running, completed, failed, skipped
}
```

**How it works:**

1. When the agent loop detects `%%PIPELINE_CONFIRM%%`, it parses the numbered plan text into `PipelineStep` objects (one per numbered item)
2. Steps are stored on `TaskManager` as `@Published var pipelineSteps: [PipelineStep]`
3. As the agent loop processes tool calls, it matches tool names to plan steps and updates their status
4. `PipelineProgressView` observes `pipelineSteps` and renders them

**UI layout:**
```
┌─────────────────────────────────────────┐
│  Pipeline: "I just finished auth"       │
│                                         │
│  ✅ 1. Commit & push changes            │
│     └─ Pushed 3 files to agent/auth     │
│                                         │
│  🔄 2. Create PR on GitHub              │
│     └─ Creating PR...                   │
│                                         │
│  ⏳ 3. Move ticket to "In Review"       │
│                                         │
│  ⏳ 4. Post update in #engineering      │
│                                         │
│  ─────────────────────────────────────  │
│  Step 2 of 4 · 12s elapsed             │
└─────────────────────────────────────────┘
```

**Status icons:**
- ⏳ `circle.dashed` (SF Symbol) — Pending (gray)
- 🔄 `arrow.trianglehead.2.counterclockwise` with rotation animation — Running (blue)
- ✅ `checkmark.circle.fill` — Completed (green)
- ❌ `xmark.circle.fill` — Failed (red)
- ⏭️ `forward.circle` — Skipped (orange)

**Step matching heuristic:**
The agent loop doesn't explicitly label which plan step a tool call belongs to. Use keyword matching between the plan step text and the tool name/arguments:
- Plan says "Create PR" + tool is `github__create_pull_request` → match
- Plan says "Move ticket" + tool is `linear__update_issue` → match
- Plan says "Post in #engineering" + tool is `slack__slack_post_message` → match

Store a mapping of common keywords → tool name prefixes:
```swift
let stepToolMapping: [String: [String]] = [
    "commit": ["git_commit"],
    "push": ["git_push"],
    "pr": ["github__create_pull_request", "git_create_pr"],
    "issue": ["linear__create_issue", "linear__update_issue", "github__create_issue"],
    "slack": ["slack__"],
    "notion": ["notion__"],
    "email": ["send_email", "draft_email"],
    "calendar": ["create_calendar_event", "update_calendar_event"],
]
```

**Failure handling:**
- If a step fails, show the error inline and mark it red
- The pipeline continues — one failed step doesn't abort the rest (the LLM decides how to handle it)
- At the end, show a summary: "3/4 steps completed. Slack notification failed: channel not found."

---

### 6C — Error Handling & Recovery

**Goal:** Consistent, user-friendly error handling across the app. No silent failures, no cryptic error messages.

**Modified files:**
- `Majoor/Core/AgentLoop.swift` — Structured error recovery
- `Majoor/Core/MCP/MCPServerManager.swift` — Server crash recovery with user notification
- `Majoor/Core/AnthropicProvider.swift` — Better error classification
- `Majoor/UI/StatusBarController.swift` — Error state improvements
- `Majoor/Core/NotificationManager.swift` — Error notification actions

**Error categories and handling:**

| Error | Current Behavior | Target Behavior |
|-------|-----------------|-----------------|
| API key invalid (401) | Notification "Invalid API key" | Notification with "Open Settings" action button that opens the Models tab |
| Rate limited (429) | Retries with backoff, may timeout | Show "Rate limited, retrying..." in status bar tooltip. If all retries fail, notification with estimated wait time |
| Network timeout | Generic "Network error" | Distinguish WiFi-off vs API-slow. "No internet connection" vs "API is slow, retrying..." |
| MCP server crash | Silent restart in background | Notification: "GitHub integration restarted" if it recovers, or "GitHub integration failed — check Settings" if it doesn't |
| MCP tool 401/403 | Raw error in tool result | Agent gets clean error: "GitHub: authentication failed. Your token may have expired. Update it in Settings > Integrations." |
| Task fails mid-pipeline | Pipeline aborts, error in activity feed | Show which step failed in PipelineProgressView, continue remaining steps, summary at end |
| Keychain access denied | Silent failure | Alert explaining Keychain access is required, with link to System Settings > Privacy |

**Status bar error states:**
- Current: Icon turns red for 3 seconds on error, then back to idle
- Target: Icon turns red and stays until user acknowledges (clicks the icon). Tooltip shows the error. Clicking opens the panel with error details.

**Agent loop recovery improvements:**
```
Current flow:
  API error → retry 3x → throw → task marked failed → done

Target flow:
  API error → classify error type
    → transient (429, 529, network): retry with appropriate backoff
    → auth (401): fail fast, notify with "Open Settings" action
    → context too large (400 + "max tokens"): auto-summarize conversation history, retry
    → unknown: retry once, then fail with clean message
```

**Context overflow recovery:**
When the conversation history + tools + system prompt exceeds the model's context window, the API returns a 400 error. Currently this crashes the task. Instead:
1. Detect the 400 with a message containing "too many tokens" or similar
2. Trim the oldest conversation history entries
3. If still too large, summarize tool results (keep first 500 chars instead of full output)
4. Retry the API call
5. If still failing, notify user: "This task got too complex. Try breaking it into smaller steps."

---

### 6D — Performance & Battery Optimization

**Goal:** Majoor should be invisible when idle — zero CPU, minimal memory, no battery drain.

**Modified files:**
- `Majoor/Core/MCP/MCPServerManager.swift` — Lazy server startup
- `Majoor/Core/MCP/MCPClient.swift` — Idle timeout
- `Majoor/Core/AgentLoop.swift` — Conversation history memory management
- `Majoor/AppDelegate.swift` — Power state awareness

**Optimizations:**

| Area | Current | Target |
|------|---------|--------|
| MCP servers | All start on app launch, run forever | Start on first use per-server. Idle timeout: shut down after 10 min of no tool calls. Auto-restart on next use. |
| MCP health monitor | Polls every 10s per server | Poll every 30s. Stop polling for servers with no recent activity. |
| Conversation history | Kept in memory for 10 min | Same, but also cap at 5 entries (not just time-based). Each entry stores max 1000 chars of response text. |
| Memory retrieval | SQLite query on every task | Cache recent queries for 60s. If the same user input pattern repeats, reuse cached result. |
| Status bar animation | Continuous pulse when working | Use `CADisplayLink`-free animation. Stop animation callback when not visible. |
| Tool schemas | All 61+ tool JSON schemas sent every API call | For tasks classified as `general` or `email`, only send relevant tool subsets. Code tasks get all tools. |

**Lazy MCP server startup:**
```swift
// MCPServerManager changes:
// Instead of startAll() on launch, track which servers have been used

func ensureRunning(_ serverName: String) async throws {
    if let client = clients[serverName], await client.isRunning {
        return // Already running
    }
    guard let config = configs[serverName] else {
        throw MCPError.notConfigured(serverName)
    }
    await startServer(name: serverName, config: config)
}

// MCPToolBridge.execute calls ensureRunning before callTool
```

**Tool subset filtering:**
The system prompt already tells Claude about MCP tools. To reduce token usage, only include MCP tool schemas when the task category suggests they're needed:

| Task Category | Tools Sent |
|--------------|-----------|
| `general` | Local tools only (34) |
| `coding` | Local tools + GitHub MCP |
| `email` | Local tools + email tools only |
| `calendar` | Local tools + calendar tools only |
| `research` | Local tools + web tools only |
| `project` | All tools (local + all MCP) |
| When user explicitly mentions a service | Add that service's MCP tools |

This reduces the average tool count from 61+ to ~35-40, saving ~3000-5000 input tokens per API call.

**Power state awareness:**
```swift
// AppDelegate: listen for power state changes
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.willSleepNotification, ...
) { _ in
    // Gracefully stop MCP servers before sleep
    Task { await MCPServerManager.shared.stopAll() }
}

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, ...
) { _ in
    // Don't restart servers immediately — wait for first command
    // Just log that we're awake
}
```

---

### 6E — App Notarization & Distribution

**Goal:** Ship Majoor as a notarized DMG that users can download and run without Gatekeeper warnings.

**New files:**
- `Scripts/build-dmg.sh` — Build, sign, notarize, and package into DMG
- `Scripts/notarize.sh` — Apple notarization submission and stapling

**Modified files:**
- `Majoor/Majoor.entitlements` — Add hardened runtime entitlements
- `Majoor.xcodeproj` — Code signing configuration

**Requirements:**
1. **Apple Developer ID certificate** — "Developer ID Application" certificate (requires paid Apple Developer Program membership, $99/year)
2. **Hardened Runtime** — Required for notarization. Enable in Xcode: Signing & Capabilities → Hardened Runtime
3. **Entitlements for hardened runtime:**

```xml
<!-- Required for shell/Process execution (sandbox is already disabled) -->
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<true/>
<!-- Required for MCP server subprocesses -->
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
<!-- Required for EventKit calendar access -->
<key>com.apple.security.personal-information.calendars</key>
<true/>
```

**Build & distribute script (`Scripts/build-dmg.sh`):**
```bash
#!/bin/bash
set -euo pipefail

VERSION="0.6.0"
APP_NAME="Majoor"
TEAM_ID="<your-team-id>"
SIGNING_ID="Developer ID Application: <your-name> ($TEAM_ID)"

# 1. Clean build
xcodebuild clean build \
  -project Majoor.xcodeproj \
  -scheme Majoor \
  -configuration Release \
  CODE_SIGN_IDENTITY="$SIGNING_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"

# 2. Create DMG
BUILD_DIR="$(xcodebuild -showBuildSettings | grep BUILD_DIR | awk '{print $3}')"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$BUILD_DIR/Release/$APP_NAME.app" \
  -ov -format UDZO \
  "dist/$APP_NAME-$VERSION.dmg"

# 3. Sign DMG
codesign --sign "$SIGNING_ID" --timestamp "dist/$APP_NAME-$VERSION.dmg"

# 4. Notarize
xcrun notarytool submit "dist/$APP_NAME-$VERSION.dmg" \
  --apple-id "<your-apple-id>" \
  --team-id "$TEAM_ID" \
  --password "<app-specific-password>" \
  --wait

# 5. Staple
xcrun stapler staple "dist/$APP_NAME-$VERSION.dmg"

echo "✅ $APP_NAME-$VERSION.dmg ready for distribution"
```

**Version management:**
- Update `Info.plist` `CFBundleShortVersionString` to `0.6.0`
- Update `CFBundleVersion` to build number
- Update the About tab in Settings to read from `Info.plist` dynamically

---

### 6F — Auto-Update Mechanism

**Goal:** Users get updates without manually downloading DMGs.

**Dependency:**
- [Sparkle 2](https://sparkle-project.org/) — The standard macOS update framework. Add via SPM: `https://github.com/sparkle-project/Sparkle` (v2.x)

**New files:**
- `Majoor/Core/UpdateManager.swift` — Wrapper around Sparkle's `SPUStandardUpdaterController`
- Host an `appcast.xml` file on GitHub Pages or a static hosting service

**Modified files:**
- `Majoor/AppDelegate.swift` — Initialize Sparkle on launch
- `Majoor/Settings/GeneralSettingsView.swift` — Add "Check for Updates" button and "Auto-check for updates" toggle
- `Majoor/Info.plist` — Add `SUFeedURL` key pointing to appcast URL

**Appcast hosting:**
- Create a GitHub repo (e.g., `kush-3/majoor-releases`) with GitHub Pages enabled
- Each release: upload the DMG, generate an appcast entry with Sparkle's `generate_appcast` tool
- The app checks this URL periodically for new versions

**Implementation:**
```swift
// UpdateManager.swift
import Sparkle

class UpdateManager {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }
}
```

---

## Implementation Order

```
Step 1: 6A — Onboarding (first-run UX, no infra changes)
Step 2: 6B — Pipeline Progress UI (carry from 5D, improves daily UX)
Step 3: 6C — Error Handling (stability, reduces user confusion)
Step 4: 6D — Performance (battery/memory, improves background behavior)
Step 5: 6E — Notarization & DMG (requires Apple Developer cert)
Step 6: 6F — Auto-Update (requires 6E, needs hosted appcast)
```

Steps 1-4 can be developed in parallel by different engineers. Steps 5-6 are sequential and depend on having an Apple Developer ID certificate.

---

## New File Count: ~6 new files + 1 dependency

| File | LOC Estimate | Owner |
|------|-------------|-------|
| `UI/Onboarding/OnboardingView.swift` | ~120 | |
| `UI/Onboarding/OnboardingStepViews.swift` | ~200 | |
| `Core/UpdateManager.swift` | ~40 | |
| `Scripts/build-dmg.sh` | ~40 | |
| `Scripts/notarize.sh` | ~20 | |
| **Total new** | **~420 LOC** | |

**Modified files:** ~12 existing files with moderate changes

**New dependency:** Sparkle 2.x via SPM (auto-update framework)

---

## Milestone

> A new user downloads Majoor.dmg, opens it, completes a 5-step onboarding wizard, and within 2 minutes has a working agent with GitHub connected. They say "I just finished the auth feature" and see a clear pipeline progress view showing each step complete in real time. The app uses minimal battery when idle, recovers gracefully from errors, and auto-updates when a new version ships.

---

## Open Questions

1. **Apple Developer Program** — Is there an active $99/year membership? Notarization (6E) and Sparkle signing (6F) both require it. Everything else works without it.

2. **Tool subset filtering (6D)** — Should the TaskClassifier be updated with new categories that map to MCP servers (e.g., `project_management` → Linear, `communication` → Slack)? Or is keyword detection in the user input sufficient?

3. **Onboarding re-entry** — Should users be able to re-run onboarding from Settings? Useful if they skipped integrations initially and want the guided flow later.

4. **MCP idle timeout (6D)** — 10 minutes was proposed. Should this be configurable in Settings, or is a fixed value fine? Slack servers are lightweight (~20MB RSS), GitHub is similar. The memory savings may not be worth the cold-start latency.

5. **Pipeline step editing** — Should users be able to edit/remove steps from the proposed plan before approving? This is a nice-to-have but adds significant UI complexity. Recommendation: defer to Phase 7 if needed.

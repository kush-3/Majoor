# Majoor 2.0, Phase 1 implementation plan

**Status:** Draft v1, 2026-10-31. Source of requirements: `docs/MAJOOR-2.0-PRD.md` v0.3 (§3, §5.1–5.4, §7, §9, §12, §13/D7).
**Scope of this document:** plan only. No code was changed. The one experiment (the Swift 6 build in step 1) ran on a copy of the working tree in a scratch directory.

Phase 1 goal, from PRD §12: from your phone, text Majoor a task; it does it, asks before anything R3, `STOP` works, "remind me in 20 min" works. From your laptop: hotkey, type a task, watch it run on the Mac mini in the activity feed, approve it there.

---

## 0. Ground rules and what I found in the code

### 0.1 Files this plan must not touch

Phase 0 work is uncommitted in the working tree. This plan never edits `Majoor/Security/*`, `Majoor/Core/PermissionMode.swift`, `Majoor/Core/OAuth/GoogleOAuthManager.swift`, `Majoor/Tools/ShellTools.swift`, `Majoor/Tools/WebTools.swift`. It reads from them (`ConfirmationPolicy.shouldConfirm`, `ConfirmationPolicy.isSensitive`, `PermissionMode.current`, `PermissionMode.defaultsKey`, `runShellCommand`) and says so where it does.

`Majoor.xcodeproj/project.pbxproj` also has uncommitted Phase 0 edits (signing team, build number, runtime exceptions). The Swift 6 flip edits two lines in that file, so **step 1 must start after Phase 0 is committed**, or the two diffs get tangled.

### 0.2 Surprises (read these before the steps; several change the design)

1. **The confirmation actor is already multi-continuation.** `ConfirmationManager.pendingConfirmations` is a `[String: CheckedContinuation]` keyed by a fresh UUID per request (`ConfirmationManager.swift:27`). The PRD's "single `CheckedContinuation`" is not quite right. What actually forces one task at a time is three other things:
   - `AppDelegate.handleCommand` refuses input while `taskManager.isTaskRunning` (`AppDelegate.swift:176`) and keeps one `runningTaskHandle`.
   - `TaskManager` has single UI slots: `activeConfirmation`, `pendingPipelinePlan`, `pendingPipelineTaskId`, `pipelineSteps`, `pipelineExecuting`, `pipelineStartTime`, `isTaskRunning`, `runningTaskInput`.
   - One `AgentLoop` instance owns one shared `conversationHistory` (`AgentLoop.swift:28`), and `AppDelegate.agentLoop` lives for the life of the app.

   The per-session confirmation work is therefore mostly about *ownership* (which session a prompt belongs to, so `/stop 3` denies only session 3), nonces and expiry, and a UI queue, not about making the actor concurrent.
2. **Pipeline step toggles travel through shared UI state.** After a plan is approved, the loop reads `taskManager.pipelineSteps` to find steps the user switched off (`AgentLoop.swift:~329` and again in the `.mixed` arm). A remote approver cannot mutate that array, so `ConfirmationResult` (`ConfirmationManager.swift:12`) must grow a `skippedStepIndices` field and the control API must carry it.
3. **The loop mutates the SwiftUI model directly.** `AgentLoop` has 35 `taskManager.` references and 31 `MainActor.run` hops, and appends to `AgentTask.steps` (a `@Published` class) from the loop. It cannot run headless or stream to a remote client until it writes to a neutral recorder and emits events instead. This is the core of step 2.
4. **The pipeline-plan approval block is duplicated** in the `.text` arm (`AgentLoop.swift:~290–360`) and the `.mixed` arm (`~505–570`). Both call `ConfirmationManager.shared.requestConfirmation` (lines 311 and 525); the tool-confirmation call is at line 775. Three call sites to move, and the two plan blocks should become one method while they are being touched.
5. **Tools have no per-call context.** `AgentTool.execute(arguments:)` (`ToolProtocol.swift:38`) receives only string arguments. A reminder tool cannot know which channel asked. Plan: a `@TaskLocal` `SessionContext` (step 2), which reaches tools because they run inside the loop's task chain. Nothing in the codebase uses `TaskLocal` yet.
6. **`STOP` cannot kill a running child process.** `runShellCommand` (`ShellTools.swift:400`) waits on a `terminationHandler` continuation and only kills on its own timeout (30 s shell, 60 s script, 120 s run_tests). Cancelling the session task stops the loop before the next tool, not mid-command. Worst-case STOP latency is about 2 minutes. Fixing it means editing `ShellTools.swift`, which is off-limits until Phase 0 lands: tracked as step 2f, deferred.
7. **`MCPClient` drops server notifications** (`MCPClient.swift:~395`, "log and ignore for now"). `imsg rpc` delivers new messages as notifications (`message`, `watch.overflow`), so the iMessage client cannot be `MCPClient` itself. It needs its own sibling (step 7). I fetched the `imsg` RPC reference (`openclaw/imsg`, `docs/rpc.md`) to ground this.
8. **`AgentTool` is not actually `nonisolated`.** The comment above it says "nonisolated since tools do file/network I/O" (`ToolProtocol.swift:28`) but the protocol has no `nonisolated`, so under default MainActor isolation it is MainActor-isolated. Every tool struct is marked `nonisolated`, which only produces warnings in Swift 5 mode. This single omission is behind about half of the Swift 6 errors.
9. **The date context given to the model has no time zone** (`AgentLoop.swift:114–116`: `"EEEE, MMMM d, yyyy 'at' h:mm a"`). A reminder tool that takes an absolute time needs it. Step 6 adds the zone to the prompt and also takes a `delay_minutes` argument so "in 20 minutes" needs no date arithmetic by the model.
10. **ATS vs Tailscale names.** App Transport Security does not apply to IP-address URLs but does apply to fully qualified names such as `mini.tailnet.ts.net`. A `ws://` URLSession connection to a MagicDNS name would be refused. Step 4/5 therefore use `NWConnection` with WebSocket options on both ends (ATS does not apply to Network.framework), which also gives one framing code path.
11. **`conversationHistory` is a product feature** ("Conversation Continuity", last 10 minutes, 5 entries). Splitting history per session would silently remove follow-up behavior. Plan: history is keyed by *thread* (panel, one iMessage chat, one control client), not by session (step 2).
12. **Headless-box permission prompts.** Calendar, Full Disk Access, Automation → Messages and (possibly) Local Network prompts need one interactive click on the Mac mini (screen sharing during setup). Keychain items are saved `WhenUnlockedThisDeviceOnly` (`KeychainManager.save`), which is fine for an auto-login session but fails over plain SSH. Operational, not code.
13. **`ChatView.swift:158` crashes the Swift 6 type-checker** with "failed to produce diagnostic" in the first pass. It disappeared after the other errors were fixed (I also rewrote the ternary that passes two method references to `Button(action:)`; I did not isolate which change cured it).

### 0.3 Conventions for all new code

- New directories under `Majoor/Core/` (CLAUDE.md says follow the existing structure and gives `Core/` as the home for runtime pieces): `Core/Runtime/`, `Core/Channels/`, `Core/Channels/IMessage/`, `Core/ControlAPI/`, `Core/Automation/`. Tools go in `Majoor/Tools/`. UI goes in `Majoor/UI/` and `Majoor/Settings/`. Nothing new in `Security/`.
- Files under `Majoor/` are auto-discovered (`PBXFileSystemSynchronizedRootGroup`): create the `.swift` file, do not touch `project.pbxproj` for file references.
- Isolation vocabulary used below: `nonisolated` (struct/enum/final class, `@unchecked Sendable` only when it guards state with a lock), `actor`, `@MainActor` (the default; written explicitly only for emphasis). Every new off-main type is written `nonisolated` from the start because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` still applies after the flip.
- Migrations: add new `migrator.registerMigration("vN_...")` blocks after `v4_fts5_external_content` in `DatabaseManager.runMigrations`. Never edit an applied one.
- Logging: `MajoorLogger.log/error` (already `nonisolated`).

### 0.4 Order and parallelism

```
1 Swift 6 ──► 2 Session runtime ──► 3 Channel protocol + panel channel ──┬─► 4 Control API ──► 5 Client mode
                                                                          ├─► 6 Automations + reminders
                                                                          └─► 7 iMessage channel
```

After step 3, tracks 4→5, 6, and 7 are independent and can be done in parallel or in any order. Step 6's delivery path is best exercised by step 7, but works with the panel channel (macOS notification) alone.

### 0.5 Test target

**Yes: add a unit-test target in step 1.** The PRD itself lists "the session-runtime refactor destabilizes a codebase with no tests" as a High-likelihood risk (§14). Creating a target means editing `project.pbxproj` targets, which CLAUDE.md warns against doing by hand; **Kush should create it in Xcode** (File ▸ New ▸ Target ▸ Unit Testing Bundle, Swift Testing), named `MajoorTests`, with its source folder synced the same way as `Majoor/`. ~1–2 h including the seams below.

Seams needed so tests do not touch real state (all small, done in step 1b):
- `DatabaseManager.dbPath`: honor an env var `MAJOOR_DB_PATH` (tests point it at a temp file). Without it, `@testable import Majoor` tests would write to `~/Library/Application Support/ai.majoor.agent/majoor.sqlite`.
- `AppDelegate.applicationDidFinishLaunching`: return early when `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`, so an app-hosted test run does not start MCP servers, register the global hotkey or pop onboarding.
- Later steps introduce a `ProviderRouter` closure and a `Clock` seam (below) so the loop and scheduler are testable with scripted providers and a fake clock.

What the suite covers (tests are added step by step, listed per step): session stop/approval semantics, nonce handling, slash-command parsing, control-API message round trips, newline-JSON framing (partial lines, several messages per chunk), owner-only filtering and handle normalization, scheduler firing/catch-up with a fake clock, migrations on a fresh and a v4 database.

---

## Step 1. Swift 6 language mode flip (D7)

> **Status: done 2026-10-31** on branch `phase-1-swift6` (commits "build: Flip to Swift 6 language mode" and "chore: Clear every Swift 6 warning"). Zero errors, zero Swift warnings in Debug and Release; smoke-tested through the `majoor://task` automation hook. The test target (§0.5) is still to be created in Xcode.

**Size:** ~60 changed lines in 14 files, 2–3 h, plus 1–2 h for the test target. **Depends on:** Phase 0 committed.

### 1a. What breaks (measured, not guessed)

I ran both commands from the brief.

- `xcodebuild … build 2>&1 | grep warning:` on the current tree: **87 warning lines** (about 45 distinct). Everything isolation-related in it is "will be an error in Swift 6".
- Because warning text alone under-reports (the Swift 6 compiler reports in layers), I also built with `SWIFT_VERSION=6` as a command-line override. First pass: **27 distinct errors** in 7 files. Fixing them exposed **13 + 11 + 2 more** (conformance-isolation errors, free-function errors, a `sending` error), i.e. expect three compile passes.
- I then applied the fixes below to a copy of the tree in a scratch directory: **it builds clean in Swift 6 mode (exit 0)**. The 12 files and 24 one-line edits are exactly the list below. No Phase 0 file needed to change (`ShellTools.swift`, `GoogleOAuthManager.swift`, `WebTools.swift`, `PermissionMode.swift` all compile once the root causes elsewhere are fixed).

### 1b. Error categories and the fix for each

| # | Category | Errors | Root cause | Fix |
|---|----------|--------|-----------|-----|
| A | `AgentTool` is MainActor by accident | `ToolProtocol.swift:54,62,63,67`; `AgentLoop.swift:717,876`; 13 `conformance of 'XTool' to protocol 'AgentTool' crosses into main actor-isolated code` (CalendarTools ×3, EmailTools ×3, FileTools ×4, MemoryTools ×1, ShellTools ×2) | Protocol declared without `nonisolated` (surprise 8); its extension defaults `isReadOnly` and `confirmationPreview` inherit MainActor too | `ToolProtocol.swift`: `nonisolated protocol AgentTool: Sendable`; `nonisolated var isReadOnly`; `nonisolated func confirmationPreview`. Fixes all 19 with no edit to any tool file |
| B | Free functions and helper types in tool files default to MainActor | `CalendarTools.swift` `parseDate` (×6 call sites), `formatEvent` (×3); `EmailTools.swift` `isValidEmailId` (×2), `GmailAPI.parseMessage` (`EmailTools.swift:267`) | file-private `func`/`struct` pick up default isolation | Mark `nonisolated`: `parseDate`, `formatEvent`, `ensureCalendarAccess`, `describeAuthStatus` (CalendarTools), `isValidEmailId`, `struct GmailAPI` (EmailTools), `shellEscape`, `isValidBranchName` (GitTools; defensive, did not error but same shape) |
| C | Config/singletons read off-main | `ModelRouter.swift:29,54,64,87` and `GoogleOAuthManager.swift:58,290,318` (`APIConfig.claudeAPIKey`/`googleClientId`); `ConfirmationManager.swift:56`, `NotificationManager.swift:103,191,198` | `APIConfig` and `NotificationManager` are MainActor by default but used from nonisolated code | `APIConfig.swift`: `nonisolated struct APIConfig` (also fixes the three GoogleOAuth errors without touching that file). `NotificationManager.swift`: `nonisolated final class NotificationManager` (it is already `@unchecked Sendable` and its delegate methods are already `nonisolated`) |
| D | Data containers used off-main | `AnthropicProvider.swift:421–423` (`AnyCodable.stringValue/intValue/boolValue`); `AgentLoop.swift:932` (`PipelineStep.init`) | `AnyCodable`, `AnthropicContent`, `PipelineStep`, `PipelineStepStatus` lack `nonisolated` | `Models.swift`: add `nonisolated` to those four |
| E | UI model class touched from the loop and from persistence | `AgentLoop.swift:145` (`AgentTask(userInput:)`), `:432` (`task.steps`); `TaskPersistence.swift:43,56,57,59,60,62×3,64,115` (10) | `AgentTask` is a `@MainActor ObservableObject` | **Interim (this step):** `@MainActor` on `TaskPersistence.saveTask`, `loadRecentTasks`, `recordToTask`; in `AgentLoop` create the task inside the existing `MainActor.run`, and read `task.steps` in one `MainActor.run`. Behavior is unchanged (`taskManager.persistTask` already ran on main). **Permanent fix is step 2** (`TaskSnapshot`, `TaskRecorder`) which deletes these hops |
| F | Non-Sendable value crossing a continuation | `MCPClient.swift:367` (`continuation.resume(returning: result)` with `[String: Any]`) | `sending` check on a `[String: Any]` | `nonisolated(unsafe) let r = result` before the resume, with a comment. Proper fix (a Sendable `JSONValue`) arrives with the iMessage client in step 7; do not refactor `MCPClient` in this step |
| G | Isolated `Equatable` conformance used in a `@Sendable` closure | `StatusBarController.swift:43` (`AgentState`) | enum is MainActor by default | `nonisolated enum AgentState` |
| H | Type-checker crash | `ChatView.swift:158` | see surprise 13 | Replace `Button(action: chatManager.isStreaming ? stopStreaming : sendMessage)` with a closure that branches |

### 1c. Warnings that remain (not errors, fix opportunistically in the same PR)

About 30 warnings remain after the flip. They are real isolation smells but compile:
- AppKit completion-handler closures touching MainActor state: `AppDelegate.swift:69,75,76,313,314`, `CommandBarWindow.swift:90,91`, `StatusBarController.swift:37–44,126–142`. Wrap the bodies in `MainActor.assumeIsolated { }` (the callbacks do run on main) or `Task { @MainActor in }`.
- `NotificationManager.swift:8,87`: `@preconcurrency import UserNotifications`.
- Pre-existing, unrelated to Swift 6: `CalendarTools.swift:19` switch not exhaustive (add `@unknown default`), `:34,37` and `GoogleOAuthManager.swift:72` unused `MainActor.run` result (`_ =`; do not edit the Google file now, leave it), `.authorized` deprecated at `CalendarTools.swift:19` and `AccountsSettingsView.swift:111` (use `.fullAccess`), `TaskPersistence.swift:62` meaningless `??`.

### 1d. Build settings

`project.pbxproj` lines 307 and 357: `SWIFT_VERSION = 5.0;` to `6.0;` (Debug and Release). Keep `SWIFT_APPROACHABLE_CONCURRENCY = YES` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. `SWIFT_STRICT_CONCURRENCY` is not set today and is implied by Swift 6 mode; do not add it. Preferably make this change in Xcode (Build Settings ▸ Swift Language Version) rather than by hand.

### 1e. Risks

- **Runtime isolation traps.** Swift 6 inserts executor checks on `@MainActor` closures. The ones to watch are NotificationCenter and AppKit callbacks registered with `queue: nil` (`AppDelegate.swift:56–66`, sleep/wake) and any closure that calls a MainActor method from a delegate callback. The sleep/wake closures only spawn `Task { await MCPServerManager… }`, so they are safe; the smoke test below exercises the rest.
- A fourth compile pass may reveal an error that only appears in Release (optimizer-dependent diagnostics are rare, but build Release once).
- Third-party modules: GRDB and Sparkle both compiled clean in the scratch build.

### 1f. Verify (manual smoke, ~20 min; run before and after)

1. Debug and Release builds succeed (`xcodebuild -configuration Debug build`, then Release).
2. Launch; menu bar icon; ⌘⇧Space opens the bar.
3. Task: "list files in ~/Desktop" (tool call, result, completion toast).
4. Task that triggers a confirmation (`delete_file` on a temp file): sheet appears; approve; also deny; also approve from the macOS notification button.
5. A pipeline plan (a 3-tool scenario): plan sheet, toggle a step off, approve, `PipelineProgressView` updates.
6. Start a task, press Stop mid-way: "Task Stopped" toast, row persisted as failed.
7. Calendar read (permission dialog path), Gmail fetch (token refresh path), one MCP tool, Chat tab streaming, Sparkle "Check for updates".
8. Quit and relaunch: previous tasks load (`TaskPersistence.loadRecentTasks`).

---

## Step 2. Session runtime: `AgentSession`, `SessionManager`, per-session approvals

**Size:** ~1,400 new lines plus ~600 changed in `AgentLoop.swift` (mostly mechanical), 4–5 days. **Depends on:** step 1. This is the step that carries the risk; it is split into verifiable sub-steps, and the app must work in "local mode" (1.x behavior, panel only) after each one.

### Design in one picture

```
Panel / channel text ──► SessionManager (actor) ──► AgentSession (actor) ──► AgentLoop.run (nonisolated, 1.x logic)
                              │                          │  emits SessionEvent
                              │                          └─ awaits approval via its own continuation
                              ├─ EventBus (actor): seq numbers + ring buffer ─► UI mirror (MainActor) ─► TaskManager / AgentTask
                              │                                                └► control API subscribers (step 4)
                              └─ ThreadHistory: conversation continuity keyed by thread
```

The loop stops knowing about `TaskManager`, `AgentTask`, `ConfirmationManager`, and `NotificationCenter`. It talks to its session. Everything the UI shows is derived from `SessionEvent`s, so the local panel and a remote laptop render from the same stream.

### 2a. Event model, recorder, snapshot persistence

> **Status: done 2026-10-31** (commit "feat: Session runtime foundations (Phase 1 step 2a)"). Files under `Core/Runtime/`; migration `v5_sessions_approvals`; 20 tests in `MajoorTests/SessionRuntimeTests.swift`. Deviation: `TaskPersistence` keeps `saveTask(AgentTask)` and `loadRecentTasks` as main-actor wrappers around the snapshot API until 2e removes the last callers.

**New files (all `nonisolated`, `Codable`, `Sendable` unless noted):**
- `Core/Runtime/SessionTypes.swift`: `typealias SessionID = UUID`; `enum SessionKind { concierge, task, job }`; `enum SessionState { queued, running, waitingApproval, completed, failed, stopped }`; `struct SessionInfo { id, shortId: Int, kind, state, input, origin: ChannelRef, threadKey, createdAt, endedAt?, summary?, tokensIn, tokensOut, costUSD }`; `struct StepDTO` (mirror of `TaskStep`: timestamp, type string, description, detail); `struct PipelineStepDTO`; `enum RiskClass: String { r0, r1, r2, r3 }`; `struct ApprovalRequest { id, sessionId, title, body, category, riskClass, nonce, expiresAt, isPipelinePlan, pipelineSteps }`; `struct ApprovalDecision { approved, feedback, skippedStepIndices }` (supersedes `ConfirmationResult`, surprise 2); `struct ChannelRef { channelId: String, threadKey: String }`.
- `Core/Runtime/SessionEvent.swift`: `enum SessionEvent` with cases `created(SessionInfo)`, `state(id, SessionState)`, `step(id, StepDTO)`, `pipelinePlan(id, text, [PipelineStepDTO])`, `pipelineStep(id, index, status, result?, error?)`, `approvalRequested(ApprovalRequest)`, `approvalResolved(approvalId, approved, byChannel)`, `cost(id, tokensIn, tokensOut, sessionUSD, dayUSD)`, `finished(id, SessionState, summary)`. Custom `Codable` with a `"type"` discriminator so step 4 can ship it as JSON unchanged.
- `Core/Runtime/EventBus.swift`: `actor EventBus` with `publish(_:)`, `subscribe(since: Int?) -> (snapshotRequired: Bool, stream: AsyncStream<SequencedEvent>)`, a monotonically increasing `seq`, and a 1,000-event ring buffer. `snapshotRequired` is true when `since` is older than the ring. Slow subscribers: `AsyncStream.Continuation.BufferingPolicy.bufferingNewest(2000)`; a subscriber that overflows is told to resync.
- `Core/Runtime/TaskRecorder.swift`: `actor TaskRecorder` replaces the loop's use of `AgentTask`. Holds `steps`, `status`, `summary`, `tokensUsed`, `modelUsed`, `completedAt`. Methods: `append(step)`, `setUsage(tokens, model)`, `complete(summary, steps) -> Bool` (returns false if the session was stopped: this is the actor-serialized replacement for the "liveness check in the same MainActor hop" comment at `AgentLoop.swift:~400`; the race it closes must stay closed), `fail(reason)`, `snapshot() -> TaskSnapshot`. Persists through `TaskPersistence` and publishes the matching `SessionEvent`.
- `TaskSnapshot` (in `Core/TaskPersistence.swift`): `nonisolated struct TaskSnapshot: Sendable` with the same fields `TaskPersistence.saveTask` reads from `AgentTask` today.

**Modified:**
- `Core/TaskPersistence.swift`: `saveTask(_ snapshot: TaskSnapshot)` and `loadRecentTasks` returning `[TaskSnapshot]`; delete the interim `@MainActor` from step 1. `TaskManager.init` converts snapshots to `AgentTask` on the main actor (it already restores via `AgentTask.init(id:…)`).
- `Core/Database/DatabaseManager.swift`: new migration `v5_sessions_approvals` (PRD §7):
  - `sessions(id TEXT PK, shortId INTEGER, kind TEXT, originChannel TEXT, threadKey TEXT, state TEXT, input TEXT, taskId TEXT, createdAt TEXT, endedAt TEXT, tokensIn INTEGER, tokensOut INTEGER, costUSD REAL, summary TEXT)`, index on `createdAt`.
  - `approvals(id TEXT PK, sessionId TEXT, nonce TEXT, actionSignature TEXT, riskClass TEXT, requestedAt TEXT, expiresAt TEXT, decision TEXT, decidedByChannel TEXT, decidedAt TEXT, feedback TEXT)`, index on `sessionId`. "Every decision is logged" (PRD G5) starts here; `actionSignature` is `toolName + sorted normalized key args` hashed, which is what the Phase 2 trust ledger will key on.
  - Do not touch `tasks`; `sessions.taskId` links to it.
- `Core/LLMProvider.swift`: add `IncompleteReason.budgetExceeded` with `userFacing` "Stopped: the session token budget was reached." (the only exhaustive switch is that enum's own `userFacing`).

**Watch out for:** `AgentTask` stays as the SwiftUI model, now created only by the UI mirror (2e). `TaskRecord.costEstimate` uses `tokensUsed / 2` for both directions (`TaskPersistence.swift:62`, existing TODO): the recorder should carry real input and output counts and fix it, since `cost` events need correct dollars.

**Isolation summary:** `SessionTypes`, `SessionEvent`, `TaskSnapshot`: `nonisolated` value types. `EventBus`, `TaskRecorder`: actors.

**Verify:** unit tests: event JSON round-trip for every case; `EventBus` resume (`since` inside and outside the ring); `TaskRecorder.complete` returns false after `fail(.cancelled)`; migration `v5` on a fresh DB and on a copy of a real v4 DB.

### 2b. Thread history and token budget

> **Status: done 2026-10-31** (commit "feat: Thread-keyed conversation history and token budget (Phase 1 step 2b)"). `ConversationEntry` replaces the loop's private `ConversationContext`; wiring into the loop is 2c.

**New:**
- `Core/Runtime/ThreadHistory.swift`: `nonisolated final class ThreadHistory: @unchecked Sendable` (an `NSLock`, same pattern as `AgentLoop.historyLock`). Moves `ConversationContext` out of `AgentLoop` and keeps the same constants (10-minute timeout, 5 entries, 1000-char response cap). API: `snapshot(thread:)`, `append(thread:, entry:)`, `pruned`. Keyed `[String: [ConversationContext]]`.
- `Core/Runtime/TokenBudget.swift`: `nonisolated struct TokenBudget: Sendable { var maxTotalTokens: Int }` plus `static func dailyCapExceeded() -> Bool` using `UsageStore.shared.todayUsage().totalCost` against a setting. Placeholder defaults: 2,000,000 tokens per session, $25/day (see open questions; the loop does not use prompt caching, so long sessions re-send the whole context every iteration and tokens grow quickly).

**Why thread-keyed:** surprise 11. Panel thread key is `"panel"` (same as today's single history), iMessage is `"imessage:<handle>"`, a control client is `"client:<clientId>"`.

**Verify:** unit test that two sessions in the same thread see each other's completed entries and that entries older than 10 minutes are pruned.

### 2c. Surgery on `AgentLoop` (the risky one)

> **Status: 2c, 2d and 2e done 2026-10-31** (commit "feat: Session runtime: concurrent sessions with per-session approvals"). Deviations from the text below: the loop talks to an `AgentLoopHost` protocol (`Core/Runtime/LoopHost.swift`) rather than to `AgentSession` directly, so tests host it too; `ModelRouter.routeHybrid` was left untouched and wrapped by `AgentLoop.defaultRouter`; pipeline state lives in a locked `PipelineState` class shared with the tool phase; the UI mirror is the minimal version (`TaskManager.apply` + `SessionEventPump`; no "1 of N" badge yet; the command bar shows the running row above the input instead of a "N running · Stop" row). 2f (killing child processes on STOP) remains deferred. Real concierge sessions remain deferred to Phase 2.

**File:** `Core/AgentLoop.swift`. Goal: identical model-visible behavior (system prompt, iteration logic, truncation recovery, overflow recovery, tool dispatch, memory injection, aliases, pipeline parsing) with different plumbing.

1. **Constructor and entry.** Replace `init(tools:taskManager:)` with `init(tools: [any AgentTool], route: @escaping ProviderRouter)` where `typealias ProviderRouter = @Sendable (String) async -> (provider: any LLMProvider, toolSets: [String])` and the default is `ModelRouter.routeHybrid` (change its return type from `AnthropicProvider` to `any LLMProvider`: the loop only uses `complete`, `model`, `name`, so the change is safe). This is the test seam. Replace `execute(userInput:)` (line 90) with `run(userInput:session:)` where `session: AgentSession`; keep the body's structure.
2. **Delete the loop's own `conversationHistory`/`historyLock`/`ConversationContext`** (moved in 2b); read and write through `session.history`. The two write sites (success at `~422` and iteration-limit at `~590`) become `session.history.append(...)`.
3. **Replace every `taskManager.X` call (the 35 listed by line in the grep) and `task.steps.append`/`task.status = …` inside `MainActor.run` blocks** with calls to `session.recorder` (steps, usage, completion, failure) or `session.emit(...)` (pipeline events). `private func fail(_ task:…)` (line 613) becomes `fail(_ reason:)` calling `recorder.fail(reason)`; it still returns `LLMError.incomplete(reason:)` and callers still `throw await fail(...)`. The "only tear down a plan this task owns" guard disappears because pipeline state is now per-session.
4. **Pipeline state moves into the run frame.** `var pipeline: [PipelineStep]` is a local of `run`; `matchToolToPipelineStep(_:arguments:steps:)` already takes `steps` as a parameter, so it needs no change; the `taskManager.pipelineSteps` reads at `~329`, `~525` (skipped steps) become `decision.skippedStepIndices`. Emit `pipelinePlan` once and `pipelineStep` on each status change.
5. **Extract the plan block.** The identical plan-approval code in the `.text` and `.mixed` arms becomes `private func proposePlan(_ planText: String, messages: inout [AnthropicMessage], session:…) async -> PlanOutcome` (`.approved`, `.declined`). Both arms call it; the surrounding `truncatedPrefix` handling stays in the arms. Keep the exact `approvalMsg` / `denialMsg` strings, since they are prompt text.
6. **Replace the three `ConfirmationManager.shared.requestConfirmation` sites** (lines 311, 525, 775) with `await session.requestApproval(ApprovalDraft(...))`. The tool-confirmation site keeps its argument-summary construction (priority keys, identity-key caps, `confirmationPreview`) verbatim. It additionally passes the computed `riskClass` (below) and `actionSignature`.
7. **Per-session permission mode.** `ConfirmationPolicy.shouldConfirm(mode: PermissionMode.current, …)` becomes `mode: session.effectiveMode`, where `effectiveMode` is `PermissionMode.current` except that sessions started from an inbound channel with `trust == .remoteText` (iMessage) downgrade `.auto` to `.standard` (PRD T1: "Auto permission mode is disabled on inbound channels"). `shouldConfirm` already takes `mode` as a parameter, so no edit to `PermissionMode.swift` is needed.
8. **Risk class.** `RiskClass` for an approval is derived with a read-only call to `ConfirmationPolicy.isSensitive(toolName:requiresConfirmation:arguments:)`: sensitive means `.r3`, anything else that prompted means `.r1`. Phase 1 uses it for display and logging only; the trust ledger and R2 promotion are Phase 2.
9. **Budget.** After `totalInputTokens += …` (line ~213), if `session.budget` is exceeded or `TokenBudget.dailyCapExceeded()`, `throw await fail(.budgetExceeded)`. Emit a `cost` event each iteration.
10. **`SessionContext` task-local** (surprise 5): `Core/Runtime/SessionContext.swift`, `nonisolated struct SessionContext: Sendable { sessionId, origin: ChannelRef, trust }` with `@TaskLocal static var current: SessionContext?`. `AgentSession` wraps the run in `SessionContext.$current.withValue(ctx) { … }`. Tools read `SessionContext.current` (used by step 6).
11. **Keep untouched:** the system prompt text, `normalizeArguments`, `parsePipelineSteps`, `stepToolMapping`, `matchToolToPipelineStep`, `trimConversationForRecovery` and its helpers, `unexecutedTurn`, the iteration cap (75), `maxToolResultChars`, truncation-recovery constants. CLAUDE.md says "avoid changing iteration logic"; none changes.
12. **Cancellation.** `try Task.checkCancellation()` calls (lines ~686, ~810) stay. The approval path must preserve the closed race that `ConfirmationManager.requestConfirmation` documents (check cancellation, register, no suspension in between): see `AgentSession.requestApproval` below.

**Risks:** this is a 600-line mechanical edit in a file with no tests; a dropped `continue` or a missed `truncatedPrefix = ""` changes what users see. Mitigation: do it as a sequence of small commits (constructor, history, recorder, pipeline, approvals), run the step 1f smoke after each, and add the scripted-provider tests (2d) *before* starting 2c so there is a safety net.

### 2d. `AgentSession`, `SessionManager`, slash commands

**New files:**
- `Core/Runtime/AgentSession.swift`: `actor AgentSession`.
  - State: `id`, `shortId`, `kind`, `origin: ChannelRef`, `state`, `budget`, `recorder: TaskRecorder`, `history: ThreadHistory` (shared reference), `runTask: Task<Void, Never>?`, `pendingApproval: (request, CheckedContinuation<ApprovalDecision, Never>)?`, `stopped: Bool`.
  - `start(input:)`: sets `.running`, creates `runTask` that runs `AgentLoop.run` inside `SessionContext.$current.withValue`, maps the loop's outcome to `finished` events (completed, `LLMError.incomplete` to failed with the reason text, `CancellationError` to stopped).
  - `requestApproval(_ draft) async -> ApprovalDecision`: if `stopped || Task.isCancelled` return denied "Task was stopped by the user" **before** registering; mint `nonce` (4 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, `SystemRandomNumberGenerator`); register the continuation; set state `.waitingApproval`; publish `approvalRequested`; send the macOS notification (`NotificationManager.shared.sendActionable`, existing API, now carrying `nonce` in `userInfo`); arm a 10-minute expiry `Task` that resolves as denied with feedback "Approval expired"; write the `approvals` row. Returns when `answer` or `stop` or expiry resumes it.
  - `answer(approvalId:, nonce:, decision:, byChannel:) -> AnswerResult` (`.ok`, `.unknownId`, `.badNonce`, `.expired`): compares nonce case-insensitively in constant time, resumes the continuation exactly once (guard `pendingApproval` nil-out before resume), publishes `approvalResolved`, updates the `approvals` row. A wrong nonce does **not** consume the approval (PRD T4: a replayed or injected "yes" is useless) but is counted; five wrong nonces deny it.
  - `stop(reason:)`: sets `stopped`, cancels `runTask`, resumes any pending continuation as denied, records state `.stopped`.
- `Core/Runtime/SessionManager.swift`: `actor SessionManager` with `static let shared`.
  - `sessions: [SessionID: AgentSession]`, `nextShortId`, `queue`, `maxConcurrent` (default 3, from settings), `history = ThreadHistory()`, `bus = EventBus()`.
  - `submit(input:, origin:, kind: .task) async -> SessionInfo`: creates the session; starts it if running < `maxConcurrent`, else `queued` (FIFO; started when a session finishes).
  - `list() -> [SessionInfo]`, `stop(shortId:)`, `stopAll()` (**STOP**: stop every session, drain the queue, deny every pending approval; idempotent), `answerApproval(id:nonce:decision:channel:)` (routes to the owning session by scanning pending approvals), `statusText() -> String` for `/status` (one line per session: `3 · running · "summarize the Q3 deck…" · 2m · $0.12`, plus queued and waiting-approval markers and the day's spend).
  - `handleInbound(_ text, from origin: ChannelRef, trust:)`: `InboundCommand.parse(text)` first: exact trimmed case-insensitive `stop` is STOP; `/status`; `/stop <n>`; `/stop` alone with exactly one running session stops it, otherwise it replies with the list. Everything else becomes a task. **Only those exact forms are commands**, so "stop the build and send a summary" or a path like `/etc/hosts` are tasks.
- `Core/Runtime/InboundCommand.swift`: `nonisolated enum InboundCommand { stopAll, stop(Int), status, none }` plus `static func parse`. Pure function; unit-test it heavily.

**Concierge kind.** `SessionKind.concierge` exists in the enum and in `sessions.kind`, but Phase 1 does not implement a separate fast read-only answerer. Every non-command message starts a task session, as 1.x does. A real concierge (small read-only toolset, can spawn tasks) is deferred to Phase 2 (see open question 4). `job` is implemented in step 6.

**Concurrency hazards to document, not solve:** two task sessions can edit the same repo or file (the model's own Git safety rules apply, nothing else does); `MCPServerManager`, `MemoryRetriever`, `UsageStore` are already shared and thread-safe by construction; EventKit uses the single `sharedEventStore`.

**Verify (tests, with a `ScriptedProvider: LLMProvider` returning canned `LLMResponse`s, injected through `ProviderRouter`):**
1. Two sessions run concurrently; each requests approval; answering A leaves B pending.
2. `stopAll()` with one running, one waiting for approval, one queued: all end `.stopped`, no continuation leaks (use `withCheckedContinuation` leak detection: a leak logs a runtime warning).
3. Approval with wrong nonce is rejected and does not resolve; correct nonce resolves; second answer returns `.unknownId`.
4. Approval expiry (inject a short expiry) yields a denied tool result and the loop continues.
5. Budget exceeded ends `.failed` with `.budgetExceeded`.
6. `InboundCommand.parse` table.
7. Iteration cap still yields `.failed(.iterationLimit)` (regression for commit `0e6ae04`, the truthful loop).

### 2e. UI mirror and AppDelegate rewiring (still local, panel only)

- `Core/TaskManager.swift` (`@MainActor`, stays an `ObservableObject`): add `func apply(_ event: SessionEvent)` that creates/updates `AgentTask` objects by session id (using `AgentTask.init(id:…)`, which already exists), maintains `pendingApprovals: [ApprovalRequest]`, `pipelineBySession: [UUID: [PipelineStep]]`, and `focusedPipelineSession`. `isTaskRunning`/`runningTaskInput` become computed (`runningTasks.count > 0`). Keep the old published property *names* where views read them (`pendingPipelinePlan`, `pipelineSteps`, `pipelineExecuting`, `pendingPipelineTaskId`) as computed projections of the focused session, so `PipelineProgressView` and `ConfirmationSheet` need only small edits, not rewrites. `activeConfirmation` becomes `pendingApprovals.first` mapped to `ConfirmationContext` (extended with `nonce`, `sessionId`, `riskClass`, `expiresAt`).
- A tiny `@MainActor final class SessionEventPump`: consumes `EventBus.subscribe` and calls `taskManager.apply`. Started in `AppDelegate`.
- `UI/ConfirmationSheet.swift:198` and `Core/NotificationManager.swift:186`: replace `ConfirmationManager.shared.resolve` with `SessionManager.shared.answerApproval(id:nonce:…)` (nonce read from the sheet's context / the notification's `userInfo`; local UI passes the nonce it was given, so the local approve path is unchanged for the user). The sheet shows the nonce for remote parity but does not ask the user to type it.
- `UI/ConfirmationSheet.swift`: the pipeline step toggles currently call `taskManager.togglePipelineStep` (line 66); keep that local toggling in the `pipelineBySession` copy and send the disabled indices as `skippedStepIndices` with the decision.
- `AppDelegate.swift`: delete `agentLoop`, `runningTaskHandle`, `handleCommand`'s single-flight guard (line 176) and `isTaskRunning` writes; `setupAgentLoop()` (line ~118) keeps DB init and memory decay, and builds `SessionManager.shared` configured with `ToolRegistry.defaultTools()`. `handleCommand` becomes: empty check, API-key check (keep the existing "Setup Required" toast), then `SessionManager.shared.submit`. Completion/failure toasts move to `SessionEventPump` reacting to `finished`. `stopRunningTask()` calls `SessionManager.shared.stopAll()`; keep the `statusBarController.setState` updates driven by event state.
- `UI/CommandBarView.swift` / `CommandBarWindow.swift`: the bar no longer blocks input while something runs (`isTaskRunning` branch at `CommandBarView.swift:37` and `:54`). Replace the running state with a small "N running · Stop" row above the input. `CommandBarWindow` passes `runningCount`.
- `UI/MainPanelView.swift:72`: "Working..." indicator uses `taskManager.isTaskRunning` (now computed); no structural change. The `activeConfirmation` branch (line ~25) keeps priority; add a "1 of N" badge in `ConfirmationSheet` when more than one is pending.
- `Core/ConfirmationManager.swift`: delete. `ConfirmationResult` is replaced by `ApprovalDecision`; `ConfirmationContext` is kept and extended.
- `CLAUDE.md`: the "do not introduce concurrency here" lines in the Confirmation Flow section are superseded by PRD §5.2; update them (the `docs-sync-auditor` agent does this).

**Verify (manual, panel only):** the full step 1f smoke; then start two tasks back to back (command bar stays usable); trigger two `delete_file` confirmations at once and answer them in reverse order; Stop during an approval wait; quit with a pending approval and confirm no stuck state on relaunch (sessions in `running`/`waitingApproval` found in `sessions` at launch are marked `failed` with "interrupted by restart": add that sweep to `SessionManager.start()`).

### 2f. Deferred: killing child processes on STOP

Needs a process registry that `runShellCommand` registers into and a `withTaskCancellationHandler` around its termination wait, in `ShellTools.swift`. Do this as a small follow-up commit right after Phase 0 lands. Until then, document that STOP takes effect before the next tool call and shell commands end at their own timeout (≤120 s). Open question 7.

---

## Step 3. `Channel` protocol and the panel channel

> **Status: done 2026-10-31** (commit "feat: Channel protocol, trust policy and channel router"). Deviations: `ChannelTrust` cases are `local` / `authenticatedClient` / `remoteText`; coded approval replies (`yes K7Q2`) are parsed by the router for every remote channel now rather than in step 7; `ask` has a default no-answer implementation until the Phase 2 "I'm blocked" job; `SessionGateway` carries `recentTasks` and `events` for the control API's snapshot.

**Size:** ~450 new lines, ~120 changed, 1–1.5 days. **Depends on:** step 2.

**New files:**
- `Core/Channels/Channel.swift`:
  ```swift
  nonisolated protocol Channel: Sendable {
      var id: String { get }                       // "panel", "imessage", "control"
      var trust: ChannelTrust { get }              // .localUI, .authenticatedClient, .remoteText
      var inbound: AsyncStream<InboundMessage> { get }
      func send(to thread: String, text: String, attachments: [URL]) async throws
      func ask(question: String, options: [String], timeout: Duration) async -> Answer
  }
  ```
  with `InboundMessage { channelId, threadKey, sender: SenderID, text, attachments, receivedAt }`, `SenderID` (normalized handle string), `Answer { text: String?, option: String?, timedOut: Bool }`, `ChannelTrust`.
- `Core/Channels/ChannelRouter.swift`: `actor ChannelRouter`. `register(channel)` starts a `Task` that iterates `channel.inbound`. For each message: `TrustPolicy.authorize(sender, channel)` (owner check, below), then `SessionManager.handleInbound`. Also `deliver(to: ChannelRef, text:)` used by sessions and scheduler to reach a channel by id.
- `Core/Channels/TrustPolicy.swift`: `nonisolated struct TrustPolicy`. Phase 1: the panel and authenticated control clients are owner by construction (they are local UI or hold a pairing token); `remoteText` channels require `sender` to equal the configured owner handle. Owner handle storage: `contacts_policy` table (migration `v6_control_clients_contacts`, shared with step 4's `paired_clients`): `handle TEXT PK, trust TEXT, isVIP INTEGER, createdAt`. One row with `trust = "owner"` is the whole Phase 1 policy; VIP and other trust levels are Phase 2 columns that exist but are unused.
- `Core/Channels/PanelChannel.swift`: `nonisolated final class PanelChannel: Channel, @unchecked Sendable`. `inbound` is an `AsyncStream` whose continuation is fed by `submit(text:)`, called from the main actor by the command bar. `send` posts a toast / macOS notification through `await MainActor.run`. `ask` is implemented for yes/no plus free-text feedback by reusing the approval path (a question is an `ApprovalRequest` with `isQuestion = true` and the options as button labels; free-form multi-option UI is Phase 2).
- `Core/Channels/SessionGateway.swift`: the seam that makes client mode cheap in step 5.
  ```swift
  nonisolated protocol SessionGateway: Sendable {
      func submit(_ text: String, thread: String) async throws -> SessionInfo
      func stop(shortId: Int?) async            // nil = STOP all
      func answerApproval(id: String, nonce: String, decision: ApprovalDecision) async throws
      func events(since: Int?) -> AsyncStream<SequencedEvent>
  }
  ```
  `LocalSessionGateway` wraps `SessionManager.shared`. `RemoteSessionGateway` arrives in step 5.

**Modified:**
- `AppDelegate.swift`: the `CommandBarWindow` `onSubmit` closure (task mode) calls `panelChannel.submit(text:)` instead of `handleCommand`. Chat mode path (`chatManager.send`) is unchanged. `applicationDidFinishLaunching` registers the panel channel with `ChannelRouter`.
- `UI/CommandBarView.swift`: no change beyond step 2e.

**Why a gateway and a channel both:** a *channel* is a place messages and questions come from and go to (panel, iMessage, a control client); the *gateway* is how the UI talks to *a* runtime (in-process or remote). In client mode the laptop's `PanelChannel` is not registered with a local router; the command bar submits through `RemoteSessionGateway` instead.

**Risks:** tasks submitted from the panel now go through an `AsyncStream` and a router actor: latency is negligible, but make sure the stream is created before the command bar can fire (create in `AppDelegate.init` order, not lazily). Dropped `inbound` messages if the consumer task is cancelled: the router's task lives for the app lifetime.

**Verify:** the step 1f smoke through the panel; type `/status` and `STOP` in the command bar (they go through `handleInbound`); `/stop 2` with two tasks running. Unit tests for `TrustPolicy` (owner handle normalization: phone to E.164, email lowercased) and `ChannelRouter` (non-owner on a `remoteText` channel never reaches `SessionManager`).

---

## Step 4. Control API (WebSocket on the Tailscale interface)

> **Status: done 2026-10-31** (commit "feat: Control API: WebSocket server on the Tailscale interface"). Implemented as designed with these notes: the per-connection handler is an actor; `ControlSettings.validate` is the pure tighten-only check the tests cover; the client endpoint must be a `ws://` URL (a host-and-port endpoint never completes the HTTP upgrade); the listener reports `.waiting` as a failed state so Settings shows why. Not yet verified by hand: the LAN-side refusal (`nc -vz <LAN-IP> 47821`) and the Local Network privacy prompt on a real Tailscale bind. Enabled from Settings ▸ Remote; off by default.

**Size:** ~900 new lines, 3 days. **Depends on:** step 3 (uses `SessionGateway`, `EventBus`). Runs only in runtime mode (step 5 adds the mode switch; for development, a DEBUG-only toggle enables it).

### Networking choice

**Network.framework `NWListener` with `NWProtocolWebSocket.Options` on the server, `NWConnection` with the same options on the client. No new dependency.**

Justification:
- CLAUDE.md: "Do NOT introduce new dependencies unless necessary" and the dependency list is deliberately two. A WebSocket server library (Vapor/Hummingbird/SwiftNIO) adds a large dependency graph and its own Swift 6 concurrency story for one endpoint.
- `NWProtocolWebSocket` has shipped in the OS since macOS 10.15 and supports server mode, subprotocols, ping/pong auto-reply, maximum message size, and per-message metadata for text/binary. Framing, masking and the HTTP upgrade are handled for us.
- `NWParameters.requiredLocalEndpoint` binds the listener to a specific local address, which is how we bind only to the Tailscale address (verified below with `lsof` and a LAN-side `nc`).
- Using `NWConnection` for the client avoids ATS (surprise 10) and gives one code path.
- Cost: a ~150-line `WebSocketPeer` wrapper turning a connection into `AsyncThrowingStream<Data, Error>` + `send(_:)`. **API detail to confirm during implementation:** whether the server-side `setClientRequestHandler` exposes request headers for an `Authorization` check at upgrade time. The plan does not rely on it: authentication is a first-frame `hello` with a 5-second deadline (below), which works regardless.

Rejected: `URLSessionWebSocketTask` for the client (ATS blocks `ws://` to MagicDNS names; would force an ATS exception), a hand-rolled RFC 6455 server on `NWListener` raw TCP (no reason to when the framework does it), SwiftNIO (dependency).

### 4a. Finding the Tailscale interface

**New:** `Core/ControlAPI/TailscaleInterface.swift`, `nonisolated enum TailscaleInterface`.
- `static func currentIPv4() -> String?`: `getifaddrs`; keep entries that are `IFF_UP`, `AF_INET`, name has prefix `utun`, and whose address is in `100.64.0.0/10` (Tailscale's CGNAT range). Return the first. (IPv6 `fd7a:115c:a1e0::/48` is possible later; Phase 1 is IPv4 only.) Free with `freeifaddrs` in a `defer`.
- Why not `tailscale ip -4`: the CLI path varies (App Store build, Homebrew, standalone) and spawning a process on a timer is brittle. Why not just `0.0.0.0`: that is exactly the exposure T9 forbids.
- `static func changes() -> AsyncStream<String?>`: an `NWPathMonitor` plus a 30-second recheck; yields the current address whenever it changes (including to `nil`).

**Behavior when Tailscale is absent:** the listener is not started and nothing falls back to a wider bind. `ControlServer` state becomes `.waitingForTailscale`; Settings (runtime mode) shows "Tailscale not detected: the Mac mini cannot be reached from your laptop. Start Tailscale." The app keeps working locally (panel, iMessage, scheduler). When the address appears, the listener starts; when it changes, the listener is torn down and rebuilt on the new address; when it disappears, all control connections are closed. **DEBUG builds only** (`#if DEBUG`) have a Settings switch "Bind to 127.0.0.1 for development" so client mode can be tested on one Mac. It does not exist in Release.

### 4b. Server

**New files in `Core/ControlAPI/`:**
- `ControlServer.swift`: `actor ControlServer`. Owns the `NWListener` (queue: a dedicated serial `DispatchQueue("ai.majoor.control")`), `connections: [UUID: ControlConnection]`, state enum (`stopped`, `waitingForTailscale`, `listening(address, port)`, `failed(Error)`). Port: fixed default `47821` (configurable; chosen to avoid the commonly used ports), stored in UserDefaults `controlPort`. Limits: max 4 concurrent connections, per-IP connect rate limit (10/min), max message 1 MB (`WebSocket.Options.maximumMessageSize`).
- `ControlConnection.swift`: `nonisolated final class` wrapping one `WebSocketPeer`. State machine: `.unauthenticated` (5-second deadline: no valid `hello` or `pair` frame closes the socket), `.authenticated(clientId)`. Any non-`hello`/`pair` frame while unauthenticated closes the connection. Ping every 20 s, close after 60 s silence. Decodes frames into `ControlMessage`, calls the `SessionGateway` (the local one), and forwards the `EventBus` stream.
- `ControlProtocol.swift`: the message types (below).
- `PairingManager.swift`: `actor PairingManager` (below).
- `WebSocketPeer.swift`: the `NWConnection`/server-connection wrapper (`AsyncThrowingStream<Data, Error>` receive, `send(Data)`, `close(code:)`), used by both server and client.

### 4c. Message schema (protocol v1)

JSON text frames. Envelope: `{ "v": 1, "id": "<uuid, client-chosen for requests>", "type": "<name>", "body": { … } }`. Server replies echo `id` as `replyTo`.

Client to server:

| `type` | `body` | Reply |
|---|---|---|
| `pair` | `{ code, deviceName }` | `pair.ok { clientId, token }` (token shown once) or `error` |
| `hello` | `{ clientId, token, appVersion, protocol: 1 }` | `hello.ok { runtimeId, serverVersion, seq, mode }` or `error { code: "unauthorized" }` then close |
| `subscribe` | `{ sinceSeq?: Int }` | `snapshot { sessions: [SessionInfo], pendingApprovals: [ApprovalRequest], recentTasks: [TaskSnapshot], settings, dayUSD }` then `event` frames; snapshot is sent when `sinceSeq` is absent or older than the ring |
| `submit` | `{ text, threadKey?, clientRequestId }` | `submit.ack { sessionId, shortId }` (idempotent on `clientRequestId` so a retry after reconnect cannot start the task twice) |
| `approval.answer` | `{ approvalId, nonce, decision: "approve"\|"deny", feedback?, skipSteps?: [Int] }` | `approval.ok` or `error { code: "bad_nonce" \| "unknown" \| "expired" }` |
| `stop` | `{ sessionId?: String }` | `stop.ok { stopped: [shortId] }`; omitted `sessionId` means STOP all |
| `sessions.list` | `{}` | `sessions { sessions: [SessionInfo] }` |
| `settings.get` | `{ keys?: [String] }` | `settings { values }` |
| `settings.set` | `{ key, value }` | `settings.ok` or `error` |
| `ping` | `{}` | `pong` |

Server to client (unsolicited): `event { seq, event: SessionEvent }` where `SessionEvent` is exactly the type from step 2 (session state, tool-call and tool-result steps, pipeline plan and steps, `approvalRequested`/`approvalResolved`, `cost`, `finished`); `error { code, message, replyTo? }`; `bye { reason }` (revoked, runtime shutting down).

**Settings allowlist (`settings.get`/`set`):** `permissionMode` (`PermissionMode.defaultsKey`), `maxConcurrentSessions`, `sessionTokenBudget`, `dailySpendCapUSD`, `showNotifications`. No secrets, no Keychain values, no file paths, no MCP config in Phase 1 (connectors, automations and VIP list over the API are Phase 2). **Security rule:** a client may *tighten* `permissionMode` (auto to standard to manual) but may not *loosen* it; loosening returns `error { code: "needs_local_approval" }` and must be done on the runtime itself. A compromised laptop must not be able to turn off approvals. Open question 3.

**Approvals over the API:** the nonce is delivered in `approvalRequested` and must be echoed in `approval.answer`. For the laptop UI this is invisible; its value is that any client holding only a stale or forged approval id cannot resolve a different approval, and the same field is what iMessage will type in step 7.

### 4d. Pairing and tokens

- On the runtime, Settings ▸ Control API ▸ "Pair a new client" calls `PairingManager.mintCode()`: an 8-character code from the unambiguous alphabet, valid 5 minutes, single use, held in memory only. The UI shows the code, the Tailscale address and the port.
- On the client (step 5), the user enters host, port and code. The client opens a connection and sends `pair { code, deviceName }`. The server checks the code in constant time, enforces at most 5 failed attempts per 15 minutes globally (then refuses `pair` until the window passes), burns the code, generates a 256-bit token with `SecRandomCopyBytes`, assigns `clientId` (UUID), stores `SHA-256(token)` plus name, createdAt, lastSeen, and returns the token once.
- Storage on the runtime: table `paired_clients(clientId TEXT PK, name TEXT, tokenHash BLOB, createdAt TEXT, lastSeenAt TEXT, revokedAt TEXT)` in migration `v6_control_clients_contacts` (with `contacts_policy` from step 3). Only the hash is stored.
- Storage on the client: `KeychainManager.shared.save(key: "majoor_runtime_token", value: token)` and `…_client_id` (existing API, `KeychainManager.swift:20`); host and port in UserDefaults.
- Auth on every connection: `hello { clientId, token }`; the server hashes and compares in constant time against the row, rejects revoked rows. Revoking from Settings sets `revokedAt` and closes that client's live connection with `bye`.
- Tailscale ACLs limit who can reach the port at the network layer (PRD T9); the token is the second factor.

### 4e. Lifecycle wiring

`AppDelegate` (runtime mode only): after `SessionManager` is configured, start `ControlServer`, subscribe it to `TailscaleInterface.changes()`. On `NSWorkspace.willSleepNotification` stop the listener, on `didWakeNotification` restart (the mini never sleeps by design, but laptops-as-runtime during development do). New Settings tab `Settings/ControlAPISettingsView.swift`: status, address, port, paired clients with Revoke, "Pair a new client".

### 4f. Risks

- **Exposure.** The server must never listen on anything but the Tailscale address. Verification is part of the step: `lsof -nP -iTCP:47821 -sTCP:LISTEN` must show the 100.x address only, and `nc -vz <LAN-IP> 47821` from another machine must be refused.
- **macOS Local Network privacy prompt** on first listener start (macOS 15+). On a headless mini this needs one click via screen sharing; document it in the setup checklist.
- Back-pressure: a stalled client must not grow memory without bound. The per-connection outbound queue is capped (drop-oldest for `step` events, never drop `approvalRequested`/`approvalResolved`/`finished`; on overflow close the connection and let the client resync from `snapshot`).
- Message-size and malformed-JSON handling: never crash on a bad frame; reply `error { code: "bad_request" }` and count strikes (close after 10).

### 4g. Verify

Unit tests: every `ControlMessage` encode/decode round trip; pairing code single-use and lockout; token hash compare; unauthenticated frame closes the connection (test against a loopback listener in DEBUG). Manual with `websocat` or a 20-line script over the tailnet: pair, hello, subscribe, submit "list files in ~/Desktop", watch events, answer an approval with a wrong nonce (rejected) then the right one, STOP. Confirm the LAN-side refusal above. Kill Tailscale: listener goes to `.waitingForTailscale`; restart Tailscale: it recovers without restarting the app.

---

## Step 5. Client mode in the same binary

> **Status: done 2026-10-31** (commit "feat: Client mode: the laptop drives a paired runtime over the control API"). As designed, with these notes: `AppMode` (default `local`) gates launch in `AppDelegate`; client mode configures the local `SessionManager` lazily on the first "Run here"; the control API is on by default in runtime mode and off by default in local mode. The remote pump is `SessionEventPump.startRemote(client:)` feeding `TaskManager.apply(event, source: "remote")` and `TaskManager.applySnapshot`, which replaces only remote tasks and approvals. Approvals route through `TaskManager.answerApproval` → `AppDelegate.routeApproval` (nonce over the API for remote sessions, local SessionManager otherwise), and the notification delegate uses the same router via `NotificationManager.approvalHandler`. A revoked or mismatched runtime puts the client in a terminal `.failed` state instead of retrying forever. `stop`/`/status`/`/stop N` typed in the bar are honored against the runtime. Unit tests: backoff schedule, seq cursor, snapshot replace, and a loopback lifecycle (pair, connect, submit, runtime restart, revoke). Not yet verified by hand: the two-Mac flow in 5e.

**Size:** ~700 new lines, ~250 changed, 2–3 days. **Depends on:** step 4 (and 3's `SessionGateway`).

### 5a. Mode selection

- `Core/AppMode.swift`: `nonisolated enum AppMode: String { local, runtime, client }`, stored in UserDefaults `appMode`, **default `local`** so existing installs behave exactly as 1.x (PRD G10: everything that works today keeps working). `local` = today (panel + local `SessionManager`, no server, no iMessage). `runtime` = local plus control server plus channels plus scheduler. `client` = hotkey, bar and panel talk to a remote runtime; the local runtime is *not started* unless "Run here" is used.
- `Settings/SettingsView.swift`: add a "Mode" section to `GeneralSettingsTab` (segmented picker next to the Permission mode picker at line 40) and a `Settings/ClientSettingsView.swift` tab shown in client mode: host, port, pairing code field, "Pair", connection status, "Forget this runtime". Changing mode shows "Restart Majoor to apply" with a Quit button (live switching is not worth the state-teardown risk).
- `AppDelegate.applicationDidFinishLaunching`: gate by mode. In client mode do not call `MCPServerManager.shared.startAll()` or the sleep/wake MCP observers (`AppDelegate.swift:42–59`); `MCPServerManager.ensureRunning` already lazy-starts servers for Run-here tasks. Runtime mode additionally starts the control server (step 4), iMessage (step 7) and scheduler (step 6).

### 5b. Remote gateway and connection state

**New files in `Core/ControlAPI/`:**
- `RemoteRuntimeClient.swift`: `actor RemoteRuntimeClient`. State machine `disconnected → connecting → authenticating → connected(runtimeId) → reconnecting(attempt)`. Reconnect with exponential backoff 1, 2, 4, 8, 15, 30 s (cap), reset on success, and reconnect immediately on `NSWorkspace.didWakeNotification` and on network path change (`NWPathMonitor`). After `hello.ok` it sends `subscribe { sinceSeq: lastSeq }`; the server replies with a `snapshot` if the gap is too large. Requests have a 10-second timeout; `submit` carries a `clientRequestId` UUID so a retry after a drop is idempotent.
- `RemoteSessionGateway.swift`: implements `SessionGateway` (step 3) on top of the client.
- `RuntimeConnectionModel.swift`: `@MainActor final class RuntimeConnectionModel: ObservableObject` publishing `state`, `runtimeName`, `lastError`, `dayUSD`. Drives the UI badge.

### 5c. UI changes

- **Command bar** (`UI/CommandBarView.swift`, `CommandBarWindow.swift`): submit goes through the active `SessionGateway`. A small status dot in the bar's hint row shows connected / reconnecting / unreachable. **Run here** is an explicit toggle pill next to the Task/Chat pill, persisted (`runHere`, UserDefaults), plus an inline prompt when a submit fails because the runtime is unreachable: "Mac mini unreachable. [Run here] [Retry]". It **never silently falls back**: local execution uses the laptop's files, credentials and identity, and a task meant for the mini must not quietly run with different authority. A task run locally is labeled "This Mac" in the feed.
- **Activity feed** (`UI/ActivityFeedView.swift`): unchanged structure. `TaskManager.apply(event)` (step 2e) is fed by `RemoteSessionGateway.events(since:)` instead of the local bus. On `snapshot`, `TaskManager` replaces its remote task list with `recentTasks` (client mode does not read the laptop's own SQLite `tasks` for remote work; local Run-here tasks are still persisted locally). `TaskCardView` gets a small origin chip: "Mac mini" or "This Mac" (add `var source: String = "local"` to `AgentTask`; default keeps persistence-restored tasks as local).
- **Approvals** (`UI/ConfirmationSheet.swift`, `Core/NotificationManager.swift`): `approvalRequested` events from the remote add to `pendingApprovals`; Approve/Deny call `gateway.answerApproval` with the nonce. In client mode the laptop posts the macOS notification itself on `approvalRequested` (the runtime's notification fires on the mini, not here) and its action buttons route to the gateway. R3 approvals work from the laptop (PRD §5.4). Pipeline step toggles go back as `skipSteps`.
- **Panel toolbar** (`UI/MainPanelView.swift`, `panelToolbar`): add the connection badge and a **STOP** button (stops all sessions via `gateway.stop(nil)`), always visible when anything is running. Menu bar menu in `StatusBarController` gets a "Stop all" item.
- **Chat mode** is unchanged: `ChatManager` still streams from the laptop with the laptop's Keychain key.
- **Settings read/write** (PRD §5.4 "settings on the laptop edit the runtime's configuration remotely"): in client mode the Permission mode picker in `GeneralSettingsTab` reads and writes through `settings.get/set`; loosening shows the runtime's `needs_local_approval` error as inline text.

### 5d. Risks

- Event ordering and duplicates after reconnect: dedupe by `seq` on the client; apply `snapshot` atomically on the main actor.
- `TaskManager` double-writes if a Run-here task and a remote task share an id: ids are UUIDs minted by whoever starts the session; collisions are not possible in practice.
- A client that connects to the wrong runtime (stale host): `hello.ok` returns `runtimeId`; the client stores the first one and warns loudly if it changes.
- The laptop's local `SessionManager` exists in client mode only for Run-here; make sure it is created lazily so launching in client mode does no runtime work.

### 5e. Verify

Dev loop on one Mac: runtime-mode instance and client-mode instance can run as the same app with different `UserDefaults` domains (launch with `-appMode client -controlPort …` arguments, which UserDefaults reads from the command line) against the DEBUG loopback bind. Then the real two-machine check: hotkey on the laptop, "list files in ~/Desktop", it executes on the mini (verify with a `get_file_info` result that is mini-specific), feed updates live, trigger `delete_file` and approve from the laptop, start a task from the panel and see it from a second client, quit the mini app mid-task (client shows reconnecting, then the interrupted session as failed after restart), unplug Tailscale (bar shows unreachable, "Run here" offered, nothing runs locally until clicked), STOP from the laptop. Unit tests: reconnect backoff schedule with a fake clock; `seq` dedupe; snapshot replace.

---

## Step 6. `automations` table and one-shot reminders

> **Status: done 2026-10-31** (commit "feat: Automations table, scheduler and one-shot reminders"). As designed: migration `v7_automations` with the full PRD shape and the `(enabled, nextRunAt)` index; `AutomationStore.claimDue` is one write transaction (tested with four concurrent claimers); `AutomationScheduler` is one timer behind a `SchedulerClock` seam, re-armed by `wake()` (create/cancel, system wake, `NSSystemClockDidChange`), with launch catch-up, the "(missed, was due …)" prefix past 24 h, stale-claim release after 2 min, 60 s retries up to 5 then `delivery_failed` plus a local notification. A fired reminder is recorded through `SessionManager.recordJob` (a `job` session with no model call) so it appears in the feed and history. Tools `create_reminder` / `list_reminders` / `cancel_reminder` (40 tools; CLAUDE.md and README updated), prompt rule 16, time zone appended to the date context. Delivery: `imessage` origin → `ChannelRouter.send` (throws when the channel is not registered, so it retries until step 7's channel exists); panel/control origin → local notification plus a panel toast. Runs in local and runtime modes only. Not yet verified by hand: the sleep/wake and clock-change re-arm on a real Mac.

**Size:** ~450 new lines, 1.5 days. **Depends on:** step 3 (delivery), step 2 (`SessionContext`, `job` kind). Independent of 4 and 5.

### 6a. Schema

`Core/Database/DatabaseManager.swift`, migration `v7_automations`: create the **full** PRD §5.3 shape now so Phase 2 needs no `ALTER`: `automations(id TEXT PK, name TEXT, kind TEXT, scheduleKind TEXT, runAt TEXT, cron TEXT, activeHours TEXT, inputSources TEXT, prompt TEXT, scratch TEXT, tier TEXT, deliveryChannel TEXT, deliveryThread TEXT, urgencyCeiling INTEGER, riskCeiling TEXT, enabled INTEGER, nextRunAt TEXT, claimedAt TEXT, createdAt TEXT, createdBySession TEXT, lastRunAt TEXT, lastResult TEXT)` with an index on `(enabled, nextRunAt)`. Phase 1 uses only: `id, name, kind='reminder', scheduleKind='once', runAt/nextRunAt, prompt (the reminder text), deliveryChannel/deliveryThread, enabled, claimedAt, lastRunAt, lastResult`. `cron`, `activeHours`, `inputSources`, `tier` etc. stay null. The Phase 1 scheduler **ignores** rows with `scheduleKind != 'once'` and logs them.

**New:** `Core/Automation/AutomationStore.swift` (`nonisolated final class`, GRDB, same pattern as `TaskPersistence`/`UsageStore`): `insert`, `cancel(id)`, `listUpcoming(limit)`, `claimDue(now) -> [AutomationRecord]` (a single transaction: select enabled rows with `nextRunAt <= now` and `claimedAt IS NULL`, set `claimedAt = now`, return them: this prevents double fire if two timers race), `markDelivered(id)`, `releaseClaim(id)` (on delivery failure), `staleClaims(before:)` (for crash recovery).

### 6b. Scheduler

**New:** `Core/Automation/AutomationScheduler.swift`, `actor AutomationScheduler`, with a `Clock` seam (`protocol SchedulerClock { func now() -> Date; func sleep(until:) async throws }`, real implementation uses `Task.sleep(for:)`) for tests.
- One timer task, not one per row: sleeps until the earliest `nextRunAt`, wakes, calls `claimDue`, fires each, re-arms. `wake()` re-arms immediately when a reminder is created or cancelled, on `NSWorkspace.didWakeNotification`, and on `NSNotification.Name.NSSystemClockDidChange`.
- **Launch catch-up:** at start, rows with `nextRunAt` in the past fire immediately. If overdue by more than 24 hours the message is prefixed "(missed, was due <time>)"; reminders are at-least-once, so stale claims left by a crash (`claimedAt` older than 2 minutes with no `lastRunAt`) are released and re-fired.
- **Firing a one-shot:** spawn a `job` session via `SessionManager` with no model call (the reminder text is the output): it publishes `created` and `finished` events (so it shows in the feed and in `/status` history), then delivers.
- **Delivery rule:** deliver to `deliveryChannel`/`deliveryThread` if that channel is `imessage` (offline-safe). If the origin was the panel or a control client (ephemeral), deliver via iMessage when the iMessage channel is enabled, else a local macOS notification plus an event to any connected client. A failed send releases the claim and retries after 60 s, up to 5 tries, then marks `lastResult = "delivery_failed"` and posts a local notification.
- Active hours do not apply to a reminder the owner explicitly asked for (PRD: active hours govern *proactive* messages). Document this so Phase 2 does not "fix" it.
- Runs in `local` and `runtime` modes, not in `client` mode.

### 6c. Creating a reminder from a channel message

**New tool:** `Tools/ReminderTools.swift` with `nonisolated struct CreateReminderTool: AgentTool`, `ListRemindersTool` (read-only), `CancelReminderTool`. Follow the `SaveMemoryTool` pattern in `Tools/MemoryTools.swift`.
- `CreateReminderTool` parameters: `message` (string, required), `delay_minutes` (integer as string, optional), `when` (local time `yyyy-MM-dd'T'HH:mm`, optional); exactly one of `delay_minutes`/`when` is required. Computation is done in code: `delay_minutes` is added to `Date()`; `when` is parsed with the same format list `CalendarTools.parseDate` uses (copy the small helper into the reminder file; do not make that private function shared).
- It reads `SessionContext.current` for `origin` and stores the delivery fields. If there is no context (a tool test), it falls back to the owner's primary channel.
- `requiresConfirmation = false`; it writes only Majoor's own state (R0, PRD §9). It is not `isReadOnly`, so **Manual mode will prompt** for it, same as `save_memory` (`MemoryTools.swift:20` has no `isReadOnly`); acceptable, and called out in the open questions.
- Registration: add the three tools to `ToolRegistry.defaultTools()` (`ToolProtocol.swift`, "Long-Term Memory" group becomes "Memory and reminders"). Tool count becomes 40; update the "37 tools" statements in `CLAUDE.md` (docs-sync).
- Prompt support in `Core/AgentLoop.swift`: add rule 16 to `systemPrompt` ("For reminders use create_reminder. Prefer `delay_minutes` for relative times. Never use the calendar for reminders unless asked."), and **add the time zone to `dateContext`** (line 115: append ` (\(TimeZone.current.identifier))`). Surprise 9.
- Why a tool and not a regex in the router: the tool path reuses the loop, memory and routing, handles phrasings like "tomorrow morning" or "remind me when I land" gracefully (asks or declines) and needs no second parser to maintain. Cost: a few seconds and a Sonnet call per reminder. A deterministic fast path for the single most common form ("remind me in N minutes/hours to …") can be added in `ChannelRouter` later if latency matters (open question 8); it is not needed for the exit criterion.

### 6d. Risks and verification

- Clock changes and sleep: covered by `NSSystemClockDidChange` and wake re-arm. Test by setting a reminder 2 minutes out, sleeping the Mac, waking after it is due: it fires on wake.
- Double fire: covered by `claimDue` transaction; test by calling `claimDue` twice concurrently.
- Timezone mistakes: the tool takes local time and the prompt now states the zone; test "remind me at 5pm" in a different system zone.
- Tests: `AutomationStore.claimDue` semantics; scheduler with a fake clock (fires in order, catches up after a simulated gap, re-arms on insert); `CreateReminderTool` argument validation (neither/both arguments, negative delay, past `when`).
- Manual: from the panel "remind me in 2 minutes to stand up" (notification fires), then from iMessage after step 7, then quit and relaunch with a pending reminder (still fires), cancel via "cancel my reminder".

---

## Step 7. iMessage channel via `imsg rpc`

> **Status: done 2026-10-31** (commit "feat: iMessage channel over imsg rpc"). As designed, with these notes from `docs/json.md`: the message object carries `sender`, `text`, `is_from_me`, `created_at`, `guid`, `chat_id`, `is_group`, optional `type` (edited/unsent) and `is_reaction`; **`service` is on the chat, not the message**, so the channel fetches `chats.get` once per chat and requires `service == iMessage` and `is_group == false` with the owner as the only participant. `send` takes `service: "imessage"` and `allow_sms_fallback: false`. The existing `Core/Runtime/JSONValue.swift` is reused rather than a second JSON type; `MCPClient.resolveCommand` became internal `static` (one-word edit). On a first run with no saved row id the watch starts at the tail (no replay of the whole chat.db). The router's approval prompt is plain text with the expiry. `ask()` keeps the default no-answer implementation (Phase 2). Settings ▸ Channels (runtime mode) holds the enable toggle, owner handle, helper path/version, row id, stale window and a test send. Not yet verified by hand: nothing here has talked to a real `imsg` (it is not installed on this Mac); the loopback tests use a scripted transport and a Python JSON-RPC echo child. The manual checklist in 7g stands.

**Size:** ~800 new lines, 3 days. **Depends on:** step 3 (channel, trust), step 2 (approvals with nonces). Independent of 4–6.

### 7a. What `imsg rpc` gives us (from its docs, `openclaw/imsg` `docs/rpc.md`)

- Transport: one JSON object per line on stdin/stdout, `"jsonrpc": "2.0"`, named-object `params` only, **unknown keys are rejected with `-32602`**, so send exactly the documented keys.
- Methods used: `initialize { protocol_version: 1 }` (returns the `status` snapshot including `database.ready`), `chats.get { chat_id }` (returns `is_group`, `participants`, `identifier`, `service`), `messages.after { since_rowid, limit, chat_id? }` (returns `{messages, next_rowid, has_more}`: the replay cursor), `watch.subscribe { since_rowid }` (returns `{subscription, buffer_limit}`; **new messages arrive as notifications** with method `message` and `params: { subscription, message }`; overflow arrives as `watch.overflow { resume_after_rowid, terminal: true }`), `send { to, text, service: "imessage", allow_sms_fallback: false }`.
- Message fields confirmed by the docs: `id`, `guid`, `chat_id`, `is_from_me`, `created_at`, reaction fields (`is_reaction`…). **Not confirmed** by the page I could read: the exact names of the sender-handle, text and service fields. The implementer must read `docs/json.md` first (listed in open questions) and not guess.
- Permissions: Full Disk Access for reading `chat.db` and Automation → Messages for sending. Because Majoor spawns `imsg` as a child process, macOS attributes the TCC checks to the responsible app: **grant Full Disk Access and Automation to `Majoor.app`** and verify that this is sufficient (if it is not, grant to the `imsg` binary too). Install with `brew install steipete/tap/imsg` (resolve the path with the same search `MCPClient.resolveCommand` uses).

### 7b. JSON-RPC line client (the "thin sibling of MCPClient")

`MCPClient` cannot be reused as is: it hard-codes the MCP `initialize`/`tools/*` methods, uses `[String: Any]`, and ignores server notifications (surprise 7). It also should not be refactored in Phase 1 (an MCP regression would take down GitHub, Slack, Notion and Linear tools). So:

**New:** `Core/Channels/IMessage/JSONRPCLineClient.swift`: `actor JSONRPCLineClient`. Reuses the *technique*, not the class: `Process` with three pipes, `Task.detached` reader doing blocking `availableData` off the actor, a byte buffer split on `0x0A`, `pending: [Int: CheckedContinuation]` with per-request timeout tasks, `failAllPending` on EOF.
Differences from `MCPClient`, each a deliberate fix:
- A Sendable JSON type: `nonisolated indirect enum JSONValue: Sendable, Codable` (null, bool, number, string, array, object) in `Core/Channels/IMessage/JSONValue.swift`, instead of `[String: Any]`. (Also the proper fix for step 1 category F when `MCPClient` is next modified.)
- Server notifications are surfaced: `notifications: AsyncStream<(method: String, params: JSONValue)>`.
- Buffer handling: cap the line buffer (e.g. 4 MB) and drop-and-resync on overflow; `MCPClient` does `buffer = Data(buffer[index...])` per line, which is quadratic on large bursts: use an index cursor and compact occasionally.
- Reuse only the PATH helpers: make `MCPClient.augmentedPath(existing:)` (already `static`, internal) the shared source, and change `resolveCommand` from `private static` to `static` (a one-word edit in `MCPClient.swift`); everything else in `MCPClient` stays untouched.
- Framing is pure and tested in isolation: `NewlineJSONFramer` (`nonisolated struct`) with `mutating func push(_ data: Data) -> [Data]` handling partial lines, multiple lines per chunk, empty lines, non-JSON lines.

### 7c. The channel

**New:** `Core/Channels/IMessage/IMessageChannel.swift`: `actor IMessageChannel: Channel` (the protocol is `Sendable`; actors qualify).
- Lifecycle: resolve binary; start; `initialize`; check `database.ready` (if false, surface "Grant Full Disk Access to Majoor" in Settings and a local notification, and stay stopped); load `lastRowId` (stored in the `contacts_policy`-adjacent key-value table: use a `settings_kv` row, or UserDefaults `imessageLastRowId`, whichever the implementer prefers; one value); replay then watch (below).
- Supervision: same shape as `MCPServerManager.monitorServer`: on process exit, restart with backoff 5, 10, 20, 40, 80 s, give up after 5 and post a local notification. After any restart or launch, text the owner "Majoor is online (vX.Y)" (PRD §14 "Majoor texts you after any restart"); keep it to one line and rate-limit to one per 10 minutes so a crash loop does not spam.
- **Inbound pipeline** (this is where owner-only trust lives):
  1. Ignore anything with `is_from_me == true` (our own sends appear in `chat.db`; without this the agent talks to itself) and any reaction/edit/unsend event.
  2. Fetch the chat once with `chats.get` and cache by `chat_id`. **Accept only direct chats** (`is_group == false`) whose single participant is the owner. A group chat that contains the owner is rejected (anyone in it could inject text).
  3. Accept only `service == iMessage` (Apple-authenticated sender identity). SMS/RCS (spoofable sender) is rejected for commands, per PRD T2.
  4. Normalize the sender handle (E.164 for phone numbers, lowercase for emails) and compare to `TrustPolicy` owner. **Non-owner messages never reach `SessionManager`.** Phase 1 drops them, logs a count only (not the content), and does nothing else; the restricted relay persona (PRD T1) is deferred to Phase 2. Message text from a non-owner is treated as data and never concatenated into a prompt.
  5. Per-sender rate limit (e.g. 10 messages per minute) to bound cost (PRD T5).
  6. Yield `InboundMessage(channelId: "imessage", threadKey: "imessage:<handle>", …)` on `inbound`. The router then calls `SessionManager.handleInbound(..., trust: .remoteText)`, which applies the Auto-mode downgrade (step 2c item 7).
- **Replay safety (important):** on startup call `messages.after(since_rowid: lastRowId)` in a loop while `has_more`, de-duplicating by `guid`. Messages older than **10 minutes** (configurable; open question 6) are *not executed*; the owner gets one summary text ("I was offline and missed 2 messages from 08:12 to 08:40. Send them again if you still want them."). Executing stale commands after an outage ("delete the build folder" from four hours ago) is exactly the failure an unattended agent must not have. Then `watch.subscribe { since_rowid: lastRowId }`; persist `lastRowId` after each message is *handed to the router*, not before. On `watch.overflow`, resume with `messages.after` from `resume_after_rowid`.
- **`send(to:text:attachments:)`:** `send { to: <handle>, text, service: "imessage", allow_sms_fallback: false }`. Plain text only (PRD §5.4 limits with SIP on); chunk long replies at about 1,500 characters on paragraph boundaries and cap at 6 chunks with "…full result is in the Majoor panel". Strip nothing from the model's text except to enforce the cap, but **never echo raw untrusted tool output into an approval message without labeling** (see below).
- **`ask(question:options:timeout:)`:** sends the question and registers a pending question keyed to the owner thread; the next owner message that matches an option (or, for approvals, the nonce) resolves it; on timeout returns `Answer(timedOut: true)`.

### 7d. Approvals over iMessage (nonce protocol)

`SessionEventPump`-style subscriber in the channel: on `approvalRequested` for a session whose origin is `imessage` (or when the owner has no UI client connected), send:

```
Majoor wants to: send_email
To: alice@example.com
Subject: Q3 numbers
Body: Hi Alice, attaching the…
Reply "yes K7Q2" to approve, "no K7Q2 <note>" to decline. Expires in 10 min.
```

- Parsing (`ApprovalReplyParser`, pure, `nonisolated`): case-insensitive; `yes|y|approve` or `no|n|deny` followed by the 4-character nonce, anything after a `no` is the feedback note (goes back to the model as the tool result feedback, as `ConfirmationResult.feedback` does today). A bare "yes" without the nonce does **not** approve; it gets a reply "Include the code: yes K7Q2". When several approvals are pending, the nonce selects which one.
- The reply path calls `SessionManager.answerApproval(id:nonce:decision:channel: "imessage")`, which is the same code path as the laptop. Wrong nonce is rejected (step 2d).
- Channel floor (PRD §9): R3 approvals may be answered from `imessage` and the panel/laptop; Phase 1 has no voice channel, so there is nothing to forbid yet, but `ApprovalRequest.riskClass` and `byChannel` are recorded so Phase 3's rule is a one-line check.
- Untrusted content in the approval text: the body shown to the owner is built from tool arguments (which may contain text from an email the model read). Truncate each field (the same caps `AgentLoop` uses: identity keys 500, content keys 400) and strip control characters; the owner is the final check, but the prompt must not let injected text imitate the approval format. Render the nonce line last and from code, never from model text.

### 7e. Owner configuration

Settings ▸ Channels (new `Settings/ChannelsSettingsView.swift`): enable iMessage, owner handle field (validates and normalizes), shows `imsg` path/version and `database.ready` status, a "Send test message" button, last-rowid and the missed-message policy. Runtime mode only.

### 7f. Risks

- Apple changes break `chat.db` reading: accepted risk (PRD §14), mitigated by `imsg`'s community and a clear degraded-state UI.
- Sending to a handle that never messaged Majoor may fail with SIP on (PRD §5.4): the owner texts first; `send` errors are surfaced to the owner's other channels and logged.
- Process leaks: ensure `imsg` is terminated on app quit (`applicationWillTerminate`, `AppDelegate.swift:~100`) and on mode change; use `Process.terminate()` then SIGKILL after 2 s.
- Duplicate processing: the `guid` de-dup set plus persisted `lastRowId`; persisted after handoff means a crash between handoff and persist can re-deliver one message: `SessionManager.submit` dedupes on `(channelId, guid)` for 10 minutes.
- Group chats, attachments, tapbacks, edits: ignored in Phase 1.

### 7g. Verify

Unit tests: `NewlineJSONFramer` (partial and coalesced lines), `ApprovalReplyParser` table (valid, missing nonce, wrong case, feedback text, two pending), handle normalization, inbound filter matrix (from-me, group chat, SMS, non-owner, owner, stale), replay with a fake `JSONRPCLineClient`. Manual on the Mac mini (or any Mac with a second Apple ID): text "what's on my calendar today", get a reply under 30 s; text a task that triggers `send_email`, receive the approval text, reply with the wrong nonce (rejected), then correct; `no K7Q2 use a different subject`; `STOP` while a task runs; `/status`; text from a second (non-owner) Apple ID and confirm nothing happens and no content appears in logs; kill `imsg` (it restarts); stop Majoor, send a message, restart, confirm the stale-message policy; "remind me in 20 min to check the oven" arrives as an iMessage 20 minutes later.

---

## Scalability and operational notes

- Event fan-out is bounded (ring of 1,000, per-subscriber buffers, per-connection outbound caps). Cost control is per-session token budget plus the daily dollar cap, checked in the loop.
- SQLite: all new writes are small single-row upserts through the existing `DatabaseQueue` (WAL mode); `sessions` and `approvals` grow slowly; add `deleteOldSessions(olderThan: 90)` next to the existing 30-day task cleanup in `TaskManager.init`.
- No new dependencies. Network.framework, Foundation, GRDB, CryptoKit (`SHA256`, already used in `MCPServerManager`), Security (`SecRandomCopyBytes`).
- Headless operations checklist for the Mac mini (not code): auto-login, never sleep, Tailscale up before Majoor, FDA and Automation granted to `Majoor.app`, Local Network prompt accepted, `imsg` installed, Apple ID signed into Messages, LaunchAgent with KeepAlive.

---

## Open questions for Kush

1. **Swift 6 timing.** OK to wait for the Phase 0 commit before step 1 (it touches the same `project.pbxproj`), or do you want Phase 0 committed in pieces first?
2. **Test target.** Will you create `MajoorTests` in Xcode (I recommend Swift Testing, app-hosted)? I will not hand-edit the target in `project.pbxproj`.
3. **Remote loosening of the permission mode.** The plan lets a client tighten the mode but not loosen it (needs action on the mini). Is that the right rule, or should loosening be allowed with an iMessage approval?
4. **Concierge.** Phase 1 keeps the `concierge` kind in the enum but runs every non-command message as a task, as 1.x does. Is that acceptable for the exit criteria, or do you want the fast read-only concierge now?
5. **Budgets.** Placeholder defaults are 2,000,000 tokens per session, $25 per day, 3 concurrent sessions. What numbers do you want? (The loop does not use prompt caching, so context is re-sent every iteration.)
6. **Stale-message policy.** After an outage, messages older than 10 minutes are summarized, not executed. Right threshold, or should some commands (STOP, `/status`) always be honored regardless of age? (The plan says: STOP is always honored if it is the newest message.)
7. **STOP and running shell commands.** Accept a worst case of about 2 minutes until a shell command ends, or schedule the `ShellTools.swift` process-registry change (step 2f) immediately after Phase 0 lands?
8. **Reminder latency.** Reminders go through the model (a few seconds, one Sonnet call). Add a deterministic "remind me in N minutes to …" fast path now, or after you have used it?
9. **Manual mode and reminders/memory.** In Manual mode `create_reminder` and `save_memory` will prompt (they are not read-only). Mark them non-prompting as R0, or leave Manual strict?
10. **imsg fields.** I could not confirm the sender, text and service field names from `rpc.md` alone; the implementer will read `docs/json.md` first. Also: do you want `/pair` (owner texts `/pair`, the mini replies with a one-time code) as a convenience for a headless mini, accepting that the code travels over iMessage?
11. **Run here semantics.** The plan requires an explicit click each time or a persistent toggle, never an automatic fallback. Confirm.
12. **Approval UX with several pending.** The panel shows one sheet at a time with a "1 of N" badge. Is a list view needed in Phase 1?

---

## Phase 1 exit criteria (PRD §12) mapped to steps

| Exit criterion | Satisfied by |
|---|---|
| Swift 6 language mode flipped at the start of Phase 1 (D7) | Step 1 |
| Session runtime behind a control API; per-session confirmations; kill switch; `/status`, `/stop <id>`, `STOP` | Steps 2, 3 (commands via any channel), 4 (STOP over the API) |
| Approvals with nonces; owner-only trust | Step 2d (nonce, expiry, audit), step 7c/7d (owner filter, iMessage approval format), step 4c/4d (nonce echo, pairing) |
| From your phone: text Majoor a task, it does it | Steps 3, 7 |
| "It asks before anything R3" | Step 2c (risk class from `ConfirmationPolicy.isSensitive`), 7d (approval over iMessage) |
| "`STOP` works" | Steps 2d (`stopAll`), 7 (exact-match command from iMessage); known gap: running shell command ends at its timeout (2f) |
| "Remind me in 20 min" works; first automation job | Step 6 (+ step 7 for iMessage delivery) |
| From your laptop: hotkey, type a task | Steps 3, 5 |
| Watch it run on the Mac mini in the activity feed | Steps 2e (event mirror), 4 (event stream), 5c |
| Approve it from the laptop (including R3) | Steps 4c (`approval.answer`), 5c |
| Run-here fallback | Step 5c |
| Control API bound only to Tailscale, pairing token in Keychain, revocable | Steps 4a, 4d, 5c (`KeychainManager`) |
| Mac mini setup (dedicated user, Apple ID, auto-login, no sleep, Tailscale, FDA/Automation) | Not code; the operations checklist above |
| First tests for the runtime boundary (PRD §14 mitigation) | Step 0.5 and the tests listed in steps 2 to 7 |

## Deliberately deferred to Phase 2 and later

- Automations beyond one-shot: cron schedules, active-hours enforcement, event sources (`EventSource` protocol, Gmail/EventKit/Slack/filesystem), `events` table, escalation ladder, per-job delivery policy and `no_change` results.
- Trust ledger and R1/R2 auto-promotion; `contacts_policy` VIP column and trust levels beyond `owner`; the restricted relay persona for non-owner senders.
- A real concierge session (fast read-only answers, spawn-task tool); the `ask_owner` model tool ("I'm blocked" questions) and a multi-option `ask` UI.
- Router v2, data classes, tiers L and P, `OpenAICompatibleProvider`.
- Process registry so STOP kills child processes (step 2f, small follow-up once Phase 0 lands).
- SMS fallback, voice, location, connector registry and remote MCP, self-improvement, third-party calls.
- iMessage attachments, groups, tapbacks; linking `imsg` as a Swift package instead of a subprocess.
- Daemon split (`majoord`), remote editing of connectors, automations, VIP list and active hours over the control API, live mode switching without restart, TLS on the control API (tailnet encryption is relied on in Phase 1).

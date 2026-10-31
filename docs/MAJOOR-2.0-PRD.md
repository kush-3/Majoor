# Majoor 2.0: Product Requirements Document

**Status:** Draft v0.3. Decisions D1–D7 recorded on 2026-10-31 (§13); the laptop client added as G10 the same day. Three small items remain open.
**Date:** 2026-10-31
**Owner:** Kush Patel

---

## 1. Summary

Majoor 1.x is a menu-bar assistant you type into on your laptop. Majoor 2.0 is an always-on personal agent that lives on a dedicated Mac mini, has its own identity (its own Apple ID for iMessage and a Twilio number for calls), watches your email, calendar and Slack, knows where you are when you let it, and keeps you informed without being asked. It messages you, calls you when something is urgent, drafts replies in your voice for approval, acts on its own for low-risk work, takes engineering instructions by text or by phone call, and, with approval, calls other people for narrow tasks like booking an appointment. It routes work across three privacy tiers: a small local model on the Mac mini for perception, a zero-retention open-weight model in the cloud for personal reasoning, and Anthropic's frontier models for engineering only, through Claude Code under your Max subscription. It can propose, build, test and install changes to itself, never without approval. The hotkey command bar and menu bar app you use today stay on your laptop and become a window onto the Mac mini: they send tasks, show every session live, and take approvals.

The guiding idea: **Majoor is a Mac-native, security-first specialist. OpenClaw is the cross-platform generalist.** Majoor's edge is native macOS depth (Messages, Calendar, Contacts, MapKit, Keychain, Shortcuts), a written permission policy with real enforcement, and a single Swift binary you can read end to end.

## 2. Goals and non-goals

### Goals

| ID | Goal | Measure of done |
|----|------|-----------------|
| G1 | Reachable by iMessage and phone, 24 hours a day | Text Majoor from your phone; get a reply within 30 s; call it and talk to it |
| G2 | Proactive | Runs the behaviors in §8 on its own; escalates to a call for owner-defined urgent events; respects active hours |
| G3 | Acts across the Mac mini, GitHub, Slack, Google accounts, and any new service | Adding a service is a config entry plus an OAuth click, not code |
| G4 | Privacy-tiered model routing under the Strict preset | Every request carries a data class; only code reaches Anthropic; personal data stays local or on a zero-retention tier |
| G5 | Owner approves irreversible actions; low-risk actions run autonomously | A written risk policy (§9) decides, not vibes; every decision is logged |
| G6 | Improves itself | Can propose, build, self-test and install a change to its own code, gated on approval, with automatic rollback |
| G7 | Can contact third parties for narrow tasks | Books an appointment by phone with AI disclosure at the start of the call |
| G8 | Location-aware with consent | Knows where you are via your iPhone, and tells you when you are not where your calendar says you should be |
| G9 | Engineering by conversation | You text or call Majoor to describe a change to a codebase, or a new one, and it drives Claude Code and reports back |
| G10 | The laptop app stays, and gets better | The hotkey command bar and menu bar app on your laptop send tasks to the Mac mini, show what every session is doing live, and take approvals; everything that works today keeps working |

### Non-goals for 2.0

- Multiple owners or tenants. One owner.
- Any public internet exposure of a port on the Mac mini. Remote access is Tailscale only; the single webhook endpoint for voice goes through a tunnel with signed requests.
- Replacing Claude Code as the coding tool. Majoor orchestrates it.
- Running the runtime on Linux or Windows.
- WhatsApp, Telegram, Signal, Discord channels.
- Disabling System Integrity Protection to unlock iMessage private-API features. Not on a box with shell access and your credentials.
- Proactive CI, PR and dependency monitoring. Decided out for 2.0: engineering is on demand (G9), not watched.
- Scraping Find My. Its on-disk cache has been encrypted since macOS 14.4 and reading it would need your Apple ID on the box.

## 3. Where 1.x stands and why it cannot simply be extended

What 1.x is (verified against the code on 2026-10-31):

- A menu-bar GUI app. The agent loop runs inside the app process. There is no daemon, no API, no headless mode.
- One task at a time. `ConfirmationManager` already keys continuations by id; what serializes everything is the `isTaskRunning` guard in `AppDelegate`, the single-slot UI state in `TaskManager`, and the one shared `conversationHistory` in `AgentLoop`. A second request while one is waiting for approval has nowhere to go.
- Purely reactive. Nothing runs unless you type. There are no event sources, no scheduler, no jobs.
- Confirmations are macOS notifications and a sheet in the panel. They assume you are sitting at the machine.
- MCP client is stdio only. No remote (HTTP) MCP servers, so no MCP-standard OAuth.
- Model provider speaks the Anthropic wire format only. No local or OpenAI-compatible endpoint.
- Compiles in Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; isolation bugs are warnings.
- About 12,700 lines of Swift, 37 tools, no tests.

Structural gaps that 2.0 must close, each mapped to a workstream in §5:

| Gap | 2.0 workstream |
|-----|----------------|
| Single blocking loop | Session runtime (§5.2) |
| No event sources or scheduler | Automation jobs and event sources (§5.3) |
| GUI-bound confirmations | Channel-aware approvals with nonces (§5.4, §9) |
| UI lives in the same process as the loop | Control API and client mode for the laptop app (§5.4) |
| stdio-only MCP, no OAuth | Connector registry with remote MCP (§5.6) |
| Anthropic-only provider | Provider abstraction and privacy tiers (§6) |
| No self-update path beyond Sparkle releases | Self-improvement pipeline reusing Sparkle (§10) |

**Hard prerequisites before anything runs unattended with shell access.** Known open bugs in 1.x that go from "annoying" to "dangerous" once the agent reads untrusted inbound content 24/7:

1. `execute_shell` bypasses the whole sensitive-action gate: `git push`, `gh pr create` and `rm` through the shell tool skip the confirmations that `git_push`, `git_create_pr` and `delete_file` enforce. `write_file` plus `chmod +x` plus `./x.py` bypasses the script gate. Close it with command-level classification of shell input into the risk classes of §9.
2. Google OAuth has no `state` parameter and no PKCE.
3. `fetch_webpage` has no host allowlist (SSRF into Tailscale-reachable services, then prompt injection from the fetched content).
4. The truthful-loop change (`0e6ae04`) has never been run against the live API. An unattended agent that reports success for work it did not do is worse than one that fails loudly. Gate T1 first.

## 4. Options considered

| | A. Extend Majoor into an always-on runtime | B. Hybrid: OpenClaw as the channel gateway, Majoor as a tool backend | C. Fork OpenClaw |
|---|---|---|---|
| Time to first iMessage demo | 2–4 weeks after the Mac mini arrives | Days | Days, then months of learning a 100k+ line TypeScript codebase |
| Fit with G1–G9 | Full, by construction | iMessage and jobs for free; permission model, EventKit, MapKit, Keychain, voice and self-build still need Majoor work; two runtimes to keep in sync | Full feature surface, but you own a fork of a fast-moving project and lose the Swift core |
| Security posture | Yours to design; single process, no exposed gateway | Two trust boundaries; OpenClaw's early-2026 exposed-gateway incidents are the cautionary tale | Inherit OpenClaw's surface area |
| What it does for the open-source project | Majoor becomes a distinct thing | Majoor becomes a plugin | Majoor stops existing |

**Decided: A.** No OpenClaw trial (D6). Instead, §5.3 and §8 take what OpenClaw learned about proactive agents from its documentation: scheduled work belongs in independent jobs, each with its own cadence, active hours and delivery policy; a job with nothing to say returns a no-change result rather than a message; and inferred follow-ups were removed from OpenClaw in v2026.8 because of false positives, so Majoor's follow-ups are explicit and gated to a VIP list.

## 5. Architecture

### 5.1 Topology

```
┌──────────────────────────────── Mac mini M6, 32 GB (dedicated) ───────────────────────────┐
│  macOS user "majoor" (auto-login, never sleeps, FDA + Automation granted)                  │
│  Apple ID: majoor@<your-domain>  (Messages.app signed in)                                  │
│                                                                                           │
│  Majoor.app (LaunchAgent, KeepAlive)                                                      │
│  ┌──────────────┐  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐         │
│  │  Channels    │  │  Automations     │  │  Session runtime │  │  Policy       │         │
│  │  iMessage    │  │  jobs (cron,     │  │  concierge/thread│  │  risk classes │         │
│  │  Voice       │──│   one-shot)      │──│  background tasks│──│  trust ledger │         │
│  │  Panel (UI)  │  │  event sources   │  │  per-session     │  │  approvals    │         │
│  │  Location    │  │  (Gmail, EventKit│  │  confirmations   │  │  active hours │         │
│  │  SMS fallback│  │   Slack, phone)  │  │                  │  │               │         │
│  └──────────────┘  └──────────────────┘  └──────────────────┘  └───────────────┘         │
│         │                   │                      │                    │                  │
│  ┌──────┴───────────────────┴──────────────────────┴────────────────────┴───────┐         │
│  │ Tools (37 local) · Connector registry (native Google/Apple, remote MCP+OAuth,│         │
│  │ stdio MCP) · Model router v2 (tiers L/P/F) · SQLite (GRDB) · Keychain        │         │
│  └──────────────────────────────────────────────────────────────────────────────┘         │
│         │ localhost                                   │ Tailscale only                      │
│  ┌──────┴────────┐                           ┌────────┴────────┐                           │
│  │ Local model   │                           │ Claude Code     │                           │
│  │ (MLX, ~7–14B) │                           │ (Max plan login)│                           │
│  └───────────────┘                           └─────────────────┘                           │
└───────────────────────────────────────────────────────────────────────────────────────────┘
   │ iMessage (Apple)     │ Twilio ⇄ ElevenLabs Agents (brain = Majoor)   │ iPhone Shortcuts → POST   │ Control API (Tailscale)
   ▼                      ▼                                                ▼                           ▼
Your iPhone            Your phone / third parties                    Location events       Your laptop: Majoor.app in client mode
                                                                                           (hotkey, command bar, activity feed, approvals)
```

**One binary, two modes, not a daemon split.** The same Majoor.app runs in **runtime mode** on the Mac mini (hosts the sessions, the channels, and a control API bound to the Tailscale interface) and in **client mode** on your laptop (hotkey, command bar, menu bar panel, all talking to the runtime over that API). A separate `majoord` would cost XPC schemas and two binaries for nothing in 2.0. The runtime has zero dependency on UI; the control API is the boundary, and the laptop app is one `Channel` among several. A daemon split stays possible later because of that boundary.

**Why a LaunchAgent and not a LaunchDaemon:** Messages, `chat.db`, AppleScript automation, EventKit and MapKit all need a logged-in user session with Full Disk Access and Automation granted *in that session*.

### 5.2 Session runtime

Replaces "one `AgentLoop.execute` at a time".

- `SessionManager` (actor) owns N `AgentSession`s. Each session has its own conversation history, confirmation continuation, token budget and cancellation.
- Session kinds: **concierge** (one per channel thread; answers "what's my next meeting?" in seconds; may spawn tasks), **task** (background, long-running; today's agent loop), **job** (short, usually local-model, structured output only; spawned by an automation).
- The owner can list, stop and inspect sessions from any channel: `/status`, `/stop 3`, `STOP` (kills everything and denies every pending approval).
- The existing `AgentLoop` becomes the body of a task session. Iteration logic, tool dispatch and memory injection are preserved; it is instantiated per session and its confirmation path goes through the session's channel.
- Written in Swift 6 language mode (D7), flipped at the start of Phase 1 so isolation bugs in the new concurrent code are errors.

This deliberately contradicts the 1.x rule "do not introduce concurrency in the confirmation flow". That rule protected a single-user GUI. 2.0 needs concurrency by definition; the design makes it per-session and actor-isolated rather than global.

### 5.3 Automations and event sources

OpenClaw's lesson, taken whole: there is no monolithic heartbeat. Every scheduled behavior is its own **job** with its own schedule, inputs, model tier, delivery policy and active hours. A job with nothing to report records `no_change` and sends nothing.

```
job (cron | one-shot) ──► gather inputs from event sources ──► model (tier by data class, structured output)
    ──► {no_change | notify owner | spawn task session} ──► record_result
```

- `automations` table: id, name, schedule (cron expression or a single timestamp), active-hours policy, input sources, prompt and scratch, model tier, delivery (owner channel, urgency ceiling), risk ceiling, last run, last result.
- One-shot reminders are jobs the owner creates from iMessage ("remind me at 5pm to call the bank").
- `EventSource` protocol: `start()`, `stop()`, `AsyncStream<Event>`. Initial sources: Gmail (history.list poll every 2–5 min), EventKit change notifications, Slack (Socket Mode or poll), iMessage inbound, Location (§5.8), filesystem watch on chosen folders.
- **Escalation ladder:** log → iMessage → repeat after N min if unacknowledged → phone call. Only urgency 3 may reach the call rung. Active hours (D-quiet: 8:00–23:00 by default, owner-set) block rungs 2–4 except urgency 3.
- Everything a job reads is untrusted data. It is wrapped and labeled before any model sees it and can never carry an instruction (§5.7).

### 5.4 Channels

`Channel` protocol: `inbound: AsyncStream<InboundMessage>`, `send(to:, text:, attachments:)`, `ask(question:, options:, timeout:) async -> Answer`. The `ask` primitive generalizes confirmation into "the agent can ask the owner anything and resume when answered", which is what makes human-in-the-loop over iMessage work.

**iMessage (primary).** Use `imsg` (MIT, Swift 6.1, macOS 14+). It reads `~/Library/Messages/chat.db`, watches the WAL for new rows with a polling fallback, sends through Messages.app automation, and exposes `imsg rpc`: a long-lived JSON-RPC transport over stdio, newline-delimited. That is the same framing `MCPClient` already implements, so Phase 1 drives it as a subprocess with a thin sibling of `MCPClient`. Later it can be linked as a Swift package. Permissions: Full Disk Access and Automation → Messages for the `majoor` user. Known limits with SIP on: plain text and attachments only; no tapbacks or inline replies; creating a chat with a handle that has never messaged Majoor may fail, so the owner texts Majoor first and third-party outreach prefers voice or email. Messages that arrive while Majoor is down are replayed from `chat.db` with de-duplication.

**Voice (decided, D3): ElevenLabs Agents with the brain in Majoor.** A Twilio number is imported into ElevenLabs Agents, which handles telephony, speech-to-text, text-to-speech and turn-taking. Its custom-LLM endpoint points at Majoor through a single HMAC-signed webhook exposed via Tailscale Funnel or a Cloudflare Tunnel, so every turn goes through Majoor's router and permission policy, and ElevenLabs never holds a tool credential. Inbound from the owner: caller ID identifies you; a spoken passphrase is required before any R2+ action (§9) because caller ID is spoofable. Outbound to the owner: urgency-3 escalations only, with a text fallback if unanswered. Third-party calls: Phase 4, with the disclosure rule in §5.7. **Engineering by voice (G9):** you call and describe what to change, add or remove in a codebase, or a new project to start; the concierge turns it into a task session that drives Claude Code; results and the diff come back by iMessage. Privacy note: audio and transcripts of every call pass through ElevenLabs. Under the Strict preset, treat calls as tier-P exposure and do not read personal data aloud that you would not send to a cloud vendor; check ElevenLabs' retention settings for the account.

**Laptop app: hotkey, command bar, menu bar panel (G10).** The same Majoor.app in client mode. Cmd+Shift+Space opens the command bar exactly as today; a task typed there is sent to the runtime on the Mac mini over the control API and appears as a session. The panel's activity feed streams every session live, whichever channel started it: tool calls, pipeline steps, pending approvals, cost so far. A task you started by iMessage is visible on the laptop and the other way round. Approvals, including R3, can be answered from the laptop, and `STOP` works from here too. Chat mode keeps streaming as it does now. A **Run here** toggle keeps 1.x behavior for tasks that need the laptop's own files or when the Mac mini is unreachable: the client binary still contains the full runtime and runs the task locally. The control API is a WebSocket bound only to the Tailscale interface, authenticated with a pairing token minted on the Mac mini and stored in the laptop's Keychain; each client can be revoked from Settings. Settings on the laptop edit the runtime's configuration remotely: permission mode, connectors, automations, active hours, VIP list.

**SMS fallback.** Twilio SMS for when iMessage is down. Receive-only for status; SMS never carries commands (spoofable sender).

### 5.5 Identity and the phone number (decided, D1)

Majoor gets its own Apple ID (an email handle on your domain) signed into Messages on the Mac mini, and a Twilio or Telnyx number for calls and SMS. One contact card "Majoor" on your phone holds both. No SIM. Majoor's Apple ID also gets its own iCloud Calendar, and your calendar is shared to it with the minimum permission, which gives EventKit a clean separation. Sharing your own Apple ID was rejected: Majoor would read every message you receive, could send as you, and a compromise of the box would expose everything you own. A SIM in a spare iPhone remains a later upgrade if you ever want the number itself to be iMessage-registered.

### 5.6 Connector registry ("any new service is just a configuration")

There is no universal OAuth: Google, GitHub and Slack each issue their own tokens. But MCP's authorization spec (OAuth 2.1 with PKCE, resource indicators, protected-resource metadata) gives a single *flow*, and GitHub, Notion, Linear and Slack host remote MCP endpoints. So the registry has three connector types:

| Type | Auth | Examples | Status |
|------|------|----------|--------|
| Native | Provider OAuth via the existing loopback server, tokens in Keychain | Google (Gmail, Calendar), Apple (EventKit, Contacts, Messages, MapKit) | Exists; add state + PKCE |
| Remote MCP | MCP OAuth 2.1 via the same loopback redirect | GitHub, Notion, Linear, Slack hosted endpoints | New: Streamable HTTP transport + auth flow in `Core/MCP` |
| Local MCP (stdio) | `keychain:` env values | Anything with an npm/uvx server | Exists |

"Add a service" then means: paste a URL (or pick from a list), click Authorize in the browser, done. Native connectors stay native where the hand-written tools are better than an MCP wrapper (Gmail and Calendar today).

Token hygiene: fine-grained GitHub tokens scoped per repo; Google scopes minimal; every connector lists its scopes in Settings; a `/revoke <service>` command exists.

### 5.7 Security model

| # | Threat | Mitigation |
|---|--------|------------|
| T1 | Prompt injection through inbound iMessage, email, Slack, web pages | Only the owner's Apple ID can issue commands. Everything else is data: labeled, quoted, never executed. Non-owner senders get a restricted persona with zero tools that can only relay to the owner. Auto permission mode is disabled on inbound channels |
| T2 | Owner impersonation | iMessage senders are Apple-ID-authenticated, which is strong. SMS and caller ID are spoofable: SMS never carries commands; voice requires a passphrase for R2+; location posts carry a per-device secret |
| T3 | Mac mini compromise | Majoor's own Apple ID, not yours; scoped tokens; no public ports; Tailscale ACLs; the box holds nothing of yours except what connectors expose |
| T4 | Model error on an outbound action | Risk classes and approvals (§9); approval replies carry a nonce so a replayed or injected "yes" is useless |
| T5 | Runaway cost or loop | Per-session token budget, daily spend cap, `STOP` kill switch, per-job rate limits |
| T6 | Self-update bricks the agent | Self-test gate, Sparkle install, post-launch self-test, automatic rollback, launchd KeepAlive, crash-count watchdog that texts you |
| T7 | Secret exfiltration via a model | Secrets live only in Keychain and are injected into tool processes, never into prompts. Models see tool *results*, never credentials. Claude Code runs with a scrubbed environment and a denylist on `.env`, `APIConfig.swift`, Keychain and `~/.ssh` |
| T8 | Location data misuse | Location is stored only on the box, kept 7 days, never sent to any cloud tier, and used only by the jobs in §8 |
| T9 | Control API abuse from the network | Bound to the Tailscale interface only, never to all interfaces; a pairing token per client, revocable; a Tailscale ACL limits which devices may reach the port; every API action passes the same policy as any other channel |

Legal for voice: the FCC treats AI-generated voices as "artificial or prerecorded" under the TCPA (2024 ruling), and California requires AI disclosure on calls (AB 2905) and for commercial bot interactions (BOTS Act). Policy: every outbound third-party call opens with a disclosure, outbound calls go only to businesses or people with an existing relationship with you, never cold outreach, and calls are not recorded unless the counterparty is told. Verify current state law before Phase 4.

### 5.8 Location (G8)

Find My is not an option (see §2). The consent-based, Apple-native path is your iPhone pushing location to Majoor:

1. **Geofence events.** iPhone Shortcuts personal automations "When I arrive at / leave <place>" run a shortcut that posts `{event, place, time}` to Majoor's endpoint over Tailscale (the Tailscale iOS app keeps the Mac mini reachable). Places: home, office, gym, whatever you define.
2. **On-demand fix.** Majoor texts your phone a token line such as `#loc`; a Shortcuts "Message received from Majoor containing #loc" automation runs Get Current Location and posts it back. This gives Majoor a pull mechanism without an app. Verify on your iPhone that this automation runs without confirmation; if it does not, OwnTracks (open source, background location, HTTP mode) is the fallback and also gives periodic fixes.
3. **"Where you should be" job.** 15 minutes before any calendar event with a location, Majoor requests a fix, computes travel time with MapKit directions on the Mac mini (native, no API key), and texts you if you cannot make it. Urgency rises if the event is one you marked important.

Every post carries a per-device secret; the endpoint accepts nothing else. Location never leaves the box and is retained 7 days.

## 6. Model routing and privacy tiers (decided: Strict, D4)

| Tier | Where | Use | Sees |
|------|-------|-----|------|
| **L** Local | MLX server on the Mac mini, localhost. With 32 GB (D2) this is a ~7–14B model | Triage, classification, routing, memory consolidation, short summaries. Structured output only | Everything; nothing leaves the box |
| **P** Private cloud | Zero-retention open-weight endpoint (Fireworks reports ZDR by default for open models; verify the current terms) | Everything personal that needs a strong model: drafting replies in your voice, long threads, multi-document questions. **Mandatory under 32 GB + Strict** | Personal data, no credentials |
| **F** Frontier | Anthropic. Coding and engineering → **Claude Fable 5.1 through Claude Code signed in with your Max subscription** (D5). Any other tier-F-eligible work → Opus 5.5 | Engineering, self-improvement, code questions | Code and repo context only. Never email, contacts, calendar, messages or location |

**Strict preset:** the data-class table allows only `code` and `repo-context` on tier F. `email-meta`, `email-body`, `contacts`, `calendar`, `messages`, `location`, `finance` are tier L or P only, and `location` and `finance` are tier L only.

**Tier F cascade (D5).** Anthropic's support article (updated 2026-10-07) says that `claude -p` and the Agent SDK, when signed in with your Claude plan, draw from your subscription limits, and that Max plans now include monthly API credits usable with an API key from the linked Console organization. So:

1. Claude Code headless, signed in with the Max plan, model Fable 5.1 for coding tasks. Marginal cost $0 until the plan's limits.
2. On limits: the same task re-run through the API with the linked Console org's key, model Opus 5.5, consuming the included credits.
3. On credit exhaustion: paid API, Opus 5.5, with Fable 5.1 only on explicit request. The daily spend cap applies here.

Majoor must use the official `claude` binary with your own login; building on the subscription's OAuth token directly is not what the article covers. The article says nothing about pooling several subscriptions. Anthropic's usage policy prohibits circumventing usage limits, so plan on one Max account signed in on the Mac mini (D9) rather than rotating accounts, unless you confirm otherwise with Anthropic.

**Consequence of 32 GB + Strict, stated plainly:** the email drafts you approve will be written by a cloud open-weight model under a zero-retention agreement, not by Claude and not by the local model. If draft quality disappoints, the levers are a better tier-P model or relaxing the preset for `email-body`, not more RAM.

Local model selection: run a 20-case classification and JSON-output eval on the box against two or three ~7–14B candidates and serve the winner through an OpenAI-compatible local server (Ollama and LM Studio run MLX; Rapid-MLX advertises Anthropic-compatible output). Majoor needs one `OpenAICompatibleProvider` plus a base-URL override, which also serves tier P.

## 7. Data model additions

New SQLite tables (GRDB migrations, additive): `sessions`, `automations` (§5.3), `events` (source, payload, triage result, disposition), `approvals` (nonce, session, action signature, risk class, decision, decided_by_channel, timestamps), `trust_ledger`, `contacts_policy` (handle → trust level, VIP flag), `connectors` (type, scopes, status), `locations` (fix, source, 7-day retention). Existing `memories`, `tasks`, `usageStats` stay.

## 8. Proactive behaviors (decided set)

| Behavior | Job | Tier | Risk class and autonomy |
|----------|-----|------|--------------------------|
| Morning brief | Daily at an owner-set time | L gathers, P writes | R0, auto: calendar, unreplied VIP threads, open tasks, Majoor health |
| Unreplied-email nudge with drafts | Every 2 h, VIP-gated | L detects, P drafts | R0 notify; the draft is shown in your voice; sending is R3, always approved. VIP list is explicit (OpenClaw removed inferred follow-ups for false positives) |
| Inbox and Slack urgency triage | Every 30 min | L | R0: only urgency ≥ 2 reaches you; the rest waits for the brief; `no_change` otherwise |
| Weekly self-improvement proposals | Weekly | F (code only) | R0: up to three proposals with cost estimates; nothing runs until you say so (§10) |
| One-shot reminders | Created from iMessage | none | R0 |
| Weekly cost and activity report | Sunday | L | R0: tokens and dollars per tier, sessions, approvals, trust-ledger promotions |
| Nightly memory consolidation | Nightly | L | R1 on Majoor's own state: merge duplicates, decay stale, flag contradictions |
| Urgent escalation to a call | Event-driven | L classifies | Ladder in §5.3; only urgency 3 reaches the call rung; breaks active hours |
| Location: "where you should be" | 15 min before located events | L | R0 (§5.8) |
| "I'm blocked" questions | Any task needing a decision | n/a | `ask` over iMessage; the task resumes on answer |

**Explicitly not in 2.0:** meeting prep, CI-failure watching, review-request and PR notifications, Dependabot alerts. Engineering is on demand (G9). One communication behavior was marked "something else" during the decision pass and is still unspecified (D8).

The unreplied-email nudge is the Phase 2 exit criterion because it exercises every piece: event source, local triage, tier-P drafting in your voice, approval over iMessage with a nonce, and an irreversible send.

## 9. Permission policy v2

Extends the existing Manual / Standard / Auto modes with risk classes:

| Class | Definition | Examples | Default |
|-------|------------|----------|---------|
| R0 | Read-only, or writes only to Majoor's own state | search, read, summarize, save memory, notify owner, record a location | Auto |
| R1 | Reversible, internal | write a file in a project dir, commit on a branch, create a draft, create an event on Majoor's calendar | Auto, logged, trust ledger applies |
| R2 | External but reversible or low blast radius | comment on a GitHub issue, post in a Slack channel you own, update your own calendar event | Approval until promoted by the trust ledger |
| R3 | Irreversible or outward-facing to people | send email or iMessage to anyone but the owner, delete, `git push`, open a PR, place a call, spend money, install a new build of Majoor | Always approve. Never promoted |

Rules:

- Trust ledger: an R1 or R2 action signature (tool + normalized key arguments) approved 5 times in 30 days is promoted to auto. R3 is never promoted. Promotions are listed in the weekly report and revocable with one message.
- Approval over iMessage: the request shows the concrete action (recipient, subject, first lines) and a 4-character nonce; the reply must contain the nonce (`yes K7Q2`); it expires in 10 minutes; a decline can carry a note that goes back into the session as a tool result.
- Channel floor: R3 approvals require iMessage or the panel; voice can approve up to R2 with the passphrase.
- Active hours (decided): proactive messages only between owner-set hours, default 8:00–23:00; urgency-3 escalations are exempt.
- The 1.x `execute_shell` escape hatch is closed by classifying shell commands into the same classes (mutating git, `rm`, `gh`, interpreters, writes outside allowed roots → the class of the equivalent tool).

## 10. Self-improvement pipeline

```
proposal (weekly job or owner request by text/voice) ──► git worktree
   ──► Claude Code headless, Fable 5.1 under the Max login (cascade in §6)
   ──► xcodebuild ──► self-test (--selftest: migrations, tool registry, canned task)
   ──► iMessage summary + diff attachment ──► owner approval (R3)
   ──► build-dmg.sh + local appcast ──► Sparkle installs ──► post-launch self-test
   ──► OK: keep | FAIL: launchd restarts previous .app, Majoor texts you
```

Guardrails: never on `master` directly; one self-change per day; changes touching `Security/`, `Core/PermissionMode.swift` or the policy engine require an explicit "I read the diff" approval; the self-test must pass on the *new* build before install and again after launch; the previous `.app` is kept for rollback. Reusing Sparkle means the self-build path is the release path, which is the one already exercised.

## 11. Costs (updated for D2, D3, D5)

Prices other than Anthropic's come from secondary sources; verify before buying.

### One-time

| Item | Cost |
|------|------|
| Mac mini M6, 32 GB (D2) | about $1,299 (base $899 plus $400 memory) |
| Apple Developer Program (notarized builds; optional) | $99/year |

### Monthly

| Item | Estimate | Assumptions |
|------|----------|-------------|
| Phone number | ~$1.15 | Twilio US local; Telnyx is cheaper |
| Voice telephony minutes | ~$1–3 | 100–200 min at ~$0.009–0.014/min |
| ElevenLabs Agents (D3) | ~$10–30 | 100–300 min at ~$0.10/min; check whether the LLM line is billed when the brain is your own endpoint |
| Local model (tier L) | ~$2–5 | Electricity only |
| Private cloud (tier P) | ~$5–30 | Higher than v0.1 because 32 GB pushes all drafting to this tier; 10–30M tokens at ~$0.2–1.0 per million |
| Tailscale, Cloudflare Tunnel | $0 | Personal tiers |
| **Baseline total** | **~$20–70** | Everything except engineering |
| Engineering (tier F) | **$0 marginal up to the Max plan's limits**, then the included API credits, then paid Opus 5.5 at $4/$20 per million tokens | Your existing Max subscription is the first rung (D5). Worst case with no subscription headroom: $100–400 at 20 tasks a month on Opus, $250–900 on Fable |

## 12. Phases

| Phase | Scope | Exit criterion |
|-------|-------|----------------|
| **0. Prerequisites** (now, before the Mac mini) | Close the four items in §3. Build the iPhone Shortcuts location proof of concept against your current Mac (cheap, no new hardware). Answer D8–D10. | Truthful-loop T1 passes; `execute_shell` gate closed; a Shortcut posts a location fix to a local endpoint |
| **1. Always-on + iMessage + laptop client** | Mac mini setup (dedicated user, Apple ID, auto-login, no sleep, Tailscale, FDA/Automation). Swift 6 language mode (D7). Session runtime behind a control API. Client mode for the laptop app: command bar, activity feed, approvals, Run-here fallback. iMessage channel via `imsg rpc`. Owner-only trust. Approvals with nonces. Kill switch. One-shot reminders (first automation job). | From your phone: text Majoor a task, it does it, it asks before anything R3, `STOP` works, "remind me in 20 min" works. From your laptop: hotkey, type a task, watch it run on the Mac mini in the activity feed, approve it there |
| **2. Proactive** | Automations table and event sources. Local tier via MLX server and `OpenAICompatibleProvider` (also serves tier P). Router v2 with data classes under Strict. Morning brief, triage, VIP nudge, cost report, memory consolidation, location job, escalation ladder (text rungs). | Nudge works end to end with approval; morning brief daily for a week without a false alarm you cared about; "you won't make your 3pm" fires correctly once |
| **3. Voice + connectors** | ElevenLabs Agents with the Twilio number, brain = Majoor. Inbound from owner with passphrase. Outbound urgency-3 calls. Engineering by voice (G9). Remote MCP transport + OAuth. | Call Majoor, describe a code change, get a diff by text; Majoor calls you for an urgency-3 event; add Linear with a URL and a click |
| **4. Self-improvement + third parties** | Pipeline in §10 on the Max-login cascade. Weekly proposals job. Third-party calls with disclosure. | Majoor ships a change to itself that you approved from your phone; books one real appointment |
| 5. Later | Daemon split, SIM-backed number, self-hosted voice pipeline, Shortcuts/App Intents as a channel, WhatsApp | |

## 13. Decisions

| ID | Decision | Outcome (2026-10-31) |
|----|----------|----------------------|
| D1 | Majoor's identity | **Own Apple ID + Twilio number.** |
| D2 | Mac mini memory | **M6, 32 GB.** Tier P becomes mandatory for drafting; tier L is triage-only. |
| D3 | Voice vendor for v1 | **ElevenLabs Agents, brain = Majoor** via its custom-LLM endpoint. |
| D4 | Privacy preset | **Strict.** Only code reaches Anthropic. |
| D5 | Engineering model | **Fable 5.1 for coding through Claude Code under the Max subscription; Opus 5.5 for other tier-F work; cascade to included API credits, then paid Opus.** |
| D6 | OpenClaw two-week trial | **No.** Behaviors chosen from a catalog instead (§8). |
| D7 | Swift 6 language mode | **Yes, at the start of Phase 1.** |
| D-quiet | When Majoor may message unprompted | **Active hours, urgency-3 exempt.** |
| D8 | The unspecified "something else" communication behavior | **Open.** |
| D9 | Which Max account signs in on the Mac mini, and whether a second subscription is used at all | **Open.** Default: one account, no rotation. |
| D10 | Location mechanism: Shortcuts message-trigger pull vs OwnTracks | **Open** until the Phase 0 proof of concept. |

## 14. Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Apple breaks `chat.db` reading or Messages automation in a macOS update | Medium over 2 years | `imsg` has a community that chases this; SMS via Twilio as a degraded channel; pin the Mac mini's macOS version and update deliberately |
| Small local model misclassifies urgency | High | Triage uses structured output with a conservative threshold; anything uncertain waits for the brief rather than waking you; weekly report shows misses |
| Tier-P drafts do not sound like you | Medium | Few-shot from your sent mail (stays on tier P); switch tier-P model; last resort relax `email-body` |
| The session-runtime refactor destabilizes a codebase with no tests | High | Write the first tests for the runtime boundary as part of Phase 1; keep 1.x `AgentLoop` semantics inside the task session |
| Shortcuts automations need confirmation or stop running in the background | Medium | OwnTracks fallback; geofence events alone still cover "arrived / left" |
| Max plan limits or terms change | Medium | The cascade degrades to paid API automatically; the daily cap bounds the damage |
| Power or network loss on the Mac mini | Low | KeepAlive, auto-login, a small UPS, Tailscale reconnects, Majoor texts you after any restart |
| Third-party calling exposes you legally | Low if policy is followed | Disclosure, businesses only, no recording, no cold outreach |

## 15. Sources consulted (2026-10-31)

- OpenClaw iMessage channel, gateway architecture, automations (formerly heartbeat), and task placement: https://docs.openclaw.ai/channels/imessage, https://docs.openclaw.ai/concepts/architecture, https://docs.openclaw.ai/gateway/heartbeat.md, https://docs.openclaw.ai/cron-vs-heartbeat
- `imsg` (Swift iMessage CLI, JSON-RPC over stdio): https://github.com/steipete/imsg
- Anthropic: Agent SDK and `claude -p` under a Claude plan, Max API credits (updated 2026-10-07): https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan
- Anthropic model prices and the Fable 5.1 retention requirement: Anthropic API reference bundled with Claude Code (cached 2026-10-06)
- Mac mini 2026 lineup and prices: https://www.theregister.com/ai-and-ml/2026/08/25/apple-defies-memory-shortage-with-new-mac-minis/5292406, https://www.macworld.com/article/2964754/2026-mac-mini-m5-pro-design-specs-release-date.html
- Find My cache encrypted since macOS 14.4 (developer forum report): https://developer.apple.com/forums/thread/742555
- Twilio voice and number pricing: https://www.twilio.com/voice/pricing/us, https://quiq.com/blog/twilio-voice-pricing/
- Voice agent per-minute pricing: https://elevenlabs.io/blog/comparing-elevenlabs-conversational-ai-v-openai-realtime-api
- Local models and runtimes on Apple silicon: https://dev.to/bspann/running-llms-locally-on-macos-the-complete-2026-comparison-48fc, https://github.com/raullenchai/Rapid-MLX
- MCP authorization (OAuth 2.1): https://mojoauth.com/blog/how-mcp-authorization-actually-works-oauth-2-1-resource-servers-and-resource-indicators
- Zero-retention open-model inference: https://www.morphllm.com/fireworks-ai-pricing
- AI voice disclosure and TCPA: https://justcall.io/blog/ai-voice-agent-disclosure-laws.html, https://retellai.com/blog/tcpa-compliance-playbook-voice-ai-outbound

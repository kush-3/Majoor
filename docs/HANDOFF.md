# Majoor 2.0 — where things stand and how to pick up

**Updated 2026-10-31.** This file exists so that work can resume from any machine, account or
session with nothing but the repository. Read it first, then `CLAUDE.md` (how the code is built),
then `docs/MAJOOR-2.0-PRD.md` (what 2.0 is) and `docs/PHASE-2-PLAN.md` (each step's status block
says what landed, what deviated from the plan, and what is still unverified by hand).

Some notes stay local to Kush's laptop on purpose and are **not** in the repository: a backlog and
session-handoff file, a credential-rotation checklist, and a truthful-loop test script. Nothing in
them is needed to continue; everything a new session needs is here or in the plan.

## State

| Piece | Where | Status |
|-------|-------|--------|
| PRD v0.3 | `docs/MAJOOR-2.0-PRD.md` | Decisions D1–D7 made; D8, D9, D10 open (§13) |
| Phase 0 (prerequisites) and Phase 1 (always-on runtime, control API, client mode, iMessage, reminders) | merged to `master`, PR #16 | Code complete; the Phase 1 exit criterion still has to be run on the Mac mini (plan §0.1) |
| Phase 2 step 2 (OpenAI-compatible provider, tiers L and P, Settings ▸ Models, eval script) | merged to `master`, PR #17 | Code complete |
| Phase 2 steps 3–6 (router v2 + Strict, event sources, cron jobs + runner + ladder, `ask_owner`, the §8 behaviors) | PR #18 from `phase-2-proactive` | Code complete; 253 test functions pass; Debug and Release build warning-free |
| Phase 3 (voice via ElevenLabs Agents + Twilio, remote MCP + OAuth) | not started | Needs the Mac mini and D1's accounts; write `docs/PHASE-3-PLAN.md` first, in the shape of the Phase 2 plan |

Everything was built on the laptop with no Mac mini, no `imsg`, no tier L or P endpoint. Unit tests
cover every pure piece with scripted providers, fakes and throwaway databases; nothing proactive has
yet run against a real inbox, calendar, phone or local model.

## Pick up here, in order

1. **Sync.** `git checkout master && git pull`. If PR #18 is merged, delete the local
   `phase-2-providers` and `phase-2-proactive` branches; if it is still open, review comments arrive
   on the PR and nothing should be re-implemented.
2. **First launch after the merge.** The privacy preset defaults to **Strict** (decision D4). On a Mac
   with no tier P endpoint, email, calendar and file-management tasks on Claude receive a tool-result
   refusal and memory context is withheld on Claude for every task. Either configure tier P in
   Settings ▸ Models or switch the preset there to "Claude for everything" (the 1.x behaviour).
3. **Hand checks** (each step's status block in `docs/PHASE-2-PLAN.md` lists its own; PR #18's body
   collects them): a task on a local model with the routing override on (Settings ▸ Models); the
   Models, Location, Automations and Contacts tabs visually; the `hello` job on `*/5 * * * *` producing
   five `no_change` rows and sending nothing; a question from the agent answered over `imsg`; the VIP
   nudge end to end (mark a sender VIP in Settings ▸ Contacts → draft over iMessage → `send CODE` →
   the `reply_to_email` approval with its nonce); a week of morning briefs; one "you won't make your
   3pm" (needs D10).
4. **Phase 1 close-out on the Mac mini** (plan §0.1 and step 1): dedicated user, Apple ID, Tailscale,
   Full Disk Access and Automation for Messages, `brew install steipete/tap/imsg`, the two-Mac client
   flow, a real `imsg` conversation, the location proof of concept (`Scripts/location-poc.py`) that
   decides D10, and decisions D8 and D9.
5. **Decisions for Kush** before Phase 3: D8, D9, D10; plan open questions 5 (chat mode and the
   Auto-mode consent judge still go to Claude; move them to tier P under Strict?), 7 (what marks a
   calendar event important; today a `!` in the title), 9 (a `DecisionModel` seam for the ambiguous-
   input classifier and later triage, with Jev / tier L / keyword implementations chosen by the
   20-case eval; TypeSafe AI's Jev is cloud-only, so it counts as a tier-P vendor until its retention
   terms are verified, and never for location or finance). Small code follow-ups: a skip-the-model
   seam in `JobRunner` when a behavior's gather finds nothing; a question prompt for `ask_owner` in the
   panel (`PanelChannel.ask` still answers "no answer"); two old `try` warnings in
   `MajoorTests/ChannelTests.swift` and `SessionLoopTests.swift`.
6. **Phase 3**, per PRD §12.

## How the Phase 2 code was built, for whoever continues it

- Steps 3–6 were built by eight parallel subagents, each in its own git worktree, merged onto one
  integration branch. The seams that made that possible are worth keeping: `DataClass` landed first
  so router and sources could share it; `JobDefinition` has `gather` and `apply` closures so each
  behavior is one file under `Core/Jobs/Behaviors/`; behaviors share state only through their own
  `automations.scratch` row with the shapes in `Behaviors/JobState.swift`.
- Two lessons: a worktree cut from `master` must be reset to the integration branch before work
  starts, and two agents can declare the same test helper name in different files without git
  noticing, so scan `MajoorTests` for duplicate top-level names after every parallel merge.
- Tests: `xcodebuild test -project Majoor.xcodeproj -scheme Majoor -destination 'platform=macOS' -only-testing:MajoorTests`.
  Each run gets its own database (`/tmp/majoor-tests/majoor-{pid}.sqlite`), so parallel runs are safe.
  Swift Testing suites run in parallel; tests never touch `UserDefaults.standard`, the Keychain or
  the real database.
- Developer hooks: a running build accepts `majoor://task?text=…&token=…` when launched with
  `MAJOOR_AUTOMATION_TOKEN`; DEBUG builds add `majoor://pair-code` and `majoor://pair` for the one-Mac
  client loop. Target a running instance with `open -a <full .app path> "majoor://…"`, never `open -b`.
  On macOS, `log` is a zsh builtin: use `/usr/bin/log show --info`.
- Commits never carry attribution trailers (`CLAUDE.md`, Git Commits). Nothing is pushed unless Kush
  asks. `master` is never committed to directly.

## A prompt for a fresh session

> Continue Majoor 2.0. Read docs/HANDOFF.md, then the status blocks in docs/PHASE-2-PLAN.md. Tell me
> which hand checks and decisions are still open, then start on the first thing in "Pick up here"
> that this machine can do.

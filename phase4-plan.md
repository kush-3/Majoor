# Phase 4 — Email, Calendar & Notifications

**Goal:** EventKit calendar integration, Gmail OAuth with full access, actionable notifications with decision support, and a response viewer for long agent outputs.

**Branch:** `kush/phase-4-email-calendar`

---

## Architecture Decisions (from discussion)

| Decision | Choice | Rationale |
|---|---|---|
| Calendar | Apple Calendar only (EventKit) | No OAuth needed; Google Calendar syncs to Apple Calendar natively |
| Email | Gmail API via OAuth | Full power: fetch, read, draft, send, delete, manage labels |
| Gmail Scopes | `gmail.modify` (full) | Covers read, send, compose, delete, label management |
| OAuth Flow | ASWebAuthenticationSession → system browser | Google-preferred, trustworthy UX, custom URL scheme `majoor://oauth/callback` |
| OAuth Credentials | Client ID/Secret hardcoded in `APIConfig.swift` | Same pattern as Anthropic/Tavily keys. Tokens go to Keychain. |
| Email Safety | Notification with approve/deny buttons | Agent pauses mid-loop, notification shows preview + action buttons |
| Confirmation Blocking | Block the agent loop | Simpler; no concurrent task queue needed |
| Notifications | Full actionable notifications | Task complete, errors, and decision notifications with action buttons |
| Response Viewer | Scrollable detail panel for long outputs | Notification tap or "View" in activity feed opens full response |

---

## Sub-phases & File Plan

### 4A — EventKit Calendar Tools (3 tools)

**New files:**
- `Majoor/Tools/CalendarTools.swift` — All 4 calendar tools in one file

**Modified files:**
- `Majoor/Tools/ToolProtocol.swift` — Add calendar tools to `ToolRegistry.defaultTools()`
- `Majoor/Info.plist` — Add `NSCalendarsUsageDescription` (or ensure entitlement is set)

**Tools to implement:**

| Tool | Parameters | Description |
|---|---|---|
| `read_calendar_events` | `start_date`, `end_date` (ISO8601 strings) | Fetch events in a date range via EventKit. Defaults to today if no range given. |
| `create_calendar_event` | `title`, `start_date`, `end_date`, `notes?`, `location?`, `calendar_name?` | Create a new event. If `calendar_name` not given, use default calendar. |
| `update_calendar_event` | `event_id`, `title?`, `start_date?`, `end_date?`, `notes?`, `location?` | Update an existing event by its `eventIdentifier`. |
| `delete_calendar_event` | `event_id` | Delete an event. Requires confirmation (triggers notification). |

**Implementation details:**
- Use `EKEventStore` singleton, request `.fullAccess` to events (macOS 14+)
- Date parsing: accept ISO8601 and natural-language-ish formats ("tomorrow at 2pm" → let the LLM convert to ISO8601 before calling the tool)
- Return events as JSON-like text: title, start, end, location, calendar name, event ID
- `delete_calendar_event` sets a flag that triggers the confirmation notification system (built in 4C)
- Grant access on first use; cache authorization status

**EventKit permission flow:**
```swift
let store = EKEventStore()
// macOS 14+
store.requestFullAccessToEvents { granted, error in ... }
```

---

### 4B — Google OAuth + Gmail Tools (6 tools)

**New files:**
- `Majoor/Core/OAuth/GoogleOAuthManager.swift` — OAuth flow: authorize, token exchange, refresh, revoke
- `Majoor/Core/OAuth/OAuthTokenStore.swift` — Save/load/refresh tokens via Keychain
- `Majoor/Tools/EmailTools.swift` — All 6 email tools

**Modified files:**
- `Majoor/APIConfig.swift` — Add `googleClientId`, `googleClientSecret`
- `Majoor/Tools/ToolProtocol.swift` — Add email tools to `ToolRegistry.defaultTools()`
- `Majoor/Settings/SettingsView.swift` — Add "Accounts" tab
- `Majoor/Info.plist` — Register custom URL scheme `majoor` for OAuth callback

**OAuth Flow:**
1. User clicks "Connect Gmail" in Settings → Accounts tab
2. `GoogleOAuthManager` builds the authorization URL with scopes:
   - `https://www.googleapis.com/auth/gmail.modify`
3. Opens via `ASWebAuthenticationSession` in system browser
4. User signs in, consents
5. Google redirects to `majoor://oauth/callback?code=...`
6. App catches the URL via `application(_:open:)` or `NSAppleEventManager` URL handler
7. Exchange `code` for access + refresh tokens via POST to `https://oauth2.googleapis.com/token`
8. Store tokens in Keychain via `OAuthTokenStore`
9. On subsequent requests, auto-refresh if access token expired

**URL Scheme Registration (Info.plist):**
```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>majoor</string>
    </array>
    <key>CFBundleURLName</key>
    <string>ai.majoor.oauth</string>
  </dict>
</array>
```

**OAuthTokenStore (Keychain):**
```
- Key: "google_access_token" → short-lived (~1hr)
- Key: "google_refresh_token" → long-lived
- Key: "google_token_expiry" → Date
```
Uses existing `KeychainManager` to store/retrieve.

**Gmail API Tools:**

| Tool | Parameters | Description |
|---|---|---|
| `fetch_emails` | `query?`, `max_results?` (default 10) | List emails matching Gmail search query (e.g., "is:unread", "from:john@"). Returns id, subject, from, date, snippet. |
| `read_email` | `email_id` | Fetch full email body (plain text preferred, fallback to stripped HTML). Returns from, to, subject, date, body. |
| `draft_email` | `to`, `subject`, `body` | Create a Gmail draft. Returns draft ID. Does NOT send. |
| `send_email` | `to`, `subject`, `body` | **Requires confirmation.** Creates draft, triggers approve/deny notification. On approve, sends via Gmail API. |
| `reply_to_email` | `email_id`, `body` | **Requires confirmation.** Reply to an existing thread. Triggers notification. |
| `search_emails` | `query` | Search emails using Gmail's search syntax. Returns list of matching emails with snippets. |

**Gmail API implementation notes:**
- All requests go to `https://gmail.googleapis.com/gmail/v1/users/me/...`
- Use URLSession, attach `Authorization: Bearer <access_token>` header
- Auto-refresh token if 401 response
- Parse email body: prefer `text/plain` part; if only `text/html`, strip tags
- For sending: encode as RFC 2822, base64url encode, POST to `/messages/send`
- Rate limit: max 10 requests per second (Google's default)

**send_email / reply_to_email confirmation flow:**
1. Tool is called by agent
2. Instead of sending immediately, tool returns a "pending_confirmation" status
3. AgentLoop detects this and pauses (via a confirmation mechanism — see 4C)
4. Notification sent with email preview
5. User taps Approve → tool completes the send
6. User taps Deny → tool returns "User denied sending" to the LLM

---

### 4C — Actionable Notification System + Confirmation Flow

**New files:**
- `Majoor/Core/NotificationManager.swift` — Central notification handler: categories, actions, delegate
- `Majoor/Core/ConfirmationManager.swift` — Manages pending confirmations with async/await continuations

**Modified files:**
- `Majoor/AppDelegate.swift` — Set UNUserNotificationCenter delegate, register categories, handle actions
- `Majoor/Core/AgentLoop.swift` — Check for `requiresConfirmation` on tool results, pause loop and await confirmation
- `Majoor/Tools/ToolProtocol.swift` — Add `ConfirmableToolResult` type

**Notification Categories:**

| Category ID | Actions | Used For |
|---|---|---|
| `TASK_COMPLETE` | "View" (opens panel) | Task finished successfully |
| `TASK_FAILED` | "View Error", "Retry" | Task errored |
| `CONFIRM_EMAIL` | "Approve", "Deny" | Email send/reply confirmation |
| `CONFIRM_DELETE` | "Keep", "Delete" | Calendar event / file deletion |
| `CONFIRM_GENERIC` | "Approve", "Deny" | Any other destructive action |

**ConfirmationManager design:**
```swift
actor ConfirmationManager {
    static let shared = ConfirmationManager()

    private var pendingConfirmations: [String: CheckedContinuation<Bool, Never>] = [:]

    /// Called by the agent loop when a tool needs confirmation.
    /// Sends a notification and suspends until user responds.
    func requestConfirmation(
        id: String,
        title: String,
        body: String,
        category: String
    ) async -> Bool {
        // Send the notification
        NotificationManager.shared.sendActionable(id: id, title: title, body: body, category: category)

        // Suspend until user taps an action
        return await withCheckedContinuation { continuation in
            pendingConfirmations[id] = continuation
        }
    }

    /// Called by the notification delegate when user taps an action
    func resolve(id: String, approved: Bool) {
        if let continuation = pendingConfirmations.removeValue(forKey: id) {
            continuation.resume(returning: approved)
        }
    }
}
```

**AgentLoop integration:**
- After a tool executes, check if the result indicates confirmation needed
- If so, call `ConfirmationManager.requestConfirmation(...)` which suspends the loop
- When user responds via notification, the loop resumes
- If approved, the tool's "commit" action runs (e.g., actually sends the email)
- If denied, return a message to the LLM like "User denied this action"

**Tool protocol addition:**
```swift
struct ConfirmableToolResult: Sendable {
    let needsConfirmation: Bool
    let previewTitle: String      // "Send email to john@example.com"
    let previewBody: String       // "Subject: Meeting\n\nHi John, ..."
    let category: String          // "CONFIRM_EMAIL"
    let onApprove: @Sendable () async throws -> ToolResult
    let onDeny: ToolResult        // Pre-built denial result
}
```

---

### 4D — Response Viewer (Long Output Display)

**New files:**
- `Majoor/UI/ResponseDetailView.swift` — Full-screen scrollable view for long agent responses

**Modified files:**
- `Majoor/UI/ActivityFeedView.swift` — Add "View Response" button on task cards when response is long
- `Majoor/UI/MainPanelView.swift` — Navigation to response detail view
- `Majoor/AppDelegate.swift` — Handle "View" notification action → open panel to response

**ResponseDetailView design:**
- Shows the full agent response text in a scrollable `ScrollView` with `Text` using markdown rendering (`.init(markdown:)`)
- Header: task input, model used, tokens, cost, timestamp
- Copy button to copy full response to clipboard
- If the response includes code blocks, show them with monospace font and syntax highlighting (basic)
- Accessible from:
  1. Tapping "View" on a notification
  2. Tapping a task card in the activity feed
  3. Tapping "View Details" on an expanded task card

**Task card changes:**
- If `task.steps.last` (the response step) has text > 200 chars, show truncated + "View full response →" link
- Clicking opens `ResponseDetailView` in the panel (push navigation or sheet)

---

### 4E — Settings: Accounts Tab

**New files:**
- `Majoor/Settings/AccountsSettingsView.swift` — Connected accounts management

**Modified files:**
- `Majoor/Settings/SettingsView.swift` — Add Accounts tab

**AccountsSettingsView:**
- **Gmail section:**
  - Not connected: "Connect Gmail" button → triggers OAuth flow
  - Connected: Shows email address, "Disconnect" button, last synced time
- **Calendar section:**
  - Shows EventKit permission status (granted/denied/not determined)
  - "Request Access" button if not determined
  - Link to System Preferences > Privacy > Calendars if denied
- Status indicators: green checkmark / red X / yellow pending

---

## Implementation Order

```
Step 1: 4C — NotificationManager + ConfirmationManager (foundation for everything)
Step 2: 4A — Calendar tools (EventKit, no OAuth complexity)
Step 3: 4D — Response viewer (independent, improves UX immediately)
Step 4: 4B — OAuth + Gmail tools (most complex, builds on 4C for confirmations)
Step 5: 4E — Accounts settings tab (ties it all together)
```

---

## New File Count: 6 new files

| File | LOC Estimate |
|---|---|
| `Tools/CalendarTools.swift` | ~250 |
| `Core/OAuth/GoogleOAuthManager.swift` | ~200 |
| `Core/OAuth/OAuthTokenStore.swift` | ~80 |
| `Tools/EmailTools.swift` | ~350 |
| `Core/NotificationManager.swift` | ~120 |
| `Core/ConfirmationManager.swift` | ~60 |
| `UI/ResponseDetailView.swift` | ~120 |
| `Settings/AccountsSettingsView.swift` | ~130 |
| **Total new** | **~1,310 LOC** |

**Modified files:** ~8 existing files with moderate changes

---

## Google Cloud Setup Checklist (before coding 4B)

1. Go to https://console.cloud.google.com/
2. Create project "Majoor" (or use existing)
3. Enable APIs:
   - Gmail API
4. Create OAuth 2.0 Client ID:
   - Application type: **macOS** (or "Desktop app")
   - Note the Client ID and Client Secret
5. Configure OAuth consent screen:
   - App name: Majoor
   - Scopes: `gmail.modify`
   - Test users: add your Gmail address
6. Add Client ID and Secret to `APIConfig.swift`

---

## Milestone

> User can say "what's on my calendar today", "draft a reply to John's email about the deadline", or "send an email to sarah@example.com about the meeting" — and the agent does it, asking for confirmation before sending. Long responses display in a scrollable viewer.

---

## TaskClassifier Updates

Add new categories to route email/calendar tasks to Sonnet:

```swift
// New category
case emailCalendar   // → Sonnet

// New keyword patterns
(["email", "gmail", "inbox", "unread", "send email", "draft email",
  "reply to", "email me", "calendar", "schedule", "meeting",
  "appointment", "event", "what's on my"], .emailCalendar),
```

Update `ModelRouter` to route `.emailCalendar` → Sonnet.

---

## System Prompt Update

Add to AgentLoop's system prompt:
```
- Calendar: read, create, update, and delete calendar events via Apple Calendar (EventKit)
- Email: fetch, read, search, draft, send, and reply to emails via Gmail. ALWAYS ask for confirmation before sending or replying to emails — use the send_email or reply_to_email tools which will prompt the user.
```

Add email safety rule:
```
11. Email safety — NEVER send an email without using the send_email tool (which triggers user confirmation). Always show the user what you're about to send. If drafting, use draft_email which saves but doesn't send.
```

---
name: Settings & Onboarding Apple HIG Redesign
description: Complete rewrite of all settings tabs and onboarding wizard to match macOS System Settings patterns
type: project
---

Apple HIG-aligned redesign of Settings + Onboarding completed.

**Key design decisions:**
- Settings: `.formStyle(.grouped)` everywhere, `Section` with header/footer, native `LabeledContent`, `Toggle`, `Button` controls
- Accounts: Label-based rows with icon + title + description pattern, status shown inline, destructive actions use `.plain` style with `.red` foregroundStyle
- MCP/Integrations: Status dot + name + description pattern, token input uses `.borderedProminent` Save + plain Cancel
- Memory: Toolbar-style search bar with `.bar` background, `.inset(alternatesRowBackgrounds: true)` list, hover-reveal delete
- Usage: `.rounded` monospaced font for cost figures, `LabeledContent` for model breakdown rows
- Onboarding: Setup Assistant pattern (28pt bold title, 13pt secondary description, generous 36pt horizontal padding, `controlSize(.large)` for primary buttons)
- Window sizes bumped: Settings 620x520, Onboarding 560x480, AppDelegate window creation uses DT.Layout tokens

**Why:** User wants "looks like Apple made it." These patterns come directly from System Settings, Xcode Preferences, and macOS Setup Assistant.

**How to apply:** All future settings/form UI should follow these patterns. Use `Section` with `header`/`footer` params, never custom section headers. Use native controls, never replicas.

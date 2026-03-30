---
name: Design System & Settings Full Audit
description: Complete audit of DT tokens, all 6 settings tabs, onboarding, ResponseDetailView — state as of 2026-03-30
type: project
---

## Design Tokens (DT) - Current State
- 5 font levels: micro(10), caption(11), body(13), headline(14), largeInput(17)
- 5 spacing: xs(4), sm(8), md(12), lg(16), xl(20) -- md=12 breaks pure 8pt grid
- 3 radii: small(6), medium(10), large(14)
- 4 opacities: cardFill(0.06), hoverFill(0.08), pressedFill(0.12), subtleBorder(0.08)
- 3 shadows: card, toast, floating
- HoverCardModifier + HoverButtonStyle helpers

## Settings Architecture
- 6 tabs: General, Accounts, Integrations, Memory, Usage, About
- General is overloaded: 8 sections (Startup, Notifications, Keyboard, Updates, Models, API, Setup, Safety)
- Window: 540x480
- All tabs use .formStyle(.grouped) EXCEPT Memory (custom VStack+List) and About (centered VStack)
- Onboarding: 5 steps, 500x400, directional transitions

## Systemic Anti-patterns
1. DT tokens exist but ~80% of views still use raw .font(.system(size: X))
2. Zero semantic color tokens — raw .green/.red/.orange/.secondary everywhere
3. Zero animation duration tokens
4. Duplicate utility functions (friendlyModel, formatTokens) in UIHelpers + UsageSettingsView
5. Inconsistent button sizing: mix of .font(.caption), .font(.system(size: 11/12))
6. Inconsistent destructive styling: red foreground text vs .destructive role
7. Memory tab structurally different from all other tabs
8. No consistent "row with status indicator" pattern across Accounts/MCP

**Why:** Design system is defined but not adopted. Views were built ad-hoc before DT existed.
**How to apply:** All settings/secondary UI code changes must use DT tokens exclusively. General tab needs restructuring. Memory tab needs Form conversion.

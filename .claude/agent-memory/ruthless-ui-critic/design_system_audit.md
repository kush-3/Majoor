---
name: Design System Audit - March 2026
description: Comprehensive audit of all design tokens, spacing, typography, color, corner radii, and shadow values found across the Majoor UI codebase. No centralized design system file exists.
type: project
---

## No Centralized Design System
There is no Theme.swift, DesignSystem.swift, or Constants.swift file. All values are hardcoded inline across 11 UI files.

## Typography Scale (font sizes found)
- 9pt: Hints, model labels, token counts, keyboard hint actions
- 10pt: Timestamps, action buttons, step counts, tool call labels, keyboard hint keys, toast action buttons
- 11pt: Section headers, task summaries, step descriptions, footer text, toast body, chat empty sub-text, confirmation body, pipeline steps
- 12pt: Task input titles, chat messages, chat input, confirmation title, back button, stop button, feedback input, response body, pipeline step descriptions
- 13pt: Chat empty state title, confirmation header title, panel header title, command bar running task body, response header input, activity empty state title
- 14pt: Panel header icon+title, confirmation header text
- 16pt: Task notification title, toast icons
- 17pt: Command bar input field
- 20pt: Chat send button icon
- 22pt: Command bar submit button icon
- 28pt: Chat empty state icon
- 32pt: Activity empty state icon
- 40pt: Task notification icon

**Problem**: 15+ distinct font sizes. Should be 4-5 max.

## Spacing Values (padding)
- Horizontal padding: 4, 8, 12, 14, 16, 20, 24
- Vertical padding: 1, 2, 3, 4, 6, 8, 10, 12, 14
- VStack spacing: 0, 2, 4, 6, 8, 10, 12, 16
- HStack spacing: 3, 4, 6, 8, 10, 12, 16

**Problem**: Not on a consistent 4pt/8pt grid. Values like 3, 6, 10, 14 break the grid.

## Corner Radii
- 3pt: Keyboard hint keys
- 6pt: Feedback input field
- 10pt: Task cards, toast cards
- 14pt: Chat bubbles
- 16pt: Command bar window

**Problem**: 5 different corner radii with no semantic naming.

## Shadow Values
- Task cards: .black.opacity(0.04), radius: 3, y: 1
- Toast cards: .black.opacity(0.1), radius: 8, y: 4
- Command bar: .black.opacity(0.18), radius: 24, y: 12

## Opacity Values Used
- 0.02, 0.03, 0.04, 0.05, 0.06, 0.08, 0.1, 0.12, 0.18, 0.3, 0.4, 0.5, 0.6, 0.7
**Problem**: 14+ distinct opacity values with no semantic purpose.

## Color Usage
- No custom named colors. Uses only system colors: .accentColor, .green, .red, .orange, .blue, .purple, .white, .primary, .secondary
- Status colors: running=orange, completed=green, failed=red, waiting=blue
- Dark mode: relies entirely on .regularMaterial and system colors (no custom dark mode handling)

## Animation Durations
- 0.15s: scroll-to-bottom, mode toggle
- 0.2s: card expand, toast dismiss
- 0.25s: toast appear
- 0.6s: status bar pulse timer

## Panel Dimensions
- Main panel: 400x520 (hardcoded in MainPanelView.swift AND AppDelegate.swift)
- Command bar: 600px wide, ~80px tall initial
- Settings: 500x350
- Onboarding: 500x400

## Key Missing Patterns
- No hover states on any interactive elements (task cards, buttons)
- No focus rings visible
- No loading skeleton states
- No animated typing indicator (dots don't animate)
- No Markdown rendering in chat (only in ResponseDetailView)
- friendlyModel() and formatTokens() duplicated in ActivityFeedView and ResponseDetailView

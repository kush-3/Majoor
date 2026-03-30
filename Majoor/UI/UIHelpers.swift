// UIHelpers.swift
// Majoor — Shared UI utility functions.
// Referenced by ActivityFeedView and ResponseDetailView.

import Foundation

/// Returns a human-readable model family name from a full model identifier string.
func friendlyModel(_ model: String) -> String {
    if model.contains("opus") { return "Opus" }
    if model.contains("haiku") { return "Haiku" }
    if model.contains("sonnet") { return "Sonnet" }
    return model
}

/// Formats a raw token count into a compact display string.
func formatTokens(_ tokens: Int) -> String {
    if tokens >= 1000 { return String(format: "%.1fK", Double(tokens) / 1000) }
    return "\(tokens)"
}

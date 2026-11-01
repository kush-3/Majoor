// DataClass.swift
// Majoor — What kind of data a tool, source or job touches
//
// PRD §6: routing by data class, not by task category. "Summarize my inbox"
// is personal only because `fetch_emails` returns bodies, so the class lives
// on the tool (and on event sources and job inputs), and the privacy preset
// decides the highest tier each class may reach. Router v2 (Phase 2 step 3)
// adds `PrivacyPreset` and the per-tool declarations; event sources (step 4)
// declare theirs from the start. The enum is here first so both can share it.

import Foundation

nonisolated enum DataClass: String, Codable, Sendable, CaseIterable {
    case emailMeta
    case emailBody
    case contacts
    case calendar
    case messages
    case location
    case finance
    case files
    case web
    case code
    case repoContext
    case majoorState

    var displayName: String {
        switch self {
        case .emailMeta: return "Email headers"
        case .emailBody: return "Email bodies"
        case .contacts: return "Contacts"
        case .calendar: return "Calendar"
        case .messages: return "Messages"
        case .location: return "Location"
        case .finance: return "Finance"
        case .files: return "Files"
        case .web: return "Web pages"
        case .code: return "Code"
        case .repoContext: return "Repository context"
        case .majoorState: return "Majoor's own state"
        }
    }
}

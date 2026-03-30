// EmailTools.swift
// Majoor — Gmail API Tools
//
// 6 tools: fetch_emails, read_email, search_emails, draft_email, send_email, reply_to_email
// Uses Gmail REST API with OAuth tokens from GoogleOAuthManager.

import Foundation

// MARK: - Gmail API Helper

private struct GmailAPI {

    static let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

    /// Make an authenticated Gmail API request with retry and exponential backoff.
    static func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, Int) {
        let maxAttempts = 3
        var lastError: (any Error)?

        for attempt in 0..<maxAttempts {
            let token = try await GoogleOAuthManager.shared.validAccessToken()
            let url = URL(string: "\(baseURL)\(path)")!

            var req = URLRequest(url: url, timeoutInterval: 30)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let data: Data
            let statusCode: Int
            do {
                let (responseData, response) = try await URLSession.shared.data(for: req)
                data = responseData
                statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                lastError = error
                if attempt < maxAttempts - 1 {
                    let delay: UInt64 = [1, 2, 4][attempt] * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                }
                continue
            }

            switch statusCode {
            case 200...299:
                return (data, statusCode)
            case 401:
                throw OAuthError.notAuthenticated
            case 429:
                if attempt < maxAttempts - 1 {
                    let delay: UInt64 = [4, 8, 16][attempt] * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }
                return (data, statusCode)
            case 500...599:
                if attempt < maxAttempts - 1 {
                    let delay: UInt64 = [2, 4, 8][attempt] * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }
                return (data, statusCode)
            default:
                return (data, statusCode)
            }
        }

        throw lastError ?? OAuthError.notAuthenticated
    }

    /// Parse a Gmail message JSON into a readable format
    static func parseMessage(_ msg: [String: Any], fullBody: Bool = false) -> String {
        let headers = (msg["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        let headerDict: [String: String] = headers.reduce(into: [:]) { dict, h in
            guard let name = h["name"] as? String,
                  let value = h["value"] as? String else { return }
            let key = name.lowercased()
            if dict[key] == nil {
                dict[key] = value
            }
        }

        let id = msg["id"] as? String ?? "unknown"
        let subject = headerDict["subject"] ?? "(no subject)"
        let from = headerDict["from"] ?? "unknown"
        let to = headerDict["to"] ?? ""
        let date = headerDict["date"] ?? ""
        let snippet = msg["snippet"] as? String ?? ""

        var lines = [
            "ID: \(id)",
            "From: \(from)",
            "To: \(to)",
            "Date: \(date)",
            "Subject: \(subject)",
        ]

        if fullBody {
            let body = extractBody(from: msg)
            lines.append("Body:\n\(body)")
        } else {
            lines.append("Snippet: \(snippet)")
        }

        return lines.joined(separator: "\n")
    }

    /// Extract plain text body from a Gmail message
    static func extractBody(from msg: [String: Any]) -> String {
        guard let payload = msg["payload"] as? [String: Any] else { return "(no body)" }

        // Try direct body first
        if let body = payload["body"] as? [String: Any],
           let data = body["data"] as? String,
           let decoded = base64URLDecode(data) {
            return decoded
        }

        // Try parts (multipart messages)
        if let parts = payload["parts"] as? [[String: Any]] {
            // Prefer text/plain
            for part in parts {
                if let mimeType = part["mimeType"] as? String, mimeType == "text/plain",
                   let body = part["body"] as? [String: Any],
                   let data = body["data"] as? String,
                   let decoded = base64URLDecode(data) {
                    return decoded
                }
            }
            // Fallback to text/html with tags stripped
            for part in parts {
                if let mimeType = part["mimeType"] as? String, mimeType == "text/html",
                   let body = part["body"] as? [String: Any],
                   let data = body["data"] as? String,
                   let decoded = base64URLDecode(data) {
                    return stripHTML(decoded)
                }
            }
            // Recursive: check nested parts (e.g., multipart/alternative inside multipart/mixed)
            for part in parts {
                if let nestedParts = part["parts"] as? [[String: Any]] {
                    let nestedMsg: [String: Any] = ["payload": ["parts": nestedParts]]
                    let result = extractBody(from: nestedMsg)
                    if result != "(no body)" { return result }
                }
            }
        }

        return "(no body)"
    }

    static func base64URLDecode(_ string: String) -> String? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s*\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build RFC 2822 email and base64url-encode it for Gmail API
    static func buildRawEmail(to: String, subject: String, body: String, threadId: String? = nil, inReplyTo: String? = nil) -> String {
        var message = "To: \(to)\r\n"
        message += "Subject: \(subject)\r\n"
        if let inReplyTo {
            message += "In-Reply-To: \(inReplyTo)\r\n"
            message += "References: \(inReplyTo)\r\n"
        }
        message += "Content-Type: text/plain; charset=utf-8\r\n"
        message += "\r\n"
        message += body

        let data = message.data(using: .utf8)!
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Fetch Emails

nonisolated struct FetchEmailsTool: AgentTool, Sendable {
    let name = "fetch_emails"
    let description = "Fetch recent emails from Gmail. Supports Gmail search queries like 'is:unread', 'from:john@example.com', 'newer_than:2d'."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "query", description: "Gmail search query (e.g., 'is:unread', 'from:sarah@', 'subject:invoice'). Defaults to inbox."),
        ToolParameter(name: "max_results", description: "Maximum number of emails to return (default: 10, max: 20)"),
    ]
    let requiredParameters: [String] = []
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard GoogleOAuthManager.shared.isAuthenticated else {
            return ToolResult(success: false, output: "Gmail not connected. Connect your account in Settings > Accounts.")
        }

        let query = arguments["query"] ?? "in:inbox"
        let maxResults = min(Int(arguments["max_results"] ?? "10") ?? 10, 20)

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let (data, status) = try await GmailAPI.request("/messages?q=\(encodedQuery)&maxResults=\(maxResults)")

        guard status == 200 else {
            return ToolResult(success: false, output: "Gmail API error (HTTP \(status)): \(String(data: data, encoding: .utf8) ?? "unknown")")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            return ToolResult(success: true, output: "No emails found matching: \(query)")
        }

        // Fetch each message's metadata
        var results: [String] = []
        for msg in messages.prefix(maxResults) {
            guard let msgId = msg["id"] as? String else { continue }
            let (msgData, msgStatus) = try await GmailAPI.request("/messages/\(msgId)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=To")
            guard msgStatus == 200,
                  let msgJson = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] else { continue }
            results.append(GmailAPI.parseMessage(msgJson))
        }

        if results.isEmpty {
            return ToolResult(success: true, output: "No emails found matching: \(query)")
        }

        return ToolResult(success: true, output: "Found \(results.count) email(s):\n\n\(results.joined(separator: "\n---\n"))")
    }
}

// MARK: - Read Email

nonisolated struct ReadEmailTool: AgentTool, Sendable {
    let name = "read_email"
    let description = "Read the full content of a specific email by its ID."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "email_id", description: "The email ID (from fetch_emails or search_emails)"),
    ]
    let requiredParameters = ["email_id"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard GoogleOAuthManager.shared.isAuthenticated else {
            return ToolResult(success: false, output: "Gmail not connected. Connect your account in Settings > Accounts.")
        }
        guard let emailId = arguments["email_id"] else {
            return ToolResult(success: false, output: "Error: 'email_id' is required.")
        }

        let (data, status) = try await GmailAPI.request("/messages/\(emailId)?format=full")
        guard status == 200 else {
            return ToolResult(success: false, output: "Gmail API error (HTTP \(status))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ToolResult(success: false, output: "Failed to parse email.")
        }

        return ToolResult(success: true, output: GmailAPI.parseMessage(json, fullBody: true))
    }
}

// MARK: - Search Emails

nonisolated struct SearchEmailsTool: AgentTool, Sendable {
    let name = "search_emails"
    let description = "Search emails using Gmail's search syntax. Returns matching emails with snippets."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "query", description: "Gmail search query (e.g., 'from:john subject:meeting has:attachment')"),
    ]
    let requiredParameters = ["query"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        // Delegate to FetchEmailsTool — same underlying API
        let fetchTool = FetchEmailsTool()
        return try await fetchTool.execute(arguments: arguments)
    }
}

// MARK: - Draft Email

nonisolated struct DraftEmailTool: AgentTool, Sendable {
    let name = "draft_email"
    let description = "Create a Gmail draft (does NOT send). Returns the draft ID."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "to", description: "Recipient email address"),
        ToolParameter(name: "subject", description: "Email subject"),
        ToolParameter(name: "body", description: "Email body (plain text)"),
    ]
    let requiredParameters = ["to", "subject", "body"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard GoogleOAuthManager.shared.isAuthenticated else {
            return ToolResult(success: false, output: "Gmail not connected. Connect your account in Settings > Accounts.")
        }
        guard let to = arguments["to"], let subject = arguments["subject"], let body = arguments["body"] else {
            return ToolResult(success: false, output: "Error: 'to', 'subject', and 'body' are required.")
        }

        let raw = GmailAPI.buildRawEmail(to: to, subject: subject, body: body)
        let draftBody = try JSONSerialization.data(withJSONObject: ["message": ["raw": raw]])

        let (data, status) = try await GmailAPI.request("/drafts", method: "POST", body: draftBody)
        guard status == 200 else {
            return ToolResult(success: false, output: "Failed to create draft (HTTP \(status)): \(String(data: data, encoding: .utf8) ?? "")")
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let draftId = json?["id"] as? String ?? "unknown"

        return ToolResult(success: true, output: "Draft created (ID: \(draftId)).\nTo: \(to)\nSubject: \(subject)\n\nThis draft has NOT been sent. Use send_email to send it.")
    }
}

// MARK: - Send Email (requires confirmation)

nonisolated struct SendEmailTool: AgentTool, Sendable {
    let name = "send_email"
    let description = "Send an email via Gmail. Requires user confirmation via notification before sending."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "to", description: "Recipient email address"),
        ToolParameter(name: "subject", description: "Email subject"),
        ToolParameter(name: "body", description: "Email body (plain text)"),
    ]
    let requiredParameters = ["to", "subject", "body"]
    let requiresConfirmation = true

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard GoogleOAuthManager.shared.isAuthenticated else {
            return ToolResult(success: false, output: "Gmail not connected. Connect your account in Settings > Accounts.")
        }
        guard let to = arguments["to"], let subject = arguments["subject"], let body = arguments["body"] else {
            return ToolResult(success: false, output: "Error: 'to', 'subject', and 'body' are required.")
        }

        let raw = GmailAPI.buildRawEmail(to: to, subject: subject, body: body)
        let sendBody = try JSONSerialization.data(withJSONObject: ["raw": raw])

        let (data, status) = try await GmailAPI.request("/messages/send", method: "POST", body: sendBody)
        guard status == 200 else {
            return ToolResult(success: false, output: "Failed to send email (HTTP \(status)): \(String(data: data, encoding: .utf8) ?? "")")
        }

        return ToolResult(success: true, output: "Email sent successfully!\nTo: \(to)\nSubject: \(subject)")
    }
}

// MARK: - Reply to Email (requires confirmation)

nonisolated struct ReplyToEmailTool: AgentTool, Sendable {
    let name = "reply_to_email"
    let description = "Reply to an existing email thread. Requires user confirmation before sending."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "email_id", description: "The email ID to reply to (from fetch_emails)"),
        ToolParameter(name: "body", description: "Reply body (plain text)"),
    ]
    let requiredParameters = ["email_id", "body"]
    let requiresConfirmation = true

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard GoogleOAuthManager.shared.isAuthenticated else {
            return ToolResult(success: false, output: "Gmail not connected. Connect your account in Settings > Accounts.")
        }
        guard let emailId = arguments["email_id"], let body = arguments["body"] else {
            return ToolResult(success: false, output: "Error: 'email_id' and 'body' are required.")
        }

        // Fetch original email to get thread info
        let (origData, origStatus) = try await GmailAPI.request("/messages/\(emailId)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Message-Id")
        guard origStatus == 200,
              let origJson = try? JSONSerialization.jsonObject(with: origData) as? [String: Any] else {
            return ToolResult(success: false, output: "Could not fetch original email.")
        }

        let headers = ((origJson["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        let headerDict = Dictionary(uniqueKeysWithValues: headers.compactMap { h -> (String, String)? in
            guard let name = h["name"] as? String, let value = h["value"] as? String else { return nil }
            return (name.lowercased(), value)
        })

        let replyTo = headerDict["from"] ?? ""
        let subject = "Re: \(headerDict["subject"] ?? "")"
        let messageId = headerDict["message-id"]
        let threadId = origJson["threadId"] as? String

        // Send the reply
        let raw = GmailAPI.buildRawEmail(to: replyTo, subject: subject, body: body, threadId: threadId, inReplyTo: messageId)
        var sendPayload: [String: Any] = ["raw": raw]
        if let threadId { sendPayload["threadId"] = threadId }
        let sendBody = try JSONSerialization.data(withJSONObject: sendPayload)

        let (data, status) = try await GmailAPI.request("/messages/send", method: "POST", body: sendBody)
        guard status == 200 else {
            return ToolResult(success: false, output: "Failed to send reply (HTTP \(status)): \(String(data: data, encoding: .utf8) ?? "")")
        }

        return ToolResult(success: true, output: "Reply sent successfully!\nTo: \(replyTo)\nSubject: \(subject)")
    }
}

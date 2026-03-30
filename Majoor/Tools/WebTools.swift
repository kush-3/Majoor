// WebTools.swift
// Majoor — Web Research Tools
//
// Web search via Tavily API, webpage fetching with HTML-to-text extraction.

import Foundation

// MARK: - Web Search (Tavily)

nonisolated struct WebSearchTool: AgentTool {
    let name = "web_search"
    let description = "Search the web using Tavily API. Returns relevant results with extracted content, optimized for AI agents."
    let parameters = [
        ToolParameter(name: "query", description: "Search query (e.g., 'best project management tools 2026')"),
        ToolParameter(name: "max_results", type: "integer", description: "Number of results to return. Default 5, max 10.")
    ]
    let requiredParameters = ["query"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let query = arguments["query"] else {
            return ToolResult(success: false, output: "Error: 'query' is required")
        }

        let apiKey = APIConfig.tavilyAPIKey
        guard !apiKey.isEmpty else {
            return ToolResult(success: false, output: "Error: Tavily API key not configured in APIConfig.swift")
        }

        let maxResults = min(Int(arguments["max_results"] ?? "5") ?? 5, 10)

        // Build Tavily API request
        let url = URL(string: "https://api.tavily.com/search")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": maxResults,
            "include_answer": true,
            "include_raw_content": false,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, httpResponse) = try await URLSession.shared.data(for: request)

            if let http = httpResponse as? HTTPURLResponse, http.statusCode != 200 {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                return ToolResult(success: false, output: "Tavily API error (HTTP \(http.statusCode)): \(errorBody)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ToolResult(success: false, output: "Error: Failed to parse Tavily response")
            }

            var output = "Search results for: \"\(query)\"\n\n"

            // Include the AI-generated answer if available
            if let answer = json["answer"] as? String, !answer.isEmpty {
                output += "📝 Summary: \(answer)\n\n---\n\n"
            }

            // Parse results
            if let results = json["results"] as? [[String: Any]] {
                for (i, result) in results.enumerated() {
                    let title = result["title"] as? String ?? "Untitled"
                    let url = result["url"] as? String ?? ""
                    let content = result["content"] as? String ?? ""
                    output += "[\(i + 1)] \(title)\n"
                    output += "    URL: \(url)\n"
                    if !content.isEmpty {
                        let trimmed = String(content.prefix(300))
                        output += "    \(trimmed)\n"
                    }
                    output += "\n"
                }
            }

            return ToolResult(success: true, output: output)
        } catch {
            return ToolResult(success: false, output: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Fetch Webpage

nonisolated struct FetchWebpageTool: AgentTool {
    let name = "fetch_webpage"
    let description = "Fetch a webpage URL and extract its text content. Strips HTML tags to return readable text."
    let parameters = [
        ToolParameter(name: "url", description: "The URL to fetch (e.g., 'https://example.com/article')"),
        ToolParameter(name: "max_length", type: "integer", description: "Max characters to return. Default 5000.")
    ]
    let requiredParameters = ["url"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let urlStr = arguments["url"] else {
            return ToolResult(success: false, output: "Error: 'url' is required")
        }
        guard let url = URL(string: urlStr) else {
            return ToolResult(success: false, output: "Error: Invalid URL: \(urlStr)")
        }

        let maxLength = Int(arguments["max_length"] ?? "5000") ?? 5000

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, httpResponse) = try await URLSession.shared.data(for: request)

            if let http = httpResponse as? HTTPURLResponse, http.statusCode != 200 {
                return ToolResult(success: false, output: "HTTP \(http.statusCode) fetching \(urlStr)")
            }

            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                return ToolResult(success: false, output: "Error: Could not decode response from \(urlStr)")
            }

            let text = extractText(from: html)
            let truncated = text.count > maxLength ? String(text.prefix(maxLength)) + "\n\n... [truncated]" : text

            return ToolResult(success: true, output: "Content from \(urlStr):\n\n\(truncated)")
        } catch {
            return ToolResult(success: false, output: "Error fetching \(urlStr): \(error.localizedDescription)")
        }
    }

    /// Basic HTML-to-text extraction (no external dependencies)
    private func extractText(from html: String) -> String {
        var text = html

        // Remove script and style blocks entirely
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<noscript[^>]*>[\\s\\S]*?</noscript>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)

        // Convert common block elements to newlines
        let blockTags = ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>",
                         "<br>", "<br/>", "<br />", "</li>", "</tr>", "</blockquote>"]
        for tag in blockTags {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        // Strip all remaining HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Decode common HTML entities
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&copy;", "©"), ("&reg;", "®"),
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char, options: .caseInsensitive)
        }

        // Clean up whitespace: collapse multiple blank lines, trim lines
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        text = lines.joined(separator: "\n")

        return text
    }
}

// MARK: - Fetch Multiple URLs

nonisolated struct FetchMultipleURLsTool: AgentTool {
    let name = "fetch_multiple_urls"
    let description = "Fetch multiple URLs in parallel for comparison research. Returns extracted text from each."
    let parameters = [
        ToolParameter(name: "urls", description: "Comma-separated list of URLs to fetch"),
        ToolParameter(name: "max_length_per_url", type: "integer", description: "Max characters per URL. Default 2000.")
    ]
    let requiredParameters = ["urls"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let urlsStr = arguments["urls"] else {
            return ToolResult(success: false, output: "Error: 'urls' is required")
        }

        let maxLen = arguments["max_length_per_url"] ?? "2000"
        let urls = urlsStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        if urls.count > 5 {
            return ToolResult(success: false, output: "Error: Maximum 5 URLs at a time. Got \(urls.count).")
        }

        let fetchTool = FetchWebpageTool()
        var output = "Fetched \(urls.count) URLs:\n\n"

        // Fetch all URLs concurrently
        await withTaskGroup(of: (Int, String, ToolResult).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    do {
                        let result = try await fetchTool.execute(arguments: ["url": url, "max_length": maxLen])
                        return (i, url, result)
                    } catch {
                        return (i, url, ToolResult(success: false, output: "Error fetching \(url): \(error.localizedDescription)"))
                    }
                }
            }

            var results: [(Int, String, ToolResult)] = []
            for await result in group {
                results.append(result)
            }
            results.sort { $0.0 < $1.0 }

            for (i, url, result) in results {
                output += "=== [\(i + 1)] \(url) ===\n"
                output += result.success ? result.output : "Error: \(result.output)"
                output += "\n\n"
            }
        }

        return ToolResult(success: true, output: output)
    }
}

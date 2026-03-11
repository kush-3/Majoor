// FileTools.swift
// Majoor — File Management Tools
//
// All tools are nonisolated + Sendable for Swift 6 compatibility.
// Arguments are [String: String] for Sendable safety.

import Foundation

// MARK: - List Directory

struct ListDirectoryTool: AgentTool {
    let name = "list_directory"
    let description = "List the contents of a directory. Returns file names, types, and sizes."
    let parameters = [
        ToolParameter(name: "path", description: "The directory path to list (e.g., ~/Downloads)"),
        ToolParameter(name: "showHidden", type: "boolean", description: "Include hidden files. Defaults to false.")
    ]
    let requiredParameters = ["path"]
    let requiresConfirmation = false
    
    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["path"] else {
            return ToolResult(success: false, output: "Error: 'path' is required")
        }
        let showHidden = arguments["showHidden"] == "true"
        let expanded = NSString(string: path).expandingTildeInPath
        let fm = FileManager.default
        
        guard fm.fileExists(atPath: expanded) else {
            return ToolResult(success: false, output: "Error: Directory not found: \(path)")
        }
        do {
            var items = try fm.contentsOfDirectory(atPath: expanded)
            if !showHidden { items = items.filter { !$0.hasPrefix(".") } }
            items.sort()
            
            var output = "Contents of \(path) (\(items.count) items):\n\n"
            for item in items {
                let fullPath = (expanded as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                let attrs = try? fm.attributesOfItem(atPath: fullPath)
                let size = attrs?[.size] as? Int64 ?? 0
                let modDate = attrs?[.modificationDate] as? Date
                let icon = isDir.boolValue ? "📁" : fileIcon(for: item)
                let sizeStr = isDir.boolValue ? "--" : formatBytes(size)
                let dateStr = modDate.map { formatDate($0) } ?? ""
                output += "\(icon) \(item)  [\(sizeStr)]  \(dateStr)\n"
            }
            return ToolResult(success: true, output: output)
        } catch {
            return ToolResult(success: false, output: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Read File

struct ReadFileTool: AgentTool {
    let name = "read_file"
    let description = "Read the contents of a text file."
    let parameters = [
        ToolParameter(name: "path", description: "The file path to read"),
        ToolParameter(name: "maxLines", type: "integer", description: "Max lines to read. Default 200.")
    ]
    let requiredParameters = ["path"]
    let requiresConfirmation = false
    
    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["path"] else {
            return ToolResult(success: false, output: "Error: 'path' is required")
        }
        let maxLines = Int(arguments["maxLines"] ?? "200") ?? 200
        let expanded = NSString(string: path).expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: expanded) else {
            return ToolResult(success: false, output: "Error: File not found: \(path)")
        }
        do {
            let content = try String(contentsOfFile: expanded, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            if lines.count > maxLines {
                let truncated = lines.prefix(maxLines).joined(separator: "\n")
                return ToolResult(success: true, output: "File: \(path) (\(lines.count) lines, showing \(maxLines)):\n\n\(truncated)\n\n... [\(lines.count - maxLines) more]")
            }
            return ToolResult(success: true, output: "File: \(path) (\(lines.count) lines):\n\n\(content)")
        } catch {
            return ToolResult(success: false, output: "Error reading file: \(error.localizedDescription)")
        }
    }
}

// MARK: - Write File

struct WriteFileTool: AgentTool {
    let name = "write_file"
    let description = "Write content to a file. Creates if missing, overwrites if exists."
    let parameters = [
        ToolParameter(name: "path", description: "File path to write to"),
        ToolParameter(name: "content", description: "Content to write")
    ]
    let requiredParameters = ["path", "content"]
    let requiresConfirmation = false
    
    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["path"], let content = arguments["content"] else {
            return ToolResult(success: false, output: "Error: 'path' and 'content' required. Received keys: \(arguments.keys.sorted().joined(separator: ", "))")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        let parentDir = (expanded as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        do {
            try content.write(toFile: expanded, atomically: true, encoding: .utf8)
            return ToolResult(success: true, output: "Wrote \(content.count) characters to \(path)")
        } catch {
            return ToolResult(success: false, output: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Move File

struct MoveFileTool: AgentTool {
    let name = "move_file"
    let description = "Move or rename a file/directory."
    let parameters = [
        ToolParameter(name: "source", description: "Current path"),
        ToolParameter(name: "destination", description: "New path")
    ]
    let requiredParameters = ["source", "destination"]
    let requiresConfirmation = false
    
    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let src = arguments["source"], let dst = arguments["destination"] else {
            return ToolResult(success: false, output: "Error: 'source' and 'destination' required")
        }
        let expandedSrc = NSString(string: src).expandingTildeInPath
        let expandedDst = NSString(string: dst).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedSrc) else {
            return ToolResult(success: false, output: "Error: Source not found: \(src)")
        }
        let parentDir = (expandedDst as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(atPath: expandedSrc, toPath: expandedDst)
            return ToolResult(success: true, output: "Moved: \(src) → \(dst)")
        } catch {
            return ToolResult(success: false, output: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Copy File

struct CopyFileTool: AgentTool {
    let name = "copy_file"
    let description = "Copy a file or directory."
    let parameters = [
        ToolParameter(name: "source", description: "Path to copy from"),
        ToolParameter(name: "destination", description: "Path to copy to")
    ]
    let requiredParameters = ["source", "destination"]
    let requiresConfirmation = false
    
    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let src = arguments["source"], let dst = arguments["destination"] else {
            return ToolResult(success: false, output: "Error: 'source' and 'destination' required")
        }
        let expandedSrc = NSString(string: src).expandingTildeInPath
        let expandedDst = NSString(string: dst).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedSrc) else {
            return ToolResult(success: false, output: "Error: Source not found: \(src)")
        }
        let parentDir = (expandedDst as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(atPath: expandedSrc, toPath: expandedDst)
            return ToolResult(success: true, output: "Copied: \(src) → \(dst)")
        } catch {
            return ToolResult(success: false, output: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Delete File (Trash)

struct DeleteFileTool: AgentTool {
    let name = "delete_file"
    let description = "Delete a file by moving it to Trash (recoverable)."
    let parameters = [
        ToolParameter(name: "path", description: "Path of file to delete")
    ]
    let requiredParameters = ["path"]
    let requiresConfirmation = true
    
    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["path"] else {
            return ToolResult(success: false, output: "Error: 'path' required")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return ToolResult(success: false, output: "Error: File not found: \(path)")
        }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: expanded), resultingItemURL: nil)
            return ToolResult(success: true, output: "Moved to Trash: \(path)")
        } catch {
            return ToolResult(success: false, output: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Search Files

struct SearchFilesTool: AgentTool {
    let name = "search_files"
    let description = "Search for files by name within a directory. Supports wildcards (*.pdf)."
    let parameters = [
        ToolParameter(name: "directory", description: "Directory to search in"),
        ToolParameter(name: "query", description: "Search pattern (e.g., '*.pdf', 'invoice')"),
        ToolParameter(name: "maxResults", type: "integer", description: "Max results. Default 20.")
    ]
    let requiredParameters = ["directory", "query"]
    let requiresConfirmation = false
    
    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let directory = arguments["directory"], let query = arguments["query"] else {
            return ToolResult(success: false, output: "Error: 'directory' and 'query' required")
        }
        let maxResults = Int(arguments["maxResults"] ?? "20") ?? 20
        let expanded = NSString(string: directory).expandingTildeInPath
        let fm = FileManager.default
        
        guard fm.fileExists(atPath: expanded) else {
            return ToolResult(success: false, output: "Error: Directory not found: \(directory)")
        }
        var matches: [(path: String, size: Int64, date: Date?)] = []
        if let enumerator = fm.enumerator(atPath: expanded) {
            while let file = enumerator.nextObject() as? String {
                guard matches.count < maxResults else { break }
                let fileName = (file as NSString).lastPathComponent
                if matchesQuery(fileName: fileName, query: query) {
                    let fullPath = (expanded as NSString).appendingPathComponent(file)
                    let attrs = try? fm.attributesOfItem(atPath: fullPath)
                    matches.append((file, attrs?[.size] as? Int64 ?? 0, attrs?[.modificationDate] as? Date))
                }
            }
        }
        if matches.isEmpty {
            return ToolResult(success: true, output: "No files matching '\(query)' in \(directory)")
        }
        var output = "Found \(matches.count) file(s) matching '\(query)':\n\n"
        for m in matches {
            output += "\(fileIcon(for: m.path)) \(m.path)  [\(formatBytes(m.size))]  \(m.date.map { formatDate($0) } ?? "")\n"
        }
        return ToolResult(success: true, output: output)
    }
    
    private func matchesQuery(fileName: String, query: String) -> Bool {
        let lower = fileName.lowercased()
        let q = query.lowercased()
        if q.contains("*") {
            let pattern = q.replacingOccurrences(of: ".", with: "\\.").replacingOccurrences(of: "*", with: ".*")
            return lower.range(of: "^\(pattern)$", options: .regularExpression) != nil
        }
        return lower.contains(q)
    }
}

// MARK: - Get File Info

struct GetFileInfoTool: AgentTool {
    let name = "get_file_info"
    let description = "Get detailed info about a file: size, dates, type."
    let parameters = [
        ToolParameter(name: "path", description: "File path to inspect")
    ]
    let requiredParameters = ["path"]
    let requiresConfirmation = false
    
    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["path"] else {
            return ToolResult(success: false, output: "Error: 'path' required")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: expanded) else {
            return ToolResult(success: false, output: "Error: File not found: \(path)")
        }
        do {
            let attrs = try fm.attributesOfItem(atPath: expanded)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: expanded, isDirectory: &isDir)
            var output = "File Info: \(path)\n"
            output += "  Type: \(isDir.boolValue ? "Directory" : "File")\n"
            output += "  Size: \(formatBytes(attrs[.size] as? Int64 ?? 0))\n"
            if let c = attrs[.creationDate] as? Date { output += "  Created: \(formatDate(c))\n" }
            if let m = attrs[.modificationDate] as? Date { output += "  Modified: \(formatDate(m))\n" }
            if isDir.boolValue, let items = try? fm.contentsOfDirectory(atPath: expanded) {
                output += "  Items: \(items.count)\n"
            }
            return ToolResult(success: true, output: output)
        } catch {
            return ToolResult(success: false, output: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Create Directory

struct CreateDirectoryTool: AgentTool {
    let name = "create_directory"
    let description = "Create a new directory. Creates intermediate directories if needed."
    let parameters = [
        ToolParameter(name: "path", description: "Directory path to create")
    ]
    let requiredParameters = ["path"]
    let requiresConfirmation = false
    
    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let path = arguments["path"] else {
            return ToolResult(success: false, output: "Error: 'path' required")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return ToolResult(success: true, output: "Directory already exists: \(path)")
        }
        do {
            try FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)
            return ToolResult(success: true, output: "Created directory: \(path)")
        } catch {
            return ToolResult(success: false, output: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helpers

nonisolated func fileIcon(for filename: String) -> String {
    let ext = (filename as NSString).pathExtension.lowercased()
    switch ext {
    case "pdf": return "📕"
    case "doc", "docx": return "📘"
    case "xls", "xlsx", "csv": return "📊"
    case "ppt", "pptx": return "📙"
    case "jpg", "jpeg", "png", "gif", "webp", "svg", "heic": return "🖼️"
    case "mp4", "mov", "avi", "mkv": return "🎬"
    case "mp3", "wav", "aac", "flac": return "🎵"
    case "zip", "tar", "gz", "rar": return "📦"
    case "swift", "py", "js", "ts", "java", "cpp", "rs", "go": return "💻"
    case "json", "yaml", "yml", "xml", "toml": return "⚙️"
    case "md", "txt", "rtf": return "📝"
    case "html", "css": return "🌐"
    default: return "📄"
    }
}

nonisolated func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var size = Double(bytes)
    var i = 0
    while size >= 1024 && i < units.count - 1 { size /= 1024; i += 1 }
    return i == 0 ? "\(bytes) B" : String(format: "%.1f %@", size, units[i])
}

nonisolated func formatDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: date)
}

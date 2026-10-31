// NewlineJSONFramer.swift
// Majoor — Splits a byte stream into newline-delimited records
//
// Pure and testable: partial lines wait for the rest, several lines in one
// chunk come out as several records, blank lines are skipped. The caller
// decodes; a non-JSON line is its problem to drop. A line longer than the
// cap is discarded wholesale and the framer resyncs at the next newline,
// so one runaway record cannot grow the buffer without bound.

import Foundation

nonisolated struct NewlineJSONFramer: Sendable {

    static let defaultMaxLineBytes = 4 * 1024 * 1024

    private let maxLineBytes: Int
    private var buffer = Data()
    private var discarding = false
    private(set) var droppedLines = 0

    init(maxLineBytes: Int = NewlineJSONFramer.defaultMaxLineBytes) {
        self.maxLineBytes = max(1, maxLineBytes)
    }

    /// Bytes waiting for their newline.
    var pendingBytes: Int { buffer.count }

    mutating func push(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var lines: [Data] = []
        var input = data
        if discarding {
            // Throw away the rest of the oversized line, then resume.
            guard let newline = input.firstIndex(of: 0x0A) else { return [] }
            input = input[input.index(after: newline)...]
            discarding = false
            if input.isEmpty { return [] }
        }
        buffer.append(input)
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = Self.trim(buffer[start..<newline])
            if !line.isEmpty { lines.append(Data(line)) }
            start = buffer.index(after: newline)
        }
        if start > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<start)
        }
        if buffer.count > maxLineBytes {
            buffer.removeAll(keepingCapacity: false)
            discarding = true
            droppedLines += 1
        }
        return lines
    }

    /// Strips trailing CR and surrounding whitespace.
    private static func trim(_ slice: Data.SubSequence) -> Data.SubSequence {
        var lower = slice.startIndex
        var upper = slice.endIndex
        while lower < upper, Self.isSpace(slice[lower]) { lower = slice.index(after: lower) }
        while upper > lower, Self.isSpace(slice[slice.index(before: upper)]) { upper = slice.index(before: upper) }
        return slice[lower..<upper]
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }
}

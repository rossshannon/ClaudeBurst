import Foundation

// Session window calculation approach adapted from:
// https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor
// (MIT License)

/// Represents the start and end of a Claude Code usage window
public struct UsageWindow: Equatable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// A single entry parsed from a Claude Code JSONL log file
public struct JSONLUsageEntry {
    public let timestamp: Date
    public let type: String  // "user" or "assistant"
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    public init(
        timestamp: Date,
        type: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int
    ) {
        self.timestamp = timestamp
        self.type = type
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }
}

/// Parses Claude Code's JSONL log files to determine usage windows
public enum JSONLUsageParser {
    /// Claude Code uses 5-hour rolling windows for usage limits
    public static let sessionDuration: TimeInterval = 5 * 60 * 60

    /// How far back to look for activity (6 hours - optimized for 5-hour session windows)
    /// Reduced from 24h to minimize file scanning overhead while ensuring session detection
    public static let lookbackDuration: TimeInterval = 6 * 60 * 60

    /// Cached date formatters to avoid repeated allocation (performance optimization)
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parse all entries from a JSONL file's data
    /// Uses line-by-line streaming to minimize memory allocations
    public static func parseEntries(from data: Data) -> [JSONLUsageEntry] {
        guard let content = String(data: data, encoding: .utf8) else { return [] }

        var entries: [JSONLUsageEntry] = []

        // Stream processing: enumerate lines without creating intermediate array
        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }

            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }

            guard let timestampString = json["timestamp"] as? String,
                  let timestamp = dateFormatter.date(from: timestampString)
                    ?? fallbackDateFormatter.date(from: timestampString) else {
                return
            }

            let type = json["type"] as? String ?? ""

            // Extract token usage from message.usage
            var inputTokens = 0
            var outputTokens = 0
            var cacheCreationTokens = 0
            var cacheReadTokens = 0

            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                inputTokens = usage["input_tokens"] as? Int ?? 0
                outputTokens = usage["output_tokens"] as? Int ?? 0
                cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
                cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
            }

            entries.append(JSONLUsageEntry(
                timestamp: timestamp,
                type: type,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens
            ))
        }

        return entries
    }

    /// Calculate the current usage window from parsed entries
    /// Uses block-based logic: creates new 5-hour blocks when clock expires OR after gaps
    /// Returns the block that contains "now", or the most recent past block if none active
    public static func calculateCurrentWindow(entries: [JSONLUsageEntry]) -> UsageWindow? {
        guard !entries.isEmpty else { return nil }

        // Sort by timestamp chronologically
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        let now = Date()

        // Build session blocks by iterating chronologically
        // A new block starts when:
        // 1. It's the first entry
        // 2. The previous block's end time has passed (entry.timestamp >= block.end)
        // 3. There's been a gap >= 5 hours since the last entry
        var blocks: [UsageWindow] = []
        var currentBlockStart: Date? = nil
        var currentBlockEnd: Date? = nil
        var lastEntryTimestamp: Date? = nil

        for entry in sorted {
            let needsNewBlock: Bool

            if currentBlockStart == nil {
                // First entry - start a new block
                needsNewBlock = true
            } else if let blockEnd = currentBlockEnd, entry.timestamp >= blockEnd {
                // Current block's time has expired - start a new block
                needsNewBlock = true
            } else if let lastEntry = lastEntryTimestamp,
                      entry.timestamp.timeIntervalSince(lastEntry) >= sessionDuration {
                // Gap >= 5 hours since last entry - start a new block
                needsNewBlock = true
            } else {
                needsNewBlock = false
            }

            if needsNewBlock {
                // Save the previous block if it exists
                if let start = currentBlockStart, let end = currentBlockEnd {
                    blocks.append(UsageWindow(start: start, end: end))
                }

                // Start a new block - truncate to hour in UTC (matches Claude Code)
                let blockStart = truncateToHourUTC(entry.timestamp)
                currentBlockStart = blockStart
                currentBlockEnd = blockStart.addingTimeInterval(sessionDuration)
            }

            lastEntryTimestamp = entry.timestamp
        }

        // Add the final block
        if let start = currentBlockStart, let end = currentBlockEnd {
            blocks.append(UsageWindow(start: start, end: end))
        }

        guard !blocks.isEmpty else { return nil }

        // Find the active block (end > now) - prefer the most recent one
        if let activeBlock = blocks.last(where: { $0.end > now }) {
            return activeBlock
        }

        // No active block - return the most recent past block
        return blocks.last
    }

    /// Truncate a date to the start of the hour in UTC.
    /// Claude Code uses floor/truncate semantics for session windows (verified via /usage command).
    /// For example: 8:56am activity starts a session at 8:00am, not 9:00am.
    private static func truncateToHourUTC(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: components) ?? date
    }

    /// Find all JSONL files in the projects directory modified since a given date
    public static func findJSONLFiles(in directory: URL, since: Date) -> [URL] {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        var jsonlFiles: [URL] = []

        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }

                // Check modification date
                if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = values.contentModificationDate,
                   modDate >= since {
                    jsonlFiles.append(fileURL)
                }
            }
        }

        return jsonlFiles
    }

    /// Get the default projects directory URL
    public static func projectsDirectoryURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects", isDirectory: true)

        if FileManager.default.fileExists(atPath: projectsDir.path) {
            return projectsDir
        }

        return nil
    }

    /// Convenience method to load the current window from the default projects directory (synchronous)
    public static func loadCurrentWindow() -> UsageWindow? {
        guard let projectsDir = projectsDirectoryURL() else { return nil }

        let lookbackDate = Date().addingTimeInterval(-lookbackDuration)
        let jsonlFiles = findJSONLFiles(in: projectsDir, since: lookbackDate)

        var allEntries: [JSONLUsageEntry] = []

        for fileURL in jsonlFiles {
            if let data = try? Data(contentsOf: fileURL) {
                allEntries.append(contentsOf: parseEntries(from: data))
            }
        }

        return calculateCurrentWindow(entries: allEntries)
    }

    /// Async version that performs file I/O off the main thread
    public static func loadCurrentWindowAsync() async -> UsageWindow? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = loadCurrentWindow()
                continuation.resume(returning: result)
            }
        }
    }
}

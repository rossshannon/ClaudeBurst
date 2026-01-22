import XCTest
import ClaudeBurstCore

final class JSONLUsageParserTests: XCTestCase {

    // MARK: - Parse Entries Tests

    func testParseEntriesFromValidJSONL() {
        let jsonl = """
        {"timestamp": "2026-01-08T10:00:00.000Z", "type": "user", "message": {"usage": {"input_tokens": 100, "output_tokens": 0}}}
        {"timestamp": "2026-01-08T10:00:05.000Z", "type": "assistant", "message": {"usage": {"input_tokens": 100, "output_tokens": 500}}}
        """
        let data = Data(jsonl.utf8)
        let entries = JSONLUsageParser.parseEntries(from: data)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].type, "user")
        XCTAssertEqual(entries[0].inputTokens, 100)
        XCTAssertEqual(entries[0].outputTokens, 0)
        XCTAssertEqual(entries[1].type, "assistant")
        XCTAssertEqual(entries[1].outputTokens, 500)
    }

    func testParseEntriesSkipsInvalidLines() {
        let jsonl = """
        {"timestamp": "2026-01-08T10:00:00.000Z", "type": "user"}
        not-json
        {"timestamp": "invalid-date", "type": "user"}
        {"timestamp": "2026-01-08T10:00:05.000Z", "type": "assistant"}
        """
        let data = Data(jsonl.utf8)
        let entries = JSONLUsageParser.parseEntries(from: data)

        // Should only get 2 valid entries (first and last have valid timestamps)
        XCTAssertEqual(entries.count, 2)
    }

    func testParseEntriesHandlesEmptyData() {
        let data = Data()
        let entries = JSONLUsageParser.parseEntries(from: data)
        XCTAssertTrue(entries.isEmpty)
    }

    func testParseEntriesExtractsCacheTokens() {
        let jsonl = """
        {"timestamp": "2026-01-08T10:00:00.000Z", "type": "assistant", "message": {"usage": {"input_tokens": 100, "output_tokens": 50, "cache_creation_input_tokens": 5000, "cache_read_input_tokens": 200}}}
        """
        let data = Data(jsonl.utf8)
        let entries = JSONLUsageParser.parseEntries(from: data)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].cacheCreationTokens, 5000)
        XCTAssertEqual(entries[0].cacheReadTokens, 200)
        XCTAssertEqual(entries[0].totalTokens, 5350) // 100 + 50 + 5000 + 200
    }

    // MARK: - Calculate Window Tests

    func testCalculateWindowReturnsNilForEmptyEntries() {
        let window = JSONLUsageParser.calculateCurrentWindow(entries: [])
        XCTAssertNil(window)
    }

    func testCalculateWindowWithRecentActivity() {
        // Create an entry 1 hour ago
        let oneHourAgo = Date().addingTimeInterval(-1 * 60 * 60)
        let entries = [
            JSONLUsageEntry(
                timestamp: oneHourAgo,
                type: "user",
                inputTokens: 100,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0
            )
        ]

        guard let window = JSONLUsageParser.calculateCurrentWindow(entries: entries) else {
            return XCTFail("Expected calculateCurrentWindow to return a window")
        }

        // Session should be 5 hours
        let windowDuration = window.end.timeIntervalSince(window.start)
        XCTAssertEqual(windowDuration, JSONLUsageParser.sessionDuration, accuracy: 1.0)

        // Current time should be within the window
        let now = Date()
        XCTAssertTrue(now < window.end, "Current time should be before window end")
    }

    func testCalculateWindowTruncatesToHour() {
        // Create entry at 10:45
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        var components = utcCalendar.dateComponents([.year, .month, .day, .hour], from: Date())
        components.hour = 10
        components.minute = 45
        components.second = 0

        guard let timestamp = utcCalendar.date(from: components) else {
            return XCTFail("Could not create test date")
        }

        let entries = [
            JSONLUsageEntry(
                timestamp: timestamp,
                type: "user",
                inputTokens: 100,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0
            )
        ]

        guard let window = JSONLUsageParser.calculateCurrentWindow(entries: entries) else {
            return XCTFail("Expected calculateCurrentWindow to return a window")
        }

        // 10:45 should truncate to 10:00 (floor, not round) - matches Claude Code behavior
        let startComponents = utcCalendar.dateComponents([.hour, .minute], from: window.start)
        XCTAssertEqual(startComponents.hour, 10, "Session start hour should be 10 (truncated)")
        XCTAssertEqual(startComponents.minute, 0, "Session start should be truncated to the hour")
    }

    func testCalculateWindowTruncatesAtHourBoundaries() {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        // Test 10:01 -> 10:00 (should NOT be 9:00)
        var components = utcCalendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 10
        components.minute = 1
        components.second = 0

        guard let earlyTimestamp = utcCalendar.date(from: components) else {
            return XCTFail("Could not create early test date")
        }

        let earlyEntries = [
            JSONLUsageEntry(
                timestamp: earlyTimestamp,
                type: "user",
                inputTokens: 100,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0
            )
        ]

        guard let earlyWindow = JSONLUsageParser.calculateCurrentWindow(entries: earlyEntries) else {
            return XCTFail("Expected calculateCurrentWindow to return a window for early timestamp")
        }

        let earlyStartComponents = utcCalendar.dateComponents([.hour, .minute], from: earlyWindow.start)
        XCTAssertEqual(earlyStartComponents.hour, 10, "10:01 should truncate to 10:00, not 9:00")
        XCTAssertEqual(earlyStartComponents.minute, 0)

        // Test 10:59 -> 10:00 (should NOT be 11:00)
        components.minute = 59

        guard let lateTimestamp = utcCalendar.date(from: components) else {
            return XCTFail("Could not create late test date")
        }

        let lateEntries = [
            JSONLUsageEntry(
                timestamp: lateTimestamp,
                type: "user",
                inputTokens: 100,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0
            )
        ]

        guard let lateWindow = JSONLUsageParser.calculateCurrentWindow(entries: lateEntries) else {
            return XCTFail("Expected calculateCurrentWindow to return a window for late timestamp")
        }

        let lateStartComponents = utcCalendar.dateComponents([.hour, .minute], from: lateWindow.start)
        XCTAssertEqual(lateStartComponents.hour, 10, "10:59 should truncate to 10:00, not 11:00")
        XCTAssertEqual(lateStartComponents.minute, 0)
    }

    func testCalculateWindowDetectsGap() {
        // Create two entries with a 6-hour gap (more than 5-hour session duration)
        let sixHoursAgo = Date().addingTimeInterval(-6 * 60 * 60)
        let oneHourAgo = Date().addingTimeInterval(-1 * 60 * 60)

        let entries = [
            JSONLUsageEntry(
                timestamp: sixHoursAgo,
                type: "user",
                inputTokens: 100,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0
            ),
            JSONLUsageEntry(
                timestamp: oneHourAgo,
                type: "user",
                inputTokens: 100,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0
            )
        ]

        guard let window = JSONLUsageParser.calculateCurrentWindow(entries: entries) else {
            return XCTFail("Expected calculateCurrentWindow to return a window")
        }

        // The session should start from the more recent entry, not the old one
        // Since there's a 6-hour gap, the second entry starts a new session
        let now = Date()
        XCTAssertTrue(now < window.end, "Current time should be within the active window")
    }

    // MARK: - Session Duration Tests

    func testSessionDurationIsFiveHours() {
        let expectedDuration: TimeInterval = 5 * 60 * 60
        XCTAssertEqual(JSONLUsageParser.sessionDuration, expectedDuration)
    }

    func testLookbackDurationIsOptimizedForSessionWindow() {
        // Lookback should be 6 hours (slightly more than 5-hour session window)
        // This was optimized from 24h to reduce file scanning overhead
        let expectedDuration: TimeInterval = 6 * 60 * 60
        XCTAssertEqual(JSONLUsageParser.lookbackDuration, expectedDuration)
        XCTAssertGreaterThan(JSONLUsageParser.lookbackDuration, JSONLUsageParser.sessionDuration,
                            "Lookback duration should be greater than session duration to catch session boundaries")
    }

    // MARK: - Performance Optimization Tests

    func testParseEntriesHandlesLargeFiles() {
        // Test that stream-based parsing can handle many lines without memory issues
        var jsonlLines: [String] = []
        let lineCount = 10000 // Simulate a large log file

        for i in 0..<lineCount {
            let timestamp = Date().addingTimeInterval(-Double(i) * 60) // One entry per minute
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestampString = isoFormatter.string(from: timestamp)
            jsonlLines.append("{\"timestamp\": \"\(timestampString)\", \"type\": \"assistant\", \"message\": {\"usage\": {\"input_tokens\": 100, \"output_tokens\": 50}}}")
        }

        let jsonl = jsonlLines.joined(separator: "\n")
        let data = Data(jsonl.utf8)

        // Should efficiently parse all entries using enumerateLines
        let entries = JSONLUsageParser.parseEntries(from: data)

        XCTAssertEqual(entries.count, lineCount, "Should parse all \(lineCount) entries")
        XCTAssertEqual(entries[0].inputTokens, 100)
        XCTAssertEqual(entries[0].outputTokens, 50)
    }

    // MARK: - Usage Window Struct Tests

    func testUsageWindowEquality() {
        let start = Date()
        let end = start.addingTimeInterval(5 * 60 * 60)

        let window1 = UsageWindow(start: start, end: end)
        let window2 = UsageWindow(start: start, end: end)
        let window3 = UsageWindow(start: start.addingTimeInterval(1), end: end)

        XCTAssertEqual(window1, window2)
        XCTAssertNotEqual(window1, window3)
    }
}

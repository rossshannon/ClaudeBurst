import XCTest
import ClaudeBurstCore

final class UsageWindowParserTests: XCTestCase {
    func testParseDateValueWithFractionalSeconds() {
        let value = "2026-01-07T20:00:00.123Z"
        let expectedFormatter = ISO8601DateFormatter()
        expectedFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expected = expectedFormatter.date(from: value) else {
            return XCTFail("Expected date to parse for fixture")
        }

        guard let parsed = UsageWindowParser.parseDateValue(value) else {
            return XCTFail("Expected parseDateValue to return a date")
        }

        XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.0001)
    }

    func testParseDateValueWithoutFractionalSeconds() {
        let value = "2026-01-07T20:00:00Z"
        guard let expected = ISO8601DateFormatter().date(from: value) else {
            return XCTFail("Expected date to parse for fixture")
        }

        guard let parsed = UsageWindowParser.parseDateValue(value) else {
            return XCTFail("Expected parseDateValue to return a date")
        }

        XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.0001)
    }

    func testParseDateValueWithEpochSeconds() {
        let epoch: TimeInterval = 1_700_000_000
        let expected = Date(timeIntervalSince1970: epoch)

        guard let parsed = UsageWindowParser.parseDateValue(epoch) else {
            return XCTFail("Expected parseDateValue to return a date")
        }

        XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.0001)
    }

    func testParseDateValueRejectsInvalidInput() {
        XCTAssertNil(UsageWindowParser.parseDateValue("not-a-date"))
        XCTAssertNil(UsageWindowParser.parseDateValue(nil))
    }

    func testParseUsageWindowUsesFallbackStart() {
        let endValue = "2026-01-08T04:00:00Z"
        let dict: [String: Any] = ["period_end": endValue]

        guard let parsed = UsageWindowParser.parseUsageWindow(from: dict) else {
            return XCTFail("Expected parseUsageWindow to return a window")
        }

        guard let expectedEnd = ISO8601DateFormatter().date(from: endValue) else {
            return XCTFail("Expected date to parse for fixture")
        }

        XCTAssertEqual(parsed.end, expectedEnd)

        let expectedStart = expectedEnd.addingTimeInterval(-UsageWindowParser.fallbackSessionDuration)
        XCTAssertEqual(parsed.start.timeIntervalSince1970, expectedStart.timeIntervalSince1970, accuracy: 0.0001)
    }

    func testParseUsageWindowClampsStartAfterEnd() {
        let dict: [String: Any] = [
            "period_start": "2026-01-08T06:00:00Z",
            "period_end": "2026-01-08T04:00:00Z"
        ]

        guard let parsed = UsageWindowParser.parseUsageWindow(from: dict) else {
            return XCTFail("Expected parseUsageWindow to return a window")
        }

        XCTAssertEqual(parsed.start, parsed.end)
    }

    func testParseUsageWindowFromData() throws {
        let dict: [String: Any] = [
            "period_start": "2026-01-08T00:00:00Z",
            "period_end": "2026-01-08T04:00:00Z"
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])

        guard let parsed = UsageWindowParser.parseUsageWindow(from: data) else {
            return XCTFail("Expected parseUsageWindow to return a window")
        }

        let expectedStart = parsed.end.addingTimeInterval(-UsageWindowParser.fallbackSessionDuration)
        XCTAssertEqual(parsed.start.timeIntervalSince1970, expectedStart.timeIntervalSince1970, accuracy: 0.0001)
    }
}

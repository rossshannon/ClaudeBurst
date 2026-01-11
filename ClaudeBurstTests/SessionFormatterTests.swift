import XCTest
import ClaudeBurstCore

final class SessionFormatterTests: XCTestCase {

    // Use a fixed locale for deterministic test results
    let testLocale = Locale(identifier: "en_US")

    // MARK: - Helper to create dates at specific times

    private func date(hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        components.second = 0

        return calendar.date(from: components)!
    }

    // MARK: - formatTime Tests

    func testFormatTimeOnTheHour() {
        let eightAM = date(hour: 8)
        XCTAssertEqual(SessionFormatter.formatTime(eightAM, locale: testLocale), "8am")

        let onePM = date(hour: 13)
        XCTAssertEqual(SessionFormatter.formatTime(onePM, locale: testLocale), "1pm")

        let noon = date(hour: 12)
        XCTAssertEqual(SessionFormatter.formatTime(noon, locale: testLocale), "12pm")

        let midnight = date(hour: 0)
        XCTAssertEqual(SessionFormatter.formatTime(midnight, locale: testLocale), "12am")
    }

    func testFormatTimeWithMinutes() {
        let eightThirty = date(hour: 8, minute: 30)
        XCTAssertEqual(SessionFormatter.formatTime(eightThirty, locale: testLocale), "8:30am")

        let oneFortyFive = date(hour: 13, minute: 45)
        XCTAssertEqual(SessionFormatter.formatTime(oneFortyFive, locale: testLocale), "1:45pm")

        let tenOhFive = date(hour: 10, minute: 5)
        XCTAssertEqual(SessionFormatter.formatTime(tenOhFive, locale: testLocale), "10:05am")
    }

    // MARK: - formatSessionRange Tests

    func testFormatSessionRangeUsesEmDash() {
        let start = date(hour: 8)
        let end = date(hour: 13)

        let result = SessionFormatter.formatSessionRange(start: start, end: end, locale: testLocale)

        XCTAssertEqual(result, "8am–1pm")
        XCTAssertTrue(result.contains("–"), "Should use en-dash (–) not hyphen (-)")
        XCTAssertFalse(result.contains("-"), "Should not contain regular hyphen")
    }

    func testFormatSessionRangeWithMinutes() {
        let start = date(hour: 8, minute: 30)
        let end = date(hour: 13, minute: 30)

        let result = SessionFormatter.formatSessionRange(start: start, end: end, locale: testLocale)

        XCTAssertEqual(result, "8:30am–1:30pm")
    }

    // MARK: - currentSessionDescription Tests

    func testCurrentSessionDescription() {
        let start = date(hour: 8)
        let end = date(hour: 13)
        let window = UsageWindow(start: start, end: end)

        let result = SessionFormatter.currentSessionDescription(window: window, locale: testLocale)

        XCTAssertEqual(result, "Current: 8am–1pm")
    }

    // MARK: - nextSessionDescription Tests

    func testNextSessionDescriptionWhenNilWindow() {
        let result = SessionFormatter.nextSessionDescription(window: nil, locale: testLocale)

        XCTAssertEqual(result, "Next: Start a session")
    }

    func testNextSessionDescriptionWhenSessionEnded() {
        let start = date(hour: 8)
        let end = date(hour: 13)
        let window = UsageWindow(start: start, end: end)

        // "now" is after the window ended
        let now = date(hour: 14)

        let result = SessionFormatter.nextSessionDescription(window: window, now: now, locale: testLocale)

        XCTAssertEqual(result, "Next session soon")
    }

    func testNextSessionDescriptionWithMinutesRemaining() {
        let start = date(hour: 8)
        let end = date(hour: 13)
        let window = UsageWindow(start: start, end: end)

        // 13 minutes before end
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(byAdding: .minute, value: -13, to: end)!

        let result = SessionFormatter.nextSessionDescription(window: window, now: now, locale: testLocale)

        XCTAssertEqual(result, "Next session in 13m")
    }

    func testNextSessionDescriptionWithOneMinuteRemaining() {
        let start = date(hour: 8)
        let end = date(hour: 13)
        let window = UsageWindow(start: start, end: end)

        // Just under 1 minute before end (should round up to 1m)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(byAdding: .second, value: -30, to: end)!

        let result = SessionFormatter.nextSessionDescription(window: window, now: now, locale: testLocale)

        XCTAssertEqual(result, "Next session in 1m")
    }

    func testNextSessionDescriptionShowsTimeWhenMoreThanAnHour() {
        let start = date(hour: 8)
        let end = date(hour: 13)
        let window = UsageWindow(start: start, end: end)

        // 2 hours before end (more than 60 minutes)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(byAdding: .hour, value: -2, to: end)!

        let result = SessionFormatter.nextSessionDescription(window: window, now: now, locale: testLocale)

        XCTAssertEqual(result, "Next session at 1pm")
    }

    func testNextSessionDescriptionAt60Minutes() {
        let start = date(hour: 8)
        let end = date(hour: 13)
        let window = UsageWindow(start: start, end: end)

        // Exactly 60 minutes before end (boundary case - should show "in 60m")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(byAdding: .minute, value: -60, to: end)!

        let result = SessionFormatter.nextSessionDescription(window: window, now: now, locale: testLocale)

        XCTAssertEqual(result, "Next session in 60m")
    }

    func testNextSessionDescriptionAt61Minutes() {
        let start = date(hour: 8)
        let end = date(hour: 13)
        let window = UsageWindow(start: start, end: end)

        // 61 minutes before end (just over threshold - should show time)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(byAdding: .minute, value: -61, to: end)!

        let result = SessionFormatter.nextSessionDescription(window: window, now: now, locale: testLocale)

        XCTAssertEqual(result, "Next session at 1pm")
    }
}

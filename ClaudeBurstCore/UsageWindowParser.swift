import Foundation

public struct UsageWindow: Equatable {
    public let start: Date
    public let end: Date
}

public enum UsageWindowParser {
    public static let fallbackSessionDuration: TimeInterval = 4 * 60 * 60

    public static func parseUsageWindow(from data: Data) -> UsageWindow? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any] else { return nil }
        return parseUsageWindow(from: dict)
    }

    public static func parseUsageWindow(from dict: [String: Any]) -> UsageWindow? {
        guard let end = parseDateValue(dict["period_end"]) else { return nil }
        let start = parseDateValue(dict["period_start"]) ?? end.addingTimeInterval(-fallbackSessionDuration)
        let adjustedStart = min(start, end)
        return UsageWindow(start: adjustedStart, end: end)
    }

    public static func parseDateValue(_ value: Any?) -> Date? {
        if let stringValue = value as? String {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: stringValue) {
                return date
            }

            let formatter = ISO8601DateFormatter()
            return formatter.date(from: stringValue)
        }

        if let timeInterval = value as? TimeInterval {
            return Date(timeIntervalSince1970: timeInterval)
        }

        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }

        return nil
    }
}

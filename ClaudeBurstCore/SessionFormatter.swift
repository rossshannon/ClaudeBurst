import Foundation

/// Formats session times and status messages for display in the menu bar
public struct SessionFormatter {

    /// Formats a date as a time string like "8am" or "1:30pm"
    /// - Parameters:
    ///   - date: The date to format
    ///   - locale: The locale to use for formatting (defaults to current)
    /// - Returns: A lowercase time string with am/pm suffix
    public static func formatTime(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"

        let calendar = Calendar.current
        let hasMinutes = calendar.component(.minute, from: date) != 0
        formatter.dateFormat = hasMinutes ? "h:mma" : "ha"
        return formatter.string(from: date).lowercased()
    }

    /// Formats a session time range like "8am–1pm"
    /// - Parameters:
    ///   - start: The session start time
    ///   - end: The session end time
    ///   - locale: The locale to use for formatting (defaults to current)
    /// - Returns: A formatted range string with en-dash separator
    public static func formatSessionRange(start: Date, end: Date, locale: Locale = .current) -> String {
        return "\(formatTime(start, locale: locale))–\(formatTime(end, locale: locale))"
    }

    /// Describes when the next session will be available
    /// - Parameters:
    ///   - window: The current usage window, or nil if no active session
    ///   - now: The current time (injectable for testing)
    ///   - locale: The locale to use for formatting (defaults to current)
    /// - Returns: A description like "Next session in 13m" or "Next session at 2pm"
    public static func nextSessionDescription(window: UsageWindow?, now: Date = Date(), locale: Locale = .current) -> String {
        guard let window = window else {
            return "Next: Start a session"
        }

        if now < window.end {
            let minutesRemaining = Int((window.end.timeIntervalSince(now) / 60).rounded(.up))
            if minutesRemaining <= 60 {
                return "Next session in \(minutesRemaining)m"
            }
            return "Next session at \(formatTime(window.end, locale: locale))"
        }

        return "Next session soon"
    }

    /// Formats the current session info for display
    /// - Parameters:
    ///   - window: The current usage window
    ///   - locale: The locale to use for formatting (defaults to current)
    /// - Returns: A formatted string like "Current: 8am–1pm"
    public static func currentSessionDescription(window: UsageWindow, locale: Locale = .current) -> String {
        return "Current: \(formatSessionRange(start: window.start, end: window.end, locale: locale))"
    }
}

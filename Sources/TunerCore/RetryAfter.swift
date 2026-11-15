import Foundation

/// How long to leave a provider alone after it answers "too many requests" (HTTP 429).
enum RetryAfter {
    /// With no usable `Retry-After` header.
    static let defaultWait: TimeInterval = 300
    static let shortestWait: TimeInterval = 60
    static let longestWait: TimeInterval = 86_400

    /// Seconds to wait, from the header when it gives a usable time, held between a minute and a day.
    static func wait(header: String?, now: Date) -> TimeInterval {
        guard let delay = delay(from: header, now: now) else { return defaultWait }
        return min(max(delay, shortestWait), longestWait)
    }

    /// The header's wait in seconds: a whole number of seconds, or an HTTP date in the future.
    /// Nil when absent, unreadable, zero or in the past.
    static func delay(from header: String?, now: Date) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let first = text.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) || first == "-" {
            guard let seconds = Int(text), seconds > 0 else { return nil }
            return TimeInterval(seconds)
        }
        guard let date = formatter().date(from: text) else { return nil }
        let delay = date.timeIntervalSince(now)
        return delay > 0 ? delay : nil
    }

    /// A date as HTTP headers write it, for example `Sun, 15 Nov 2026 03:26:00 GMT`.
    static func httpDate(_ date: Date) -> String { formatter().string(from: date) }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }
}

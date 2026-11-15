import Foundation

/// How much of a programme's start is written, so its day cannot be mistaken: the time alone today,
/// the weekday and time on another day within the coming five, and the date and time from six days on.
/// By then a weekday names a day of next week that could be taken for this week's (a week on is today's
/// own weekday), and search reaches a week ahead.
public enum StartTimeForm: Equatable, Sendable {
    case time
    case weekdayAndTime
    case dateAndTime

    /// From this many days after today, a start is written with its date.
    public static let datedFromDays = 6

    /// Today and the first dated day, worked out once from one moment, so a whole list is measured
    /// alike and nothing per row reads the calendar. Days are calendar days in `calendar`'s time zone.
    public struct Days: Sendable {
        private let today: DateInterval?
        private let datedFrom: Date?

        public init(now: Date, calendar: Calendar = .current) {
            today = calendar.dateInterval(of: .day, for: now)
            datedFrom = today.flatMap { calendar.date(byAdding: .day, value: StartTimeForm.datedFromDays, to: $0.start) }
        }

        /// A start on an earlier day (a programme on now that began yesterday) takes the weekday.
        public func form(of start: Date) -> StartTimeForm {
            if let today, today.start <= start, start < today.end { return .time }
            if let datedFrom, start >= datedFrom { return .dateAndTime }
            return .weekdayAndTime
        }
    }
}

import Foundation
import Testing
@testable import TunerCore

/// Calendar days in a time zone with daylight saving, so a day is not always 24 hours.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Denver")!
    return calendar
}()

private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite struct StartTimeFormTests {
    /// Sunday 15 November 2026, 10:00.
    private let days = StartTimeForm.Days(now: local(2026, 11, 15, 10), calendar: calendar)

    @Test func aStartTodayIsTheTimeAlone() {
        #expect(days.form(of: local(2026, 11, 15)) == .time)
        #expect(days.form(of: local(2026, 11, 15, 9)) == .time)
        #expect(days.form(of: local(2026, 11, 15, 23, 59)) == .time)
    }

    @Test func aStartUpToFiveDaysOnIsTheWeekdayAndTime() {
        #expect(days.form(of: local(2026, 11, 16)) == .weekdayAndTime)
        #expect(days.form(of: local(2026, 11, 20, 23, 59)) == .weekdayAndTime)
    }

    /// From six days on, the weekday could be taken for this week's: a week on is today's own.
    @Test func aStartSixOrMoreDaysOnIsTheDateAndTime() {
        #expect(days.form(of: local(2026, 11, 21)) == .dateAndTime)
        #expect(days.form(of: local(2026, 11, 22, 9)) == .dateAndTime)
        #expect(days.form(of: local(2026, 11, 22, 10)) == .dateAndTime)
    }

    /// A programme on now that began yesterday.
    @Test func aStartOnAnEarlierDayIsTheWeekdayAndTime() {
        #expect(days.form(of: local(2026, 11, 14, 23)) == .weekdayAndTime)
    }

    /// The six days are counted in calendar days: across the start of daylight saving one of them is
    /// 23 hours long, and the sixth day still begins at its midnight.
    @Test func daysAreCalendarDaysAcrossAClockChange() {
        let days = StartTimeForm.Days(now: local(2026, 3, 8, 1), calendar: calendar)
        #expect(days.form(of: local(2026, 3, 8, 23)) == .time)
        #expect(days.form(of: local(2026, 3, 13, 23, 30)) == .weekdayAndTime)
        #expect(days.form(of: local(2026, 3, 14, 0, 30)) == .dateAndTime)
    }
}

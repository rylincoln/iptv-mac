import Foundation
import TunerCore

/// A programme's start in the Mac's time zone and format: "8:00 PM" today, "Sat 8:00 PM" on another
/// day, "Nov 21 at 8:00 PM" six or more days on (`StartTimeForm`). The styles are made once;
/// formatting reuses them.
enum StartTime {
    private static let time = Date.FormatStyle(date: .omitted, time: .shortened)
    private static let dayAndTime = Date.FormatStyle(date: .omitted, time: .shortened).weekday(.abbreviated)
    private static let dateAndTime = Date.FormatStyle(date: .omitted, time: .shortened).month(.abbreviated).day()

    /// `days` is worked out once by the caller, not once per row.
    static func text(_ start: Date, days: StartTimeForm.Days) -> String {
        switch days.form(of: start) {
        case .time: return start.formatted(time)
        case .weekdayAndTime: return start.formatted(dayAndTime)
        case .dateAndTime: return start.formatted(dateAndTime)
        }
    }
}

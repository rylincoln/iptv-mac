import Foundation

/// One thing to watch: a programme, and every channel it is on. Two programmes are the same event
/// when their title, start and stop all match (the same match carried by several channels).
public struct GuideEvent: Identifiable, Equatable, Sendable {
    /// The programme as its first channel lists it.
    public var programme: ProgrammeRow
    /// In playlist order; never empty.
    public var channels: [ChannelRow]

    /// Stable while the guide data is: the first channel's programme and channel.
    public var id: String { "\(programme.id)-\(channels[0].id)" }

    /// `channels` must not be empty.
    public init(programme: ProgrammeRow, channels: [ChannelRow]) {
        self.programme = programme
        self.channels = channels
    }
}

/// A run of events under one heading of the Events view.
public struct GuideSection: Identifiable, Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Today only: started, not ended.
        case onNow
        /// Today only: starts within `GuideEvents.soon`.
        case startingSoon
        /// Starts before noon, before six in the evening, or after.
        case morning, afternoon, evening
    }

    public var kind: Kind
    public var events: [GuideEvent]
    public var id: Kind { kind }
}

public enum GuideEvents {
    /// How far ahead "starting soon" reaches.
    public static let soon: TimeInterval = 3600

    /// The window to read from the store for the day that `day` falls on: from `now` if that day is
    /// today (what has ended is not listed), else the whole day.
    public static func window(for day: Date, now: Date, calendar: Calendar = .current) -> (from: Date, to: Date)? {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return nil }
        let from = interval.contains(now) ? now : interval.start
        return (from, interval.end)
    }

    /// `hits` as the Events view lists them: the same event on several channels made one, then put
    /// under headings in time order. `hits` are in start order, as `Store.guideHits` returns them,
    /// for the window `window(for:now:)` gave. On a day other than today a programme that began the
    /// day before is left out: it belongs to that day's list.
    public static func sections(
        _ hits: [ProgrammeHit], day: Date, now: Date, calendar: Calendar = .current
    ) -> [GuideSection] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        let isToday = interval.contains(now)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: interval.start) ?? interval.end
        let six = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: interval.start) ?? interval.end
        let soonEnd = now.addingTimeInterval(soon)

        var order: [GuideSection.Kind: [GuideEvent]] = [:]
        var place: [Key: (kind: GuideSection.Kind, index: Int)] = [:]
        for hit in hits {
            let programme = hit.programme
            let key = Key(title: programme.title, start: programme.start, stop: programme.stop)
            if let at = place[key] {
                order[at.kind]![at.index].channels.append(hit.channel)
                continue
            }
            let kind: GuideSection.Kind
            if isToday, programme.start <= now {
                guard programme.stop > now else { continue }
                kind = .onNow
            } else if programme.start < interval.start || programme.start >= interval.end {
                continue
            } else if isToday, programme.start < soonEnd {
                kind = .startingSoon
            } else if programme.start < noon {
                kind = .morning
            } else if programme.start < six {
                kind = .afternoon
            } else {
                kind = .evening
            }
            place[key] = (kind, order[kind, default: []].count)
            order[kind, default: []].append(GuideEvent(programme: programme, channels: [hit.channel]))
        }
        return [GuideSection.Kind.onNow, .startingSoon, .morning, .afternoon, .evening].compactMap { kind in
            order[kind].map { GuideSection(kind: kind, events: $0) }
        }
    }

    private struct Key: Hashable {
        var title: String
        var start: Date
        var stop: Date
    }
}

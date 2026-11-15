import Foundation

/// One channel's line of the guide's grid: its programmes across the hours shown.
public struct GuideGridRow: Identifiable, Equatable, Sendable {
    public var channel: ChannelRow
    /// Earliest first; never empty.
    public var programmes: [ProgrammeRow]
    public var id: Int64 { channel.id }
}

public enum GuideGrid {
    /// How much time the grid shows across, and how far a step back or on moves it.
    public static let length: TimeInterval = 3 * 3600
    public static let step: TimeInterval = 2 * 3600
    /// How far on from now it can be moved: the week the guide lists.
    public static let lastStep = 7 * 12

    /// Where the grid starts, `steps` on from now: the half hour `now` is in, so the present is
    /// near its leading edge and the times across fall on the half hours.
    public static func start(now: Date, steps: Int = 0) -> Date {
        let half: TimeInterval = 1800
        let seconds = (now.timeIntervalSince1970 / half).rounded(.down) * half
        return Date(timeIntervalSince1970: seconds + Double(steps) * step)
    }

    /// `hits` channel by channel. They come in each channel's turn, earliest first, as
    /// `Store.guideHits(byChannel: true)` returns them.
    public static func rows(_ hits: [ProgrammeHit]) -> [GuideGridRow] {
        var rows: [GuideGridRow] = []
        for hit in hits {
            if let last = rows.indices.last, rows[last].channel.id == hit.channel.id {
                rows[last].programmes.append(hit.programme)
            } else {
                rows.append(GuideGridRow(channel: hit.channel, programmes: [hit.programme]))
            }
        }
        return rows
    }

    /// Where a programme lies across the grid, as fractions of its width from 0 to 1, cut off at
    /// the edges; nil if none of it falls within.
    public static func span(start: Date, stop: Date, gridStart: Date) -> (from: Double, to: Double)? {
        let from = max(start.timeIntervalSince(gridStart) / length, 0)
        let to = min(stop.timeIntervalSince(gridStart) / length, 1)
        return to > from ? (from, to) : nil
    }
}

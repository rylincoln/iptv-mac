import Foundation
import GRDB

/// Which channels' programmes the guide lists.
public enum GuideFilter: String, CaseIterable, Sendable {
    /// Sport programmes on any channel, and everything on a channel in a sports group.
    case sports
    case favourites
    case all
}

extension Store {
    /// The most programme rows one guide read returns.
    public static let guideRowLimit = 20_000

    /// Programmes still to end at `from` and starting before `to`, on the channels `filter` names,
    /// each with a channel it is on: one hit per channel, so a programme on a guide channel that
    /// three playlist channels share comes three times. Earliest first, then in playlist order; or,
    /// `byChannel`, each channel's in turn, in playlist order, earliest first (for the grid).
    /// Descriptions are left out (`desc` is nil); the list does not show them, and a day of every
    /// channel's would be megabytes (see `programme(id:)`).
    public func guideHits(
        _ filter: GuideFilter, from: Date, to: Date, byChannel: Bool = false, limit: Int = Store.guideRowLimit
    ) throws -> [ProgrammeHit] {
        let condition: String
        switch filter {
        case .sports: condition = "AND (p.isSport = 1 OR c.isSportsGroup = 1)"
        case .favourites: condition = "AND EXISTS (SELECT 1 FROM favourite f WHERE f.streamURL = c.streamURL)"
        case .all: condition = ""
        }
        let order = byChannel ? "c.sortIndex, c.id, p.start, p.id" : "p.start, c.sortIndex, c.id, p.id"
        return try db.read { db in
            var result: [ProgrammeHit] = []
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT p.id, p.guideRef, p.start, p.stop, p.title, p.subTitle, NULL, p.isSport,
                    \(Self.channelColumns)
                FROM programme p JOIN channel c ON c.guideRef = p.guideRef
                WHERE p.stop > ? AND p.start < ? \(condition)
                ORDER BY \(order) LIMIT ?
                """, arguments: [Self.unixSeconds(from), Self.unixSeconds(to), limit])
            while let row = try cursor.next() {
                result.append(ProgrammeHit(
                    programme: Self.programmeRow(row), channel: Self.channelRow(row, from: Self.programmeColumnCount)))
            }
            return result
        }
    }

    /// One programme in full, its description included; nil if it is gone (a guide import since).
    public func programme(id: Int64) throws -> ProgrammeRow? {
        try db.read { db in
            try Row.fetchOne(
                db, sql: "SELECT \(Self.programmeColumns) FROM programme p WHERE p.id = ?", arguments: [id]
            ).map(Self.programmeRow)
        }
    }
}

import Foundation
import GRDB

enum FTSQuery {
    /// Splits on every run of non-letter, non-digit characters (the way the `unicode61` tokenizer
    /// does, so "A&M" becomes the tokens "a" and "m"), and emits each piece as a quoted prefix
    /// term. Nil means there is nothing usable to search for.
    static func make(from text: String) -> String? {
        var pieces: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        guard !pieces.isEmpty else { return nil }
        return pieces.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}

extension Store {
    private static let searchHorizon: TimeInterval = 7 * 24 * 3600

    /// A programme, then the channel it was found on.
    private static let hitColumns = "\(programmeColumns), \(channelColumns)"

    /// Programmes (airing now, and starting within 7 days) and channels matching every typed term
    /// as a prefix. Each list holds at most `limit` entries; the limit is applied in SQL.
    public func search(_ text: String, at: Date, limit: Int = 50) throws -> SearchResults {
        guard limit > 0, let match = FTSQuery.make(from: text) else { return .empty }
        let seconds = Self.unixSeconds(at)
        let horizon = seconds + Int64(Self.searchHorizon)
        return try db.read { db in
            let onNow = try Self.hits(db, sql: """
                SELECT \(Self.hitColumns) FROM programme p
                JOIN channel c ON c.guideRef = p.guideRef
                WHERE p.start <= ? AND p.stop > ?
                  AND p.id IN (SELECT rowid FROM programme_fts WHERE programme_fts MATCH ?)
                ORDER BY c.sortIndex, c.id, p.start, p.id LIMIT ?
                """, arguments: [seconds, seconds, match, limit])
            let later = try Self.hits(db, sql: """
                SELECT \(Self.hitColumns) FROM programme p
                JOIN channel c ON c.guideRef = p.guideRef
                WHERE p.start > ? AND p.start <= ?
                  AND p.id IN (SELECT rowid FROM programme_fts WHERE programme_fts MATCH ?)
                ORDER BY p.start, c.sortIndex, c.id, p.id LIMIT ?
                """, arguments: [seconds, horizon, match, limit])
            var channels: [ChannelRow] = []
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT \(Self.channelColumns) FROM channel c
                WHERE c.id IN (SELECT rowid FROM channel_fts WHERE channel_fts MATCH ?)
                ORDER BY c.sortIndex, c.id LIMIT ?
                """, arguments: [match, limit])
            while let row = try cursor.next() {
                channels.append(Self.channelRow(row, from: 0))
            }
            return SearchResults(onNow: onNow, later: later, channels: channels)
        }
    }

    private static func hits(
        _ db: Database, sql: String, arguments: StatementArguments
    ) throws -> [ProgrammeHit] {
        var result: [ProgrammeHit] = []
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try cursor.next() {
            result.append(ProgrammeHit(
                programme: programmeRow(row), channel: channelRow(row, from: programmeColumnCount)))
        }
        return result
    }
}

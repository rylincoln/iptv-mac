import Foundation
import GRDB

extension Store {
    /// Recents shown in the section, and rows kept in the table.
    static let recentsShown = 30
    static let recentsKept = 100

    // MARK: Sources

    /// Returns the existing id when the location is already present.
    public func addSource(kind: SourceKind, location: String) throws -> Int64 {
        try db.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO source(kind, location) VALUES (?, ?)",
                arguments: [kind.rawValue, location])
            guard let id = try Int64.fetchOne(
                db, sql: "SELECT id FROM source WHERE location = ?", arguments: [location])
            else { throw DatabaseError(message: "source row missing after insert") }
            return id
        }
    }

    /// Every source this version knows how to import. A row of a kind it does not know (written by a
    /// later version, say) is left out rather than failing the whole list: it could not be imported or
    /// shown anyway, and the other sources stay usable.
    public func sources() throws -> [SourceRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, kind, location, etag, lastRefreshAt, lastError, itemCount, skippedCount, retryAt
                FROM source ORDER BY id
                """).compactMap { row in
                guard let kind = SourceKind(rawValue: row["kind"]) else { return nil }
                let refreshed: Int64? = row["lastRefreshAt"]
                let retryAt: Int64? = row["retryAt"]
                return SourceRow(
                    id: row["id"], kind: kind, location: row["location"], etag: row["etag"],
                    lastRefreshAt: refreshed.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    lastError: row["lastError"], itemCount: row["itemCount"],
                    skippedCount: row["skippedCount"],
                    retryAt: retryAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
            }
        }
    }

    /// `retryAt`: the time before which the provider must not be asked again, or nil for none.
    /// An id with no source row changes nothing and is not an error: the importer reads the row just
    /// before, so the source can only be missing if it was removed meanwhile, and then there is nothing
    /// left to record against.
    public func recordRefresh(
        sourceID: Int64, etag: String?, itemCount: Int, skippedCount: Int, error: String?, at: Date,
        retryAt: Date? = nil
    ) throws {
        try db.write { db in
            try db.execute(sql: """
                UPDATE source SET etag = ?, itemCount = ?, skippedCount = ?, lastError = ?,
                    lastRefreshAt = ?, retryAt = ? WHERE id = ?
                """, arguments: [
                    etag, itemCount, skippedCount, error, Self.unixSeconds(at),
                    retryAt.map { Self.unixSeconds($0, rounding: .up) }, sourceID,
                ])
        }
    }

    // MARK: Channels

    /// Replaces one source's channels in a single transaction, then repoints favourites and
    /// recents whose URL vanished but whose name matches exactly one channel.
    public func replaceChannels(sourceID: Int64, with channels: [ParsedChannel]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM channel WHERE sourceID = ?", arguments: [sourceID])
            let insert = try db.makeStatement(sql: """
                INSERT INTO channel(sourceID, name, tvgID, tvgName, logoURL, groupTitle, streamURL,
                    sortIndex, isSportsGroup)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for (index, channel) in channels.enumerated() {
                try insert.execute(arguments: [
                    sourceID, channel.name, channel.tvgID, channel.tvgName, channel.logoURL,
                    channel.groupTitle, channel.streamURL, index,
                    SportsClassifier.isSportsGroup(channel.groupTitle),
                ])
            }
            try db.execute(sql: "INSERT INTO channel_fts(channel_fts) VALUES ('rebuild')")
            for table in ["favourite", "recent"] {
                try db.execute(sql: """
                    UPDATE OR IGNORE \(table) SET streamURL = (
                        SELECT MIN(c.streamURL) FROM channel c WHERE c.name = \(table).name)
                    WHERE NOT EXISTS (SELECT 1 FROM channel c WHERE c.streamURL = \(table).streamURL)
                      AND (SELECT COUNT(*) FROM channel c WHERE c.name = \(table).name) = 1
                    """)
            }
            try Self.rematch(db)
        }
    }

    /// What a `ChannelRow` is read from, in `channelRow(_:from:)`'s order, in a query that names the
    /// channel `c`. Shared by every query that returns channels, so their columns cannot drift apart.
    static let channelColumns = """
        c.id, c.name, c.logoURL, c.groupTitle, c.streamURL, c.guideRef,
        EXISTS (SELECT 1 FROM favourite f WHERE f.streamURL = c.streamURL)
        """

    /// Reads `channelColumns` from column `first` on.
    static func channelRow(_ row: Row, from first: Int) -> ChannelRow {
        ChannelRow(
            id: row[first], name: row[first + 1], logoURL: row[first + 2], groupTitle: row[first + 3],
            streamURL: row[first + 4], guideRef: row[first + 5], isFavourite: row[first + 6])
    }

    public func channels(in section: Section, at date: Date) throws -> [ChannelRow] {
        let columns = Self.channelColumns
        let sql: String
        var arguments: StatementArguments = []
        switch section {
        case .all:
            sql = "SELECT \(columns) FROM channel c ORDER BY c.sortIndex, c.id"
        case .group(let title):
            sql = "SELECT \(columns) FROM channel c WHERE c.groupTitle = ? ORDER BY c.sortIndex, c.id"
            arguments = [title]
        case .sports:
            let seconds = Self.unixSeconds(date)
            sql = """
                SELECT \(columns) FROM channel c
                WHERE c.isSportsGroup = 1 OR (c.guideRef IS NOT NULL AND EXISTS (
                    SELECT 1 FROM programme p WHERE p.guideRef = c.guideRef AND p.isSport = 1
                        AND p.start <= ? AND p.stop > ?))
                ORDER BY c.sortIndex, c.id
                """
            arguments = [seconds, seconds]
        case .favourites:
            sql = """
                SELECT \(columns) FROM favourite r
                JOIN channel c ON c.id = (SELECT MIN(id) FROM channel WHERE streamURL = r.streamURL)
                ORDER BY c.name COLLATE NOCASE, c.id
                """
        case .recents:
            sql = """
                SELECT \(columns) FROM recent r
                JOIN channel c ON c.id = (SELECT MIN(id) FROM channel WHERE streamURL = r.streamURL)
                ORDER BY r.lastWatchedAt DESC, c.id LIMIT \(Self.recentsShown)
                """
        }
        return try db.read { db in
            var rows: [ChannelRow] = []
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let row = try cursor.next() {
                rows.append(Self.channelRow(row, from: 0))
            }
            return rows
        }
    }

    /// Distinct group titles, sorted.
    public func groups() throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT groupTitle FROM channel WHERE groupTitle IS NOT NULL
                ORDER BY groupTitle COLLATE NOCASE, groupTitle
                """)
        }
    }

    // MARK: Favourites and recents

    // Both are keyed by the channel's stream URL and name, never by its row id: ids are reassigned on
    // every playlist import, so a row read before an import would name another channel, or none.

    public func setFavourite(_ on: Bool, streamURL: String, name: String) throws {
        try db.write { db in
            if on {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO favourite(streamURL, name, addedAt) VALUES (?, ?, ?)
                    """, arguments: [streamURL, name, Self.unixSeconds(Date())])
            } else {
                try db.execute(sql: "DELETE FROM favourite WHERE streamURL = ?", arguments: [streamURL])
            }
        }
    }

    /// Whether the stream is a favourite, as stored.
    public func isFavourite(streamURL: String) throws -> Bool {
        try db.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM favourite WHERE streamURL = ?)", arguments: [streamURL])
                ?? false
        }
    }

    public func recordWatched(streamURL: String, name: String, at: Date) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO recent(streamURL, name, lastWatchedAt) VALUES (?, ?, ?)
                ON CONFLICT(streamURL) DO UPDATE SET name = excluded.name,
                    lastWatchedAt = excluded.lastWatchedAt
                """, arguments: [streamURL, name, Self.unixSeconds(at)])
            try db.execute(sql: """
                DELETE FROM recent WHERE streamURL NOT IN (
                    SELECT streamURL FROM recent ORDER BY lastWatchedAt DESC LIMIT \(Self.recentsKept))
                """)
        }
    }
}

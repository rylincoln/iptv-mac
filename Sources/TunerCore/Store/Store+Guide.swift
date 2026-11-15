import Foundation
import GRDB

public protocol GuideWriter {
    func add(_ c: ParsedGuideChannel) throws
    func add(_ p: ParsedProgramme) throws
}

/// Inserts rows as they arrive through reused prepared statements; only the channel id to ref
/// map (one entry per guide channel) is kept in memory.
private final class StatementGuideWriter: GuideWriter {
    private let insertChannel: Statement
    private let insertProgramme: Statement
    private let db: Database
    private let sourceID: Int64
    private let cutoff: Int64
    private var refs: [String: Int64] = [:]

    init(db: Database, sourceID: Int64, cutoff: Int64) throws {
        self.db = db
        self.sourceID = sourceID
        self.cutoff = cutoff
        insertChannel = try db.makeStatement(sql: """
            INSERT INTO guideChannel(sourceID, id, displayNames, iconURL) VALUES (?, ?, ?, ?)
            """)
        insertProgramme = try db.makeStatement(sql: """
            INSERT INTO programme(guideRef, start, stop, title, subTitle, desc, isSport)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
    }

    func add(_ c: ParsedGuideChannel) throws {
        guard refs[c.id] == nil else { return }
        try insertChannel.execute(arguments: [
            sourceID, c.id, c.displayNames.joined(separator: "\u{1F}"), c.iconURL,
        ])
        refs[c.id] = db.lastInsertedRowID
    }

    func add(_ p: ParsedProgramme) throws {
        guard let ref = refs[p.channelID] else { return }
        let stop = Int64(p.stop.timeIntervalSince1970)
        // Already past the retention window: never stored, same result as pruning afterwards.
        guard stop >= cutoff else { return }
        try insertProgramme.execute(arguments: [
            ref, Int64(p.start.timeIntervalSince1970), stop, p.title, p.subTitle, p.desc,
            SportsClassifier.isSportsCategory(p.categories),
        ])
    }
}

extension Store {
    /// One transaction: delete this source's guide data, run `load`, drop programmes that ended more than
    /// 24 hours before `now`, rebuild the programme search index, re-run matching for every channel.
    /// If `load` throws, nothing changes.
    public func replaceGuide(sourceID: Int64, now: Date, load: (GuideWriter) throws -> Void) throws {
        let cutoff = Int64(now.timeIntervalSince1970) - 24 * 3600
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM programme WHERE guideRef IN (
                    SELECT ref FROM guideChannel WHERE sourceID = ?)
                """, arguments: [sourceID])
            try db.execute(sql: "DELETE FROM guideChannel WHERE sourceID = ?", arguments: [sourceID])
            try load(StatementGuideWriter(db: db, sourceID: sourceID, cutoff: cutoff))
            try db.execute(sql: "INSERT INTO programme_fts(programme_fts) VALUES ('rebuild')")
            try Self.rematch(db)
        }
    }

    /// Links every channel to a guide channel (or clears the link) from the current tables.
    public func rematch() throws {
        try db.write { db in try Self.rematch(db) }
    }

    static func rematch(_ db: Database) throws {
        var candidates: [MatchCandidate] = []
        let guideCursor = try Row.fetchCursor(db, sql: """
            SELECT g.ref, g.id, g.displayNames,
                EXISTS (SELECT 1 FROM programme p WHERE p.guideRef = g.ref)
            FROM guideChannel g ORDER BY g.ref
            """)
        while let row = try guideCursor.next() {
            let names: String = row[2]
            candidates.append(MatchCandidate(
                ref: row[0], id: row[1],
                displayNames: names.isEmpty ? [] : names.components(separatedBy: "\u{1F}"),
                hasProgrammes: row[3]))
        }

        var queries: [MatchQuery] = []
        var current: [Int64: (ref: Int64?, kind: String?)] = [:]
        let channelCursor = try Row.fetchCursor(
            db, sql: "SELECT id, tvgID, name, tvgName, guideRef, matchKind FROM channel")
        while let row = try channelCursor.next() {
            let id: Int64 = row[0]
            queries.append(MatchQuery(channelID: id, tvgID: row[1], name: row[2], tvgName: row[3]))
            current[id] = (row[4], row[5])
        }

        let matches = Matcher.match(queries, against: candidates)
        let update = try db.makeStatement(
            sql: "UPDATE channel SET guideRef = ?, matchKind = ? WHERE id = ?")
        for query in queries {
            let match = matches[query.channelID]
            let old = current[query.channelID]
            if old?.ref == match?.guideRef && old?.kind == match?.kind.rawValue { continue }
            try update.execute(arguments: [match?.guideRef, match?.kind.rawValue, query.channelID])
        }
    }

    /// The programme airing at `at` (start <= at < stop) per guide channel.
    public func nowPlaying(at: Date) throws -> [Int64: ProgrammeRow] {
        let seconds = Int64(at.timeIntervalSince1970)
        return try db.read { db in
            var result: [Int64: ProgrammeRow] = [:]
            // Ascending start, so on overlap the latest-starting programme wins.
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT id, guideRef, start, stop, title, subTitle, desc, isSport FROM programme
                WHERE start <= ? AND stop > ? ORDER BY start
                """, arguments: [seconds, seconds])
            while let row = try cursor.next() {
                let programme = Self.programme(row)
                result[programme.guideRef] = programme
            }
            return result
        }
    }

    public func upcoming(guideRef: Int64, after: Date, limit: Int) throws -> [ProgrammeRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, guideRef, start, stop, title, subTitle, desc, isSport FROM programme
                WHERE guideRef = ? AND start >= ? ORDER BY start, id LIMIT ?
                """, arguments: [guideRef, Int64(after.timeIntervalSince1970), limit]
            ).map(Self.programme)
        }
    }

    private static func programme(_ row: Row) -> ProgrammeRow {
        let start: Int64 = row[2]
        let stop: Int64 = row[3]
        return ProgrammeRow(
            id: row[0], guideRef: row[1],
            start: Date(timeIntervalSince1970: TimeInterval(start)),
            stop: Date(timeIntervalSince1970: TimeInterval(stop)),
            title: row[4], subTitle: row[5], desc: row[6], isSport: row[7])
    }
}

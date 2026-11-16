import Foundation
import GRDB

enum FTSQuery {
    /// Splits on every run of non-letter, non-digit characters (the way the `unicode61` tokenizer
    /// does, so "A&M" becomes the tokens "a" and "m"), and emits each piece as a quoted prefix
    /// term. Nil means there is nothing usable to search for.
    static func make(from text: String) -> String? {
        let terms = ChannelName.words(in: text)
        return terms.isEmpty ? nil : prefixes(terms)
    }

    /// Every term at the start of a word.
    static func prefixes(_ terms: [String]) -> String {
        terms.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Every term a whole word: "nbc" finds "NBC 4" and not "NBCSN".
    static func wholeWords(_ terms: [String]) -> String {
        terms.map { "\"\($0)\"" }.joined(separator: " ")
    }

    /// `query` looked for in the columns named only.
    static func within(_ columns: String, _ query: String) -> String { "{\(columns)} : (\(query))" }
}

extension Store {
    private static let searchHorizon: TimeInterval = 7 * 24 * 3600

    /// A programme, then the channel it was found on.
    private static let hitColumns = "\(programmeColumns), \(channelColumns)"

    /// Channels, and programmes (airing now, and starting within 7 days), matching every typed
    /// term. Each list holds at most `limit` entries; the limit is applied in SQL, after ordering,
    /// so what is cut off is what matches least well.
    ///
    /// A programme matches a term at the start of a word of its title, sub-title or description.
    /// Those found in the title or sub-title come first: a description mentions many things the
    /// programme is not. Then on now in playlist order, and later ones earliest first.
    ///
    /// A channel matches a term at the start of a word of its name, of the names its guide channel
    /// goes by, of the playlist's second name or of its group, with letters divided from digits
    /// ("espn 2" finds "ESPN2"); or anywhere inside its name ("nbc" finds "CNBC"). In order:
    /// - a channel played before from the results for this text, or for text beginning with it,
    ///   the latest first;
    /// - how well it matches: every term a whole word of the name; at the start of a word of the
    ///   name; found with the help of its other names; with the help of its group; inside a word;
    /// - favourites, then channels watched before;
    /// - the shorter name, leaving out a region in front and picture quality behind
    ///   (`ChannelName.coreLength`); then playlist order.
    ///
    /// When no channel matches, each term that begins no word of any channel is mended to the
    /// nearest word that exists (`Typo`), and the channels found for that are given instead, with
    /// `channelsFoundFor` saying what they were found for.
    public func search(_ text: String, at: Date, limit: Int = 50) throws -> SearchResults {
        let terms = ChannelName.words(in: text)
        guard limit > 0, !terms.isEmpty else { return .empty }
        let match = FTSQuery.prefixes(terms)
        let titles = FTSQuery.within("title subTitle", match)
        let seconds = Self.unixSeconds(at)
        let horizon = seconds + Int64(Self.searchHorizon)
        return try db.read { db in
            let onNow = try Self.hits(db, sql: """
                SELECT \(Self.hitColumns) FROM programme p
                JOIN channel c ON c.guideRef = p.guideRef
                WHERE p.start <= ? AND p.stop > ?
                  AND p.id IN (SELECT rowid FROM programme_fts WHERE programme_fts MATCH ?)
                ORDER BY p.id IN (SELECT rowid FROM programme_fts WHERE programme_fts MATCH ?) DESC,
                    c.sortIndex, c.id, p.start, p.id LIMIT ?
                """, arguments: [seconds, seconds, match, titles, limit])
            let later = try Self.hits(db, sql: """
                SELECT \(Self.hitColumns) FROM programme p
                JOIN channel c ON c.guideRef = p.guideRef
                WHERE p.start > ? AND p.start <= ?
                  AND p.id IN (SELECT rowid FROM programme_fts WHERE programme_fts MATCH ?)
                ORDER BY p.id IN (SELECT rowid FROM programme_fts WHERE programme_fts MATCH ?) DESC,
                    p.start, c.sortIndex, c.id, p.id LIMIT ?
                """, arguments: [seconds, horizon, match, titles, limit])
            let picked = Self.pickKey(terms)
            var channels = try Self.channels(db, terms: terms, picked: picked, limit: limit)
            var foundFor: String?
            if channels.isEmpty {
                let vocabulary = try Row.fetchAll(db, sql: "SELECT term, doc FROM channel_words").map {
                    (word: $0[0] as String, count: $0[1] as Int)
                }
                if let mended = Typo.mended(terms.flatMap(ChannelName.parts), vocabulary: vocabulary) {
                    channels = try Self.channels(db, terms: mended, picked: picked, limit: limit)
                    if !channels.isEmpty { foundFor = mended.joined(separator: " ") }
                }
            }
            return SearchResults(onNow: onNow, later: later, channels: channels, channelsFoundFor: foundFor)
        }
    }

    private static func channels(_ db: Database, terms: [String], picked: String, limit: Int) throws -> [ChannelRow] {
        let anywhere = FTSQuery.prefixes(terms.flatMap(ChannelName.parts))
        let whole = FTSQuery.within("name divided", FTSQuery.wholeWords(terms.flatMap(ChannelName.parts)))
        let names = FTSQuery.within("name divided", anywhere)
        let known = FTSQuery.within("name divided otherNames", anywhere)
        // A term is letters and digits only, so it holds none of LIKE's own characters.
        let inside = terms.map { _ in "c.name LIKE ?" }.joined(separator: " AND ")
        let found = "c.id IN (SELECT rowid FROM channel_search WHERE channel_search MATCH ?)"
        var arguments = StatementArguments([anywhere] + terms.map { "%\($0)%" })
        arguments += [picked + "%", whole, names, known, anywhere, limit]
        var channels: [ChannelRow] = []
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT \(Self.channelColumns) FROM channel c
            WHERE \(found) OR (\(inside))
            ORDER BY
                (SELECT MAX(k.pickedAt) FROM searchPick k
                    WHERE k.streamURL = c.streamURL AND k.query LIKE ?) DESC,
                CASE WHEN \(found) THEN 0 WHEN \(found) THEN 1 WHEN \(found) THEN 2 WHEN \(found) THEN 3
                     ELSE 4 END,
                EXISTS (SELECT 1 FROM favourite f WHERE f.streamURL = c.streamURL) DESC,
                EXISTS (SELECT 1 FROM recent r WHERE r.streamURL = c.streamURL) DESC,
                c.coreLength, c.sortIndex, c.id
            LIMIT ?
            """, arguments: arguments)
        while let row = try cursor.next() {
            channels.append(Self.channelRow(row, from: 0))
        }
        return channels
    }

    // MARK: Picks

    func searchPickCount() throws -> Int {
        try db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM searchPick") ?? 0 }
    }

    static let searchPicksKept = 500

    /// What is typed, as picks are kept under it: its words, lowercase, a space between.
    static func pickKey(_ terms: [String]) -> String {
        terms.map { $0.lowercased() }.joined(separator: " ")
    }

    /// A channel was played from the results for `text`. The next search for that text, or for the
    /// start of it, lists the channel first. Only the newest `searchPicksKept` are kept.
    public func recordSearchPick(_ text: String, streamURL: String, at: Date) throws {
        let terms = ChannelName.words(in: text)
        guard !terms.isEmpty else { return }
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO searchPick(query, streamURL, pickedAt) VALUES (?, ?, ?)
                ON CONFLICT(query, streamURL) DO UPDATE SET pickedAt = excluded.pickedAt
                """, arguments: [Self.pickKey(terms), streamURL, Self.unixSeconds(at)])
            try db.execute(sql: """
                DELETE FROM searchPick WHERE pickedAt < (
                    SELECT pickedAt FROM searchPick ORDER BY pickedAt DESC LIMIT 1 OFFSET \(Self.searchPicksKept - 1))
                """)
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

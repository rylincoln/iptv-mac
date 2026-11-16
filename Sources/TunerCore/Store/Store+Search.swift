import Foundation
import GRDB

enum FTSQuery {
    /// Splits on every run of non-letter, non-digit characters (the way the `unicode61` tokenizer
    /// does, so "A&M" becomes the tokens "a" and "m"), and emits each piece as a quoted prefix
    /// term. Nil means there is nothing usable to search for.
    static func make(from text: String) -> String? {
        let pieces = terms(in: text)
        guard !pieces.isEmpty else { return nil }
        return pieces.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// The same terms as whole words: "nbc" finds "NBC 4" and not "NBCSN".
    static func wholeWords(_ terms: [String]) -> String {
        terms.map { "\"\($0)\"" }.joined(separator: " ")
    }

    /// `query` (from `make`) looked for in a programme's title and sub-title only.
    static func inTitles(_ query: String) -> String { "{title subTitle} : (\(query))" }

    /// A LIKE pattern finding `term` anywhere. A term is letters and digits only (`terms`), so it
    /// holds none of LIKE's own characters.
    static func anywhere(_ term: String) -> String { "%\(term)%" }

    /// The runs of letters and digits in `text`.
    static func terms(in text: String) -> [String] {
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
        return pieces
    }
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
    /// A channel matches a term anywhere in its name, so "nbc" finds "WNBC" and "CNBC" too. They
    /// are ordered by how well: every term a whole word of the name, then at the start of a word,
    /// then inside one. Within each, favourites first, then channels watched before, then the
    /// shorter name (the fewer other words in it, the nearer it is to what was typed), then
    /// playlist order.
    public func search(_ text: String, at: Date, limit: Int = 50) throws -> SearchResults {
        let terms = FTSQuery.terms(in: text)
        guard limit > 0, let match = FTSQuery.make(from: text) else { return .empty }
        let titles = FTSQuery.inTitles(match)
        let words = FTSQuery.wholeWords(terms)
        let named = terms.map { _ in "c.name LIKE ?" }.joined(separator: " AND ")
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
            var channels: [ChannelRow] = []
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT \(Self.channelColumns) FROM channel c
                WHERE c.id IN (SELECT rowid FROM channel_fts WHERE channel_fts MATCH ?) OR (\(named))
                ORDER BY
                    CASE WHEN c.id IN (SELECT rowid FROM channel_fts WHERE channel_fts MATCH ?) THEN 0
                         WHEN c.id IN (SELECT rowid FROM channel_fts WHERE channel_fts MATCH ?) THEN 1
                         ELSE 2 END,
                    EXISTS (SELECT 1 FROM favourite f WHERE f.streamURL = c.streamURL) DESC,
                    EXISTS (SELECT 1 FROM recent r WHERE r.streamURL = c.streamURL) DESC,
                    length(c.name), c.sortIndex, c.id
                LIMIT ?
                """, arguments: StatementArguments([match] + terms.map(FTSQuery.anywhere) + [words, match])
                    + [limit])
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

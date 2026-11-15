import Foundation
import GRDB

/// SQLite-backed store for sources, channels, favourites, recents and per-stream playback memory.
public final class Store: Sendable {
    let db: any DatabaseWriter

    /// Opens (creating the file and its parent folder if needed) and migrates the database.
    public init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        // A bulk import is one big transaction. By default SQLite keeps its dirty pages in memory
        // until about 20,000 of them (80 MB) pile up; spill to the journal early so an import's
        // memory stays flat however large the guide is.
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA cache_spill = 1000") }
        db = try DatabasePool(path: path, configuration: configuration)   // WAL journal mode
        try Self.migrator.migrate(db)
    }

    private init(queue: DatabaseQueue) throws {
        db = queue
        try Self.migrator.migrate(db)
    }

    public static func inMemory() throws -> Store {
        try Store(queue: DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE source (
                    id INTEGER PRIMARY KEY,
                    kind TEXT NOT NULL,
                    location TEXT NOT NULL UNIQUE,
                    etag TEXT,
                    lastRefreshAt INTEGER,
                    lastError TEXT,
                    itemCount INTEGER NOT NULL DEFAULT 0,
                    skippedCount INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE channel (
                    id INTEGER PRIMARY KEY,
                    sourceID INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    tvgID TEXT,
                    tvgName TEXT,
                    logoURL TEXT,
                    groupTitle TEXT,
                    streamURL TEXT NOT NULL,
                    sortIndex INTEGER NOT NULL,
                    isSportsGroup INTEGER NOT NULL DEFAULT 0,
                    guideRef INTEGER,
                    matchKind TEXT
                );
                CREATE INDEX channel_sourceID ON channel(sourceID);
                CREATE INDEX channel_streamURL ON channel(streamURL);
                CREATE INDEX channel_name ON channel(name);
                CREATE INDEX channel_sort ON channel(sortIndex, id);
                CREATE INDEX channel_group ON channel(groupTitle, sortIndex, id);
                CREATE INDEX channel_sports ON channel(isSportsGroup, sortIndex, id);
                CREATE TABLE favourite (
                    streamURL TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    addedAt INTEGER NOT NULL
                );
                CREATE INDEX favourite_name ON favourite(name);
                CREATE TABLE recent (
                    streamURL TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    lastWatchedAt INTEGER NOT NULL
                );
                CREATE INDEX recent_name ON recent(name);
                CREATE INDEX recent_last ON recent(lastWatchedAt);
                CREATE TABLE channelPlayback (
                    streamURL TEXT PRIMARY KEY,
                    bufferMs INTEGER NOT NULL
                );
                CREATE VIRTUAL TABLE channel_fts USING fts5(name, content='channel', content_rowid='id');
                """)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE guideChannel (
                    ref INTEGER PRIMARY KEY,
                    sourceID INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    displayNames TEXT NOT NULL,
                    iconURL TEXT
                );
                CREATE INDEX guideChannel_source ON guideChannel(sourceID);
                CREATE TABLE programme (
                    id INTEGER PRIMARY KEY,
                    guideRef INTEGER NOT NULL REFERENCES guideChannel(ref) ON DELETE CASCADE,
                    start INTEGER NOT NULL,
                    stop INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    subTitle TEXT,
                    desc TEXT,
                    isSport INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX programme_channel ON programme(guideRef, start);
                CREATE INDEX programme_time ON programme(start, stop);
                CREATE VIRTUAL TABLE programme_fts USING fts5(
                    title, subTitle, desc, content='programme', content_rowid='id', prefix='1');
                """)
        }
        return migrator
    }

    // MARK: Playback memory

    /// Remembered buffer for a stream, or nil when none is stored or the read fails.
    public func bufferMs(forStreamURL streamURL: String) -> Int? {
        try? db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT bufferMs FROM channelPlayback WHERE streamURL = ?",
                arguments: [streamURL])
        }
    }

    /// Remembers a buffer for a stream. Database errors are swallowed.
    public func setBufferMs(_ ms: Int, forStreamURL streamURL: String) {
        try? db.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO channelPlayback(streamURL, bufferMs) VALUES (?, ?)",
                arguments: [streamURL, ms])
        }
    }
}

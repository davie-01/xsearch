import Foundation
import os

/// Personal data kept apart from rebuildable indexes (ARCHITECTURE §15–16): `user.sqlite`.
/// Records opens for ranking and the "最近打开" list shown when the input is empty, and the
/// favorites (⌘D), bound to the file id with the path kept for relocating (§13). Neither depends
/// on the indexes: rebuilding them keeps both.
public final class UsageStore: @unchecked Sendable {
    public struct Recent: Sendable, Equatable {
        public var path: String
        public var fileId: Int64?
        public var count: Int
        public var lastOpened: Date
    }

    private let lock = OSAllocatedUnfairLock()
    private let db: SQLite
    private var boundCatalog: String?
    private var usageCache: (byId: [Int64: Int], byPath: [String: Int])?

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        db = try SQLite(path: directory.appendingPathComponent("user.sqlite").path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS opens(path TEXT PRIMARY KEY, file_id INTEGER, count INTEGER NOT NULL, last_opened REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS opens_recent ON opens(last_opened);
            CREATE TABLE IF NOT EXISTS favorites(path TEXT PRIMARY KEY, file_id INTEGER, added REAL NOT NULL);
            """)
        // Personal data is never discarded: a file from a newer build is used as it is (its
        // tables only grow), not migrated backwards.
        do { try Migrations.migrate(db, file: "user.sqlite", steps: Self.migrations) } catch is Migrations.NewerFormat {}
        try db.exec("CREATE TABLE IF NOT EXISTS user_meta(key TEXT PRIMARY KEY, value TEXT)")
    }

    /// Version 1: opens + favorites (M3). Version 2: which catalog the stored file ids belong to.
    static let migrations: [@Sendable (SQLite) throws -> Void] = [
        { _ in },
        { db in try db.exec("CREATE TABLE IF NOT EXISTS user_meta(key TEXT PRIMARY KEY, value TEXT)") },
    ]

    /// File ids are catalog row ids: after a rebuild the same number is another file. Paths stay;
    /// ids from another catalog are forgotten, so nothing follows a stranger's id.
    public func bindCatalog(_ id: String) {
        lock.withLock {
            guard id != boundCatalog else { return }
            let stored = try? db.prepare("SELECT value FROM user_meta WHERE key = 'catalog_id'").first { $0.text(0) }
            if stored != id {
                _ = try? db.transaction {
                    try db.exec("UPDATE opens SET file_id = NULL; UPDATE favorites SET file_id = NULL;")
                    try db.prepare("INSERT OR REPLACE INTO user_meta(key, value) VALUES('catalog_id', ?)").bind(id).run()
                }
                usageCache = nil
            }
            boundCatalog = id
        }
    }

    public struct Favorite: Sendable, Equatable {
        public var path: String
        public var fileId: Int64?
    }

    /// Newest first.
    public func favorites() -> [Favorite] {
        lock.withLock {
            guard let s = try? db.prepare("SELECT path, file_id FROM favorites ORDER BY added DESC") else { return [] }
            var out: [Favorite] = []
            while (try? s.step()) == true { out.append(Favorite(path: s.text(0), fileId: s.isNull(1) ? nil : s.int(1))) }
            return out
        }
    }

    public func isFavorite(path: String) -> Bool {
        lock.withLock { ((try? db.prepare("SELECT 1 FROM favorites WHERE path = ?").bind(path).first { _ in true }) ?? nil) != nil }
    }

    /// Adds or removes; returns whether the item is a favorite afterwards.
    @discardableResult
    public func toggleFavorite(path: String, fileId: Int64?) -> Bool {
        let was = isFavorite(path: path)
        lock.withLock {
            if was {
                _ = try? db.prepare("DELETE FROM favorites WHERE path = ?").bind(path).run()
            } else {
                _ = try? db.prepare("INSERT OR REPLACE INTO favorites(path, file_id, added) VALUES(?, ?, ?)")
                    .bind(path, fileId, Date().timeIntervalSince1970).run()
            }
        }
        return !was
    }

    /// The file moved or was renamed: keep the favorite under its new path.
    public func relocateFavorite(from old: String, to new: String) {
        lock.withLock { _ = try? db.prepare("UPDATE OR REPLACE favorites SET path = ? WHERE path = ?").bind(new, old).run() }
    }

    public func recordOpen(path: String, fileId: Int64?) {
        lock.withLock {
            _ = try? db.prepare("""
                INSERT INTO opens(path, file_id, count, last_opened) VALUES(?, ?, 1, ?)
                ON CONFLICT(path) DO UPDATE SET count = count + 1, last_opened = excluded.last_opened, file_id = COALESCE(excluded.file_id, file_id)
                """).bind(path, fileId, Int64(Date().timeIntervalSince1970)).run()
            usageCache = nil
        }
    }

    public func recents(limit: Int = 8) -> [Recent] {
        lock.withLock {
            guard let s = try? db.prepare("SELECT path, file_id, count, last_opened FROM opens ORDER BY last_opened DESC LIMIT ?").bind(limit) else { return [] }
            var out: [Recent] = []
            while (try? s.step()) == true {
                out.append(Recent(path: s.text(0), fileId: s.isNull(1) ? nil : s.int(1), count: Int(s.int(2)),
                                  lastOpened: Date(timeIntervalSince1970: TimeInterval(s.int(3)))))
            }
            return out
        }
    }

    /// Open counts by file id and by path, for ranking. Asked on every keystroke, changed only
    /// by opening something: kept until then.
    public func usage() -> (byId: [Int64: Int], byPath: [String: Int]) {
        lock.withLock {
            if let usageCache { return usageCache }
            var ids: [Int64: Int] = [:], paths: [String: Int] = [:]
            guard let s = try? db.prepare("SELECT path, file_id, count FROM opens ORDER BY last_opened DESC LIMIT 5000") else { return (ids, paths) }
            while (try? s.step()) == true {
                paths[s.text(0)] = Int(s.int(2))
                if !s.isNull(1) { ids[s.int(1)] = Int(s.int(2)) }
            }
            usageCache = (ids, paths)
            return (ids, paths)
        }
    }

    /// Settings › 清除最近打开: forgets every open (ranking by use starts over too).
    public func clearOpens() {
        lock.withLock {
            _ = try? db.exec("DELETE FROM opens")
            usageCache = nil
        }
    }

    public func remove(path: String) {
        lock.withLock {
            _ = try? db.prepare("DELETE FROM opens WHERE path = ?").bind(path).run()
            usageCache = nil
        }
    }
}

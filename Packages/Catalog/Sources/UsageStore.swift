import Foundation
import os

/// Personal data kept apart from rebuildable indexes (ARCHITECTURE §15–16): `user.sqlite`.
/// Records opens for ranking and the "最近打开" list shown when the input is empty.
public final class UsageStore: @unchecked Sendable {
    public struct Recent: Sendable, Equatable {
        public var path: String
        public var fileId: Int64?
        public var count: Int
        public var lastOpened: Date
    }

    private let lock = OSAllocatedUnfairLock()
    private let db: SQLite

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        db = try SQLite(path: directory.appendingPathComponent("user.sqlite").path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS opens(path TEXT PRIMARY KEY, file_id INTEGER, count INTEGER NOT NULL, last_opened REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS opens_recent ON opens(last_opened);
            """)
    }

    public func recordOpen(path: String, fileId: Int64?) {
        lock.withLock {
            _ = try? db.prepare("""
                INSERT INTO opens(path, file_id, count, last_opened) VALUES(?, ?, 1, ?)
                ON CONFLICT(path) DO UPDATE SET count = count + 1, last_opened = excluded.last_opened, file_id = COALESCE(excluded.file_id, file_id)
                """).bind(path, fileId, Int64(Date().timeIntervalSince1970)).run()
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

    /// Open counts by file id and by path, for ranking.
    public func usage() -> (byId: [Int64: Int], byPath: [String: Int]) {
        lock.withLock {
            var ids: [Int64: Int] = [:], paths: [String: Int] = [:]
            guard let s = try? db.prepare("SELECT path, file_id, count FROM opens ORDER BY last_opened DESC LIMIT 5000") else { return (ids, paths) }
            while (try? s.step()) == true {
                paths[s.text(0)] = Int(s.int(2))
                if !s.isNull(1) { ids[s.int(1)] = Int(s.int(2)) }
            }
            return (ids, paths)
        }
    }

    public func remove(path: String) {
        lock.withLock { _ = try? db.prepare("DELETE FROM opens WHERE path = ?").bind(path).run() }
    }
}

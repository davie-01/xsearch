import Foundation
import NameEngine
import XSearchCore

/// One `op_journal` entry (ARCHITECTURE §9.2). File-system events and rescans share one ordered,
/// replayable log; consumers keep their own watermark.
struct JournalOp: Equatable {
    enum Kind: Int64 {
        case fsevent = 1
        /// Reconcile a subtree recursively (initial scan, MustScanSubDirs, dropped events).
        case rescan = 2
        /// Scope changed: sync root rows, then rescan every root.
        case scope = 3
        /// Content folders added or removed, or content rules changed, where the catalog already
        /// holds every file concerned (inside the name scope): their files are decided again,
        /// nothing is listed. `path`: JSON array of absolute folder paths.
        case content = 4
    }
    var jseq: Int64
    var kind: Kind
    var path: String
    var flags: UInt32
}

/// FSEvents flag bits used here (CoreServices constants, kept local so tests need no stream).
enum EventFlag {
    static let mustScanSubDirs: UInt32 = 0x0000_0001
    static let userDropped: UInt32 = 0x0000_0002
    static let kernelDropped: UInt32 = 0x0000_0004
    static let eventIdsWrapped: UInt32 = 0x0000_0008
    static let rootChanged: UInt32 = 0x0000_0020
}

struct Row {
    var id: Int64
    var parentId: Int64
    var name: String
    var flags: EntryFlags
    var dev: Int64
    var ino: Int64
    var birthNs: Int64
    var size: Int64
    var mtimeNs: Int64
}

/// SQLite FileCatalog: the persistent truth for file identity. Entries are stored as a tree
/// (parent id + on-disk name), so moving a directory rewrites one row. Root rows have
/// `parent_id = 0` and store their absolute path as the name.
final class FileCatalog {
    let db: SQLite
    static let nameConsumer = "name"
    static let rowColumns = "id,parent_id,name,flags,dev,ino,birth_ns,size,mtime_ns"

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        db = try SQLite(path: url.path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS files(
                id INTEGER PRIMARY KEY,
                parent_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                flags INTEGER NOT NULL,
                dev INTEGER NOT NULL,
                ino INTEGER NOT NULL,
                birth_ns INTEGER NOT NULL,
                size INTEGER NOT NULL,
                mtime_ns INTEGER NOT NULL,
                in_name INTEGER NOT NULL DEFAULT 1,
                in_content INTEGER NOT NULL DEFAULT 0,
                op_seq INTEGER NOT NULL DEFAULT 0,
                change_seq INTEGER NOT NULL,
                deleted INTEGER NOT NULL DEFAULT 0);
            CREATE UNIQUE INDEX IF NOT EXISTS files_child ON files(parent_id, name) WHERE deleted = 0;
            CREATE INDEX IF NOT EXISTS files_inode ON files(dev, ino) WHERE deleted = 0;
            CREATE INDEX IF NOT EXISTS files_change ON files(change_seq);
            CREATE TABLE IF NOT EXISTS op_journal(
                jseq INTEGER PRIMARY KEY AUTOINCREMENT,
                kind INTEGER NOT NULL,
                path TEXT NOT NULL,
                flags INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS consumers(name TEXT PRIMARY KEY, applied_jseq INTEGER NOT NULL);
            INSERT OR IGNORE INTO consumers(name, applied_jseq) VALUES('name', 0);
            -- Content tasks (§9.3 step 1). Identity: file_id + op_seq + kind. Written in the same
            -- transaction as the catalog change that caused them.
            CREATE TABLE IF NOT EXISTS content_tasks(
                file_id INTEGER NOT NULL,
                op_seq INTEGER NOT NULL,
                kind INTEGER NOT NULL,
                state INTEGER NOT NULL DEFAULT 0,
                lease_until REAL NOT NULL DEFAULT 0,
                attempts INTEGER NOT NULL DEFAULT 0,
                not_before REAL NOT NULL DEFAULT 0,
                priority INTEGER NOT NULL DEFAULT 0,
                error TEXT,
                PRIMARY KEY(file_id, op_seq, kind));
            CREATE INDEX IF NOT EXISTS content_tasks_ready ON content_tasks(state, not_before, priority);
            -- Members of the one unconfirmed batch (§9.3: at most one per instance), recorded before
            -- the index commit so a crash between commit and confirmation can be resolved.
            -- state / error: what confirmation records for the file (0 none, 1 complete, 2 partial,
            -- 3 waiting for OCR, 4 failed).
            CREATE TABLE IF NOT EXISTS content_batch(file_id INTEGER NOT NULL, op_seq INTEGER NOT NULL, kind INTEGER NOT NULL,
                state INTEGER NOT NULL DEFAULT 0, error TEXT);
            """)
        try Migrations.migrate(db, file: "catalog.sqlite", steps: Self.migrations)
        for suffix in ["-wal", "-shm"] { chmod(url.path + suffix, 0o600) }
    }

    /// Schema steps after the tables above (which describe the current layout for new files).
    /// Version 1: M1 tables. Version 2: M2 content columns on catalogs created by M1. Version 3:
    /// partial index for content counts. Unversioned
    /// catalogs (before M5) start at 0 and pass through the idempotent steps.
    static let migrations: [@Sendable (SQLite) throws -> Void] = [
        { _ in },
        { db in
            let columns = try Set(FileCatalog.columns(db, "files"))
            for (name, decl) in [("content_state", "INTEGER NOT NULL DEFAULT 0"), ("content_error", "TEXT")] where !columns.contains(name) {
                try db.exec("ALTER TABLE files ADD COLUMN \(name) \(decl)")
            }
        },
        // v3: content-state counts without visiting every name entry (56 ms → 0.04 ms on 170k files).
        { db in try db.exec("CREATE INDEX IF NOT EXISTS files_content_state ON files(content_state) WHERE deleted = 0 AND in_content = 1") },
    ]

    static func columns(_ db: SQLite, _ table: String) throws -> [String] {
        let s = try db.prepare("SELECT name FROM pragma_table_info(?)").bind(table)
        var out: [String] = []
        while try s.step() { out.append(s.text(0)) }
        return out
    }

    // MARK: Content

    enum TaskKind: Int64 { case index = 1, delete = 2 }

    struct ContentInfo {
        var id: Int64
        var parentId: Int64
        var name: String
        var flags: EntryFlags
        var mtimeNs: Int64
        var inContent: Bool
        var opSeq: Int64
        var deleted: Bool
    }

    func contentInfo(_ id: Int64) throws -> ContentInfo? {
        try db.prepare("SELECT id, parent_id, name, flags, mtime_ns, in_content, op_seq, deleted FROM files WHERE id = ?").bind(id).first { s in
            ContentInfo(id: s.int(0), parentId: s.int(1), name: s.text(2), flags: EntryFlags(rawValue: UInt8(truncatingIfNeeded: s.int(3))),
                        mtimeNs: s.int(4), inContent: s.int(5) != 0, opSeq: s.int(6), deleted: s.int(7) != 0)
        }
    }

    func setContent(_ id: Int64, inContent: Bool, opSeq: Int64) throws {
        try db.prepare("UPDATE files SET in_content = ?, op_seq = ? WHERE id = ?").bind(inContent, opSeq, id).run()
    }

    /// Adds a task and drops older pending tasks of the same file: only the newest op matters,
    /// and leased older ones are rejected by the writer's sequence check anyway.
    func enqueue(_ fileId: Int64, opSeq: Int64, kind: TaskKind, priority: Int64) throws {
        try db.prepare("DELETE FROM content_tasks WHERE file_id = ? AND op_seq < ? AND state = 0").bind(fileId, opSeq).run()
        try db.prepare("INSERT OR IGNORE INTO content_tasks(file_id, op_seq, kind, priority) VALUES(?, ?, ?, ?)")
            .bind(fileId, opSeq, kind.rawValue, priority).run()
    }

    /// Global op_seq counter: sequences never go backwards even if a file id is reused, so a
    /// new file can never fall behind an old tombstone's fence.
    func opSeqCounter() throws -> Int64 { try meta("op_seq_counter").flatMap(Int64.init) ?? 0 }
    func setOpSeqCounter(_ v: Int64) throws { try setMeta("op_seq_counter", String(v)) }

    /// Live file ids below a directory (any depth).
    func descendantFiles(of id: Int64) throws -> [Int64] {
        let s = try db.prepare("""
            WITH RECURSIVE sub(id) AS (SELECT ? UNION SELECT f.id FROM files f JOIN sub ON f.parent_id = sub.id WHERE f.deleted = 0)
            SELECT f.id FROM files f JOIN sub ON f.id = sub.id WHERE (f.flags & 1) = 0
            """).bind(id)
        var out: [Int64] = []
        while try s.step() { out.append(s.int(0)) }
        return out
    }

    /// Every live file whose name has an extractable extension: candidates on a scope change.
    func contentCandidates() throws -> [Int64] {
        let s = try db.prepare("SELECT id, name, in_content FROM files WHERE deleted = 0 AND (flags & 1) = 0")
        var out: [Int64] = []
        while try s.step() {
            if s.int(2) != 0 || ContentType.of(name: s.text(1)) != nil { out.append(s.int(0)) }
        }
        return out
    }

    // MARK: Meta

    func meta(_ key: String) throws -> String? {
        let s = try db.prepare("SELECT value FROM meta WHERE key = ?").bind(key)
        return try s.first { s in s.text(0) } ?? nil
    }

    func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.prepare("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").bind(key, value).run()
        } else {
            try db.prepare("DELETE FROM meta WHERE key = ?").bind(key).run()
        }
    }

    // MARK: Journal

    /// Appends events and advances the FSEvents cursor in the same transaction: the cursor never
    /// moves past an event that is not durably journaled.
    func append(_ ops: [(JournalOp.Kind, String, UInt32)], lastEventId: UInt64?) throws {
        try db.transactionIfNeeded {
            let s = try db.prepare("INSERT INTO op_journal(kind, path, flags) VALUES(?, ?, ?)")
            for (kind, path, flags) in ops {
                try s.bind(kind.rawValue, path, Int64(flags)).run()
                s.reset()
            }
            if let lastEventId { try setMeta("fsevents_last_id", String(lastEventId)) }
        }
    }

    func journal(after jseq: Int64, limit: Int) throws -> [JournalOp] {
        let s = try db.prepare("SELECT jseq, kind, path, flags FROM op_journal WHERE jseq > ? ORDER BY jseq LIMIT ?").bind(jseq, limit)
        var out: [JournalOp] = []
        while try s.step() {
            guard let kind = JournalOp.Kind(rawValue: s.int(1)) else { continue }
            out.append(JournalOp(jseq: s.int(0), kind: kind, path: s.text(2), flags: UInt32(truncatingIfNeeded: s.int(3))))
        }
        return out
    }

    func consumer(_ name: String) throws -> Int64 {
        let s = try db.prepare("SELECT applied_jseq FROM consumers WHERE name = ?").bind(name)
        return try s.first { s in s.int(0) } ?? 0
    }

    func setConsumer(_ name: String, _ jseq: Int64) throws {
        try db.prepare("UPDATE consumers SET applied_jseq = ? WHERE name = ?").bind(jseq, name).run()
    }

    /// Deletes only entries every consumer has processed.
    func trimJournal() throws {
        try db.exec("DELETE FROM op_journal WHERE jseq <= (SELECT MIN(applied_jseq) FROM consumers)")
    }

    func journalBacklog() throws -> Int {
        let s = try db.prepare("SELECT COUNT(*) FROM op_journal WHERE jseq > (SELECT applied_jseq FROM consumers WHERE name = 'name')")
        return try s.first { s in Int(s.int(0)) } ?? 0
    }

    // MARK: Rows

    static func record(_ r: Row) -> NameRecord {
        if r.parentId == 0 {
            let last = r.name == "/" ? "/" : (r.name as NSString).lastPathComponent
            return NameRecord(fileId: r.id, parentId: 0, name: last, flags: r.flags, size: r.size, mtime: r.mtimeNs / 1_000_000_000, rootPath: r.name)
        }
        return NameRecord(fileId: r.id, parentId: r.parentId, name: r.name, flags: r.flags, size: r.size, mtime: r.mtimeNs / 1_000_000_000)
    }

    private func row(_ s: Statement, offset: Int32 = 0) -> Row {
        Row(id: s.int(offset), parentId: s.int(offset + 1), name: s.text(offset + 2), flags: EntryFlags(rawValue: UInt8(truncatingIfNeeded: s.int(offset + 3))),
            dev: s.int(offset + 4), ino: s.int(offset + 5), birthNs: s.int(offset + 6), size: s.int(offset + 7), mtimeNs: s.int(offset + 8))
    }

    func liveRecords() throws -> [NameRecord] {
        let s = try db.prepare("SELECT \(Self.rowColumns) FROM files WHERE deleted = 0")
        var out: [NameRecord] = []
        while try s.step() { out.append(Self.record(row(s))) }
        return out
    }

    /// Rows changed after a persisted snapshot: the overlay to replay on startup.
    func changes(after seq: Int64) throws -> [NameChange] {
        let s = try db.prepare("SELECT \(Self.rowColumns), deleted FROM files WHERE change_seq > ? ORDER BY change_seq")
        s.bind(seq)
        var out: [NameChange] = []
        while try s.step() {
            let r = row(s)
            out.append(s.int(9) != 0 ? .remove(r.id) : .upsert(Self.record(r)))
        }
        return out
    }

    /// Tombstones are needed only until a snapshot at or after their sequence is on disk, and
    /// until the indexer has processed their tasks. The row with the highest id always stays:
    /// SQLite gives a new row the highest id + 1, so deleting it would hand its id to an
    /// unrelated file, and a favorite or open count stored by id would follow that file.
    func purgeTombstones(upTo seq: Int64) throws {
        try db.prepare("""
            DELETE FROM files WHERE deleted = 1 AND change_seq <= ?
              AND id < (SELECT MAX(id) FROM files)
              AND NOT EXISTS (SELECT 1 FROM content_tasks t WHERE t.file_id = files.id)
            """).bind(seq).run()
    }

    func liveCount() throws -> Int {
        let s = try db.prepare("SELECT COUNT(*) FROM files WHERE deleted = 0")
        return try s.first { s in Int(s.int(0)) } ?? 0
    }

    func rootRows() throws -> [Row] {
        let s = try db.prepare("SELECT \(Self.rowColumns) FROM files WHERE parent_id = 0 AND deleted = 0")
        var out: [Row] = []
        while try s.step() { out.append(row(s)) }
        return out
    }

    func children(of id: Int64) throws -> [Row] {
        let s = try db.prepare("SELECT \(Self.rowColumns) FROM files WHERE parent_id = ? AND deleted = 0").bind(id)
        var out: [Row] = []
        while try s.step() { out.append(row(s)) }
        return out
    }

    func hasChildren(_ id: Int64) throws -> Bool {
        try db.prepare("SELECT 1 FROM files WHERE parent_id = ? AND deleted = 0 LIMIT 1").bind(id).first { _ in true } ?? false
    }

    func row(id: Int64) throws -> Row? {
        let s = try db.prepare("SELECT \(Self.rowColumns) FROM files WHERE id = ? AND deleted = 0").bind(id)
        return try s.first { s in row(s) } ?? nil
    }

    func child(of parent: Int64, named name: String) throws -> Row? {
        let s = try db.prepare("SELECT \(Self.rowColumns) FROM files WHERE parent_id = ? AND name = ? AND deleted = 0").bind(parent, name)
        return try s.first { s in row(s) } ?? nil
    }

    func rows(dev: Int64, ino: Int64) throws -> [Row] {
        let s = try db.prepare("SELECT \(Self.rowColumns) FROM files WHERE dev = ? AND ino = ? AND deleted = 0").bind(dev, ino)
        var out: [Row] = []
        while try s.step() { out.append(row(s)) }
        return out
    }

    /// True when `id` is `ancestor` or lies below it (bounded walk; tolerates broken links).
    func isWithin(_ id: Int64, _ ancestor: Int64) throws -> Bool {
        var current = id
        for _ in 0..<4096 {
            if current == ancestor { return true }
            guard current != 0, let r = try row(id: current) else { return false }
            current = r.parentId
        }
        return true  // a cycle: treat as unsafe
    }

    func path(of id: Int64) throws -> String? {
        var parts: [String] = []
        var current = id
        for _ in 0..<4096 {
            guard let r = try row(id: current) else { return nil }
            if r.parentId == 0 {
                if parts.isEmpty { return r.name }
                return (r.name == "/" ? "" : r.name) + "/" + parts.reversed().joined(separator: "/")
            }
            parts.append(r.name)
            current = r.parentId
        }
        return nil
    }

    /// Deepest catalogued directory on the way to `path` (which must be inside `root`).
    func nearest(_ path: String, root: Row) throws -> (Row, String) {
        var current = root, currentPath = root.name
        let rest = root.name == "/" ? Substring(path.dropFirst()) : path.dropFirst(root.name.count + 1)
        guard path != root.name else { return (root, root.name) }
        for component in rest.split(separator: "/") {
            guard let c = try child(of: current.id, named: String(component)), c.flags.contains(.directory) else { break }
            current = c
            currentPath = (currentPath == "/" ? "" : currentPath) + "/" + component
        }
        return (current, currentPath)
    }

    func insert(parent: Int64, name: String, _ e: DiskEntry, seq: Int64) throws -> Row {
        try db.prepare("INSERT INTO files(parent_id, name, flags, dev, ino, birth_ns, size, mtime_ns, change_seq) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(parent, name, Int64(e.flags.rawValue), e.dev, e.ino, e.birthNs, e.size, e.mtimeNs, seq).run()
        return Row(id: db.lastInsertId, parentId: parent, name: name, flags: e.flags, dev: e.dev, ino: e.ino, birthNs: e.birthNs, size: e.size, mtimeNs: e.mtimeNs)
    }

    /// Insert unless the (parent, name) slot is already taken; nil when it was.
    func insertIfAbsent(parent: Int64, name: String, _ e: DiskEntry, seq: Int64) throws -> Row? {
        try db.prepare("INSERT OR IGNORE INTO files(parent_id, name, flags, dev, ino, birth_ns, size, mtime_ns, change_seq) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(parent, name, Int64(e.flags.rawValue), e.dev, e.ino, e.birthNs, e.size, e.mtimeNs, seq).run()
        guard db.changes > 0 else { return nil }
        return Row(id: db.lastInsertId, parentId: parent, name: name, flags: e.flags, dev: e.dev, ino: e.ino, birthNs: e.birthNs, size: e.size, mtimeNs: e.mtimeNs)
    }

    func update(_ r: Row, seq: Int64) throws {
        try db.prepare("UPDATE files SET parent_id=?, name=?, flags=?, dev=?, ino=?, birth_ns=?, size=?, mtime_ns=?, change_seq=? WHERE id=?")
            .bind(r.parentId, r.name, Int64(r.flags.rawValue), r.dev, r.ino, r.birthNs, r.size, r.mtimeNs, seq, r.id).run()
    }

    /// Marks a row and its whole subtree deleted; returns the affected ids.
    func deleteSubtree(_ id: Int64, seq: Int64) throws -> [Int64] {
        let s = try db.prepare("""
            WITH RECURSIVE sub(id) AS (SELECT ? UNION SELECT f.id FROM files f JOIN sub ON f.parent_id = sub.id WHERE f.deleted = 0)
            SELECT id FROM sub
            """).bind(id)
        var ids: [Int64] = []
        while try s.step() { ids.append(s.int(0)) }
        let u = try db.prepare("UPDATE files SET deleted = 1, change_seq = ? WHERE id = ?")
        for i in ids { try u.bind(seq, i).run(); u.reset() }
        return ids
    }
}

import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin SQLite wrapper. Not thread-safe: each connection is confined to one serial queue.
final class SQLite {
    let db: OpaquePointer
    private var cache: [String: Statement] = [:]

    init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: message)
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        chmod(path, 0o600)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA temp_store=MEMORY;")
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(db)
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? ""
            sqlite3_free(err)
            throw SQLiteError(code: sqlite3_errcode(db), message: message)
        }
    }

    /// Cached prepared statement, reset and cleared for reuse.
    func prepare(_ sql: String) throws -> Statement {
        if let s = cache[sql] { s.reset(); return s }
        let s = try Statement(self, sql)
        cache[sql] = s
        return s
    }

    /// A cached statement left mid-result keeps a read lock open, which stops checkpoints from
    /// ever emptying the WAL. Reset them all once their results are no longer needed.
    func resetStatements() {
        for s in cache.values { sqlite3_reset(s.stmt) }
    }

    /// Folds the WAL into the database file and truncates it.
    func checkpoint() throws {
        resetStatements()
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            resetStatements()
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Joins an enclosing transaction instead of failing on a nested BEGIN.
    func transactionIfNeeded<T>(_ body: () throws -> T) throws -> T {
        sqlite3_get_autocommit(db) == 0 ? try body() : try transaction(body)
    }

    var lastInsertId: Int64 { sqlite3_last_insert_rowid(db) }
    var changes: Int { Int(sqlite3_changes(db)) }

    func error() -> SQLiteError { SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db))) }
}

final class Statement {
    let stmt: OpaquePointer
    unowned let conn: SQLite
    let sql: String

    init(_ conn: SQLite, _ sql: String) throws {
        self.sql = sql
        var s: OpaquePointer?
        guard sqlite3_prepare_v3(conn.db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &s, nil) == SQLITE_OK, let s else {
            throw conn.error()
        }
        stmt = s
        self.conn = conn
    }

    deinit { sqlite3_finalize(stmt) }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    @discardableResult
    func bind(_ values: Any?...) -> Statement {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(stmt, idx)
            case let x as Int64: sqlite3_bind_int64(stmt, idx, x)
            case let x as Int: sqlite3_bind_int64(stmt, idx, Int64(x))
            case let x as UInt64: sqlite3_bind_int64(stmt, idx, Int64(bitPattern: x))
            case let x as Bool: sqlite3_bind_int64(stmt, idx, x ? 1 : 0)
            case let x as Double: sqlite3_bind_double(stmt, idx, x)
            case let x as String: sqlite3_bind_text(stmt, idx, x, -1, SQLITE_TRANSIENT)
            case let x as Data: _ = x.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            default: preconditionFailure("unsupported bind type \(type(of: v))")
            }
        }
        return self
    }

    /// Steps once; returns true when a row is available.
    func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let e = conn.error()
            throw SQLiteError(code: e.code, message: e.message + " [" + sql.prefix(60) + "]")
        }
    }

    func run() throws { while try step() {} }

    /// Reads at most one row and resets right away. A statement left on a row keeps an open
    /// read transaction: the connection would keep seeing an old snapshot (missing other
    /// connections' writes) and block WAL checkpoints. Use this for every single-row read.
    func first<T>(_ map: (Statement) throws -> T) throws -> T? {
        defer { sqlite3_reset(stmt) }
        guard try step() else { return nil }
        return try map(self)
    }

    func int(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
    func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
    func text(_ col: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: p)
    }
    func isNull(_ col: Int32) -> Bool { sqlite3_column_type(stmt, col) == SQLITE_NULL }
}

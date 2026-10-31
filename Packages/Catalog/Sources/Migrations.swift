import Foundation

/// Versioned SQLite schemas (M5: upgrades and data migration). `PRAGMA user_version` records
/// the schema a file has; `migrate` runs every newer step in order, each in a transaction, so
/// an interrupted upgrade resumes from the last completed step. A file written by a newer
/// build is reported, never altered.
enum Migrations {
    struct NewerFormat: Error, CustomStringConvertible {
        var file: String
        var found: Int
        var supported: Int
        var description: String { "\(file) 由更新的版本创建（格式 \(found)，当前支持 \(supported)）" }
    }

    /// `steps[i]` upgrades version i to i + 1. Steps must be idempotent: the app and IndexService
    /// can open a catalog at the same moment and both decide to run a step (each runs inside
    /// BEGIN IMMEDIATE, so never concurrently). Returns the version found before migrating.
    @discardableResult
    static func migrate(_ db: SQLite, file: String, steps: [@Sendable (SQLite) throws -> Void]) throws -> Int {
        let found = Int(try db.prepare("PRAGMA user_version").first { $0.int(0) } ?? 0)
        guard found <= steps.count else { throw NewerFormat(file: file, found: found, supported: steps.count) }
        for v in found..<steps.count {
            try db.transaction {
                try steps[v](db)
                try db.exec("PRAGMA user_version = \(v + 1)")
            }
        }
        return found
    }
}

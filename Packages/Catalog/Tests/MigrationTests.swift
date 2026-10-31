import Foundation
import Testing
@testable import Catalog
import XSearchCore

/// M5 upgrades: versioned SQLite schemas, newer files after a downgrade, content index schema
/// changes, settings that gain fields.

@Test func unversionedM1CatalogIsMigrated() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xs-mig-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("catalog.sqlite")
    // An M1 catalog: files table without the M2 content columns, no user_version.
    do {
        let db = try SQLite(path: url.path)
        try db.exec("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE files(id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL, name TEXT NOT NULL, flags INTEGER NOT NULL,
                dev INTEGER NOT NULL, ino INTEGER NOT NULL, birth_ns INTEGER NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
                in_name INTEGER NOT NULL DEFAULT 1, in_content INTEGER NOT NULL DEFAULT 0, op_seq INTEGER NOT NULL DEFAULT 0,
                change_seq INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0);
            INSERT INTO files(id, parent_id, name, flags, dev, ino, birth_ns, size, mtime_ns, change_seq) VALUES(1, 0, '/r', 1, 1, 1, 0, 0, 0, 1);
            """)
    }
    let catalog = try FileCatalog(url: url)
    #expect(try Set(FileCatalog.columns(catalog.db, "files")).isSuperset(of: ["content_state", "content_error"]))
    #expect(try catalog.db.prepare("PRAGMA user_version").first { $0.int(0) } == Int64(FileCatalog.migrations.count))
    #expect(try catalog.db.prepare("SELECT name FROM files WHERE id = 1").first { $0.text(0) } == "/r", "rows kept")
    // Opening again is a no-op.
    _ = try FileCatalog(url: url)
}

@Test func newerCatalogIsRebuiltUserDataKept() throws {
    let box = try Sandbox("downgrade")
    try box.write("a.txt", "x")
    // A catalog and usage file from a newer build.
    try FileManager.default.createDirectory(at: box.data, withIntermediateDirectories: true)
    let catalogURL = box.data.appendingPathComponent("catalog.sqlite")
    do {
        let db = try SQLite(path: catalogURL.path)
        try db.exec("CREATE TABLE future(x); PRAGMA user_version = 99;")
    }
    #expect(throws: Migrations.NewerFormat.self) { _ = try FileCatalog(url: catalogURL) }
    let usage = try UsageStore(directory: box.data)
    usage.toggleFavorite(path: "/keep/me", fileId: 1)
    try SQLite(path: box.data.appendingPathComponent("user.sqlite").path).exec("PRAGMA user_version = 42")
    #expect(try UsageStore(directory: box.data).favorites().map(\.path) == ["/keep/me"], "personal data survives a newer format")

    let names = NameService(directory: box.data, home: "/nonexistent-home")
    names.start(scope: box.scope)
    #expect(names.waitUntilIdle())
    #expect(names.status.phase == .ready)
    #expect(names.search(NameQuery.parse("a.txt", home: "/"), limit: 10).hits.count == 1)
    let rebuilt = try FileCatalog(url: catalogURL)
    #expect(try rebuilt.db.prepare("PRAGMA user_version").first { $0.int(0) } == Int64(FileCatalog.migrations.count))
    names.shutdown()
}

@Test func contentIndexWithAnotherSchemaStartsOver() throws {
    let p = try Pipeline("schema-reset")
    defer { p.stop() }
    try p.box.write("docs/s.txt", "架构升级 omega")
    try p.start()
    #expect(p.settle())
    p.indexer.stop()
    let old = p.indexer.indexURL
    // An index written by another schema version.
    let sidecar = old.appendingPathComponent("xsearch-index.json")
    let json = try String(contentsOf: sidecar, encoding: .utf8).replacingOccurrences(of: "xs-content-v1", with: "xs-content-v0")
    try json.write(to: sidecar, atomically: true, encoding: .utf8)
    try p.restartIndexer()
    #expect(p.indexer.indexURL != old)
    #expect(!FileManager.default.fileExists(atPath: old.path), "unreadable instance removed")
    #expect(p.settle())
    #expect(try p.search("omega") == ["s.txt"])
}

@Test func settingsKeepChoicesWhenFieldsChange() throws {
    // Missing fields take defaults; present ones are kept.
    let syntax = try JSONDecoder().decode(QuerySyntax.self, from: Data(#"{"wildcards":false}"#.utf8))
    #expect(syntax == QuerySyntax(wildcards: false))
    let scope = try JSONDecoder().decode(NameScope.self, from: Data(#"{"wholeDisk":false,"folders":["/W"],"futureOption":3}"#.utf8))
    #expect(!scope.wholeDisk && scope.folders == ["/W"] && scope.excludes == NameScope.default.excludes)
}

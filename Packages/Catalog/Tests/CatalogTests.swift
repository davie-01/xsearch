import Foundation
import Testing
@testable import Catalog
import NameEngine
import XSearchCore
import SQLite3

/// Real files, real FSEvents, real SQLite. Each test gets its own scan root and data directory.
final class Sandbox {
    let root: String
    let data: URL
    let fm = FileManager.default

    private let base: URL

    init(_ label: String) throws {
        Self.removeStale()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xs-catalog-\(label)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        self.base = base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("root").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        data = base.appendingPathComponent("data")
        // FSEvents reports resolved paths (/private/var/...), so the scan root must be resolved too.
        rootReal = realpath(root, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root
    }

    let rootReal: String

    /// Sandboxes of runs killed by a timeout never reach deinit (one left a 4.8 GB WAL from
    /// the M1 checkpoint bug): anything older than six hours goes.
    static func removeStale() {
        let tmp = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("xs-catalog-") {
            let url = tmp.appendingPathComponent(name)
            if let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    var scope: NameScope {
        NameScope(wholeDisk: false, folders: [rootReal], excludes: ["node_modules", "*.log"], includeHidden: false, includePackageContents: false)
    }

    func p(_ rel: String) -> String { rootReal + "/" + rel }

    func write(_ rel: String, _ text: String = "x") throws {
        try fm.createDirectory(atPath: (p(rel) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: p(rel), atomically: false, encoding: .utf8)
    }

    func mkdir(_ rel: String) throws { try fm.createDirectory(atPath: p(rel), withIntermediateDirectories: true) }
    func mv(_ a: String, _ b: String) throws { precondition(rename(p(a), p(b)) == 0, "rename \(a) → \(b): \(errno)") }
    func rm(_ rel: String) throws { try fm.removeItem(atPath: p(rel)) }

    func service() -> NameService {
        let s = NameService(directory: data, home: "/nonexistent-home")
        s.start(scope: scope)
        return s
    }

    deinit { try? fm.removeItem(at: URL(fileURLWithPath: root).deletingLastPathComponent()) }
}

func find(_ s: NameService, _ text: String) -> [NameView.Hit] {
    s.search(NameQuery.parse(text, home: "/nonexistent-home"), limit: 1000).hits
}

/// FSEvents delivery is asynchronous: poll until the condition holds.
func eventually(_ s: NameService, timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        s.waitUntilIdle(timeout: 5)
        if condition() { return true }
        usleep(100_000)
    }
    return false
}

/// Everything below the root as the disk shows it, applying the same visibility rules.
func diskPaths(_ box: Sandbox) -> Set<String> {
    var out = Set<String>()
    func walk(_ dir: String) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in items where !name.hasPrefix(".") && name != "node_modules" && !name.lowercased().hasSuffix(".log") {
            let path = dir + "/" + name
            out.insert(path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
               (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil { walk(path) }
        }
    }
    walk(box.rootReal)
    return out
}

func indexedPaths(_ s: NameService, _ box: Sandbox) -> Set<String> {
    Set(s.search(NameQuery.parse("dir:\"\(box.rootReal)\"", home: "/"), limit: Int.max).hits.map(\.path))
}

@Test func initialScanAppliesScopeRules() throws {
    let box = try Sandbox("scan")
    try box.write("Work/A/report-2024.pdf")
    try box.write("Work/Archive/report-old.pdf")
    try box.write("Work/A/node_modules/pkg/report.js")
    try box.write("Work/A/debug.log")
    try box.write("Work/A/.secret-report")
    try box.write("合同/数据共享方案.docx")
    let s = box.service()
    defer { s.shutdown() }
    #expect(s.waitUntilIdle())
    #expect(Set(find(s, "report").map(\.name)) == ["report-2024.pdf", "report-old.pdf"])
    #expect(find(s, "report dir:\"\(box.p("Work/A"))\"").map(\.name) == ["report-2024.pdf"])
    #expect(find(s, "数据").first?.path == box.p("合同/数据共享方案.docx"))
    #expect(find(s, "kind:folder 合同").count == 1)
    #expect(indexedPaths(s, box) == diskPaths(box))
    #expect(s.rescanOps == 1)
}

@Test func liveUpdatesKeepIdentity() throws {
    let box = try Sandbox("live")
    try box.write("a/old-name.txt")
    try box.write("a/sub/deep.txt")
    try box.write("b/keep.txt")
    try box.write("doc/draft.md", "v1")
    let s = box.service()
    defer { s.shutdown() }
    #expect(s.waitUntilIdle())
    let fileId = try #require(find(s, "old-name").first?.fileId)
    let deepId = try #require(find(s, "deep").first?.fileId)
    let draftId = try #require(find(s, "draft").first?.fileId)

    // Create.
    try box.write("b/new-file.txt")
    #expect(eventually(s) { find(s, "new-file").count == 1 })

    // Rename keeps the id.
    try box.mv("a/old-name.txt", "a/renamed.txt")
    #expect(eventually(s) { find(s, "old-name").isEmpty && find(s, "renamed").first?.fileId == fileId })

    // Move across directories keeps the id.
    try box.mv("a/renamed.txt", "b/renamed.txt")
    #expect(eventually(s) { find(s, "renamed").first?.path == box.p("b/renamed.txt") })
    #expect(find(s, "renamed").first?.fileId == fileId)

    // Moving a directory moves its subtree (one catalog row changes).
    try box.mv("a/sub", "b/moved-sub")
    #expect(eventually(s) { find(s, "deep").first?.path == box.p("b/moved-sub/deep.txt") })
    #expect(find(s, "deep").first?.fileId == deepId)
    #expect(find(s, "deep dir:\"\(box.p("b"))\"").count == 1)
    #expect(find(s, "deep dir:\"\(box.p("a"))\"").isEmpty)

    // Atomic save: new inode at the same path keeps the id.
    try "v2-longer".write(toFile: box.p("doc/draft.md"), atomically: true, encoding: .utf8)
    #expect(eventually(s) { find(s, "draft").first?.size == 9 })
    #expect(find(s, "draft").first?.fileId == draftId)

    // Case-only rename on a case-insensitive volume.
    try box.mv("b/keep.txt", "b/KEEP.txt")
    #expect(eventually(s) { find(s, "keep").first?.name == "KEEP.txt" })

    // Deleting a directory removes the subtree.
    try box.rm("b/moved-sub")
    #expect(eventually(s) { find(s, "deep").isEmpty && find(s, "moved-sub").isEmpty })

    // Excluded names stay out even when created live.
    try box.write("b/node_modules/x/report.js")
    try box.write("b/trace.log")
    try box.write("b/visible-marker.txt")
    #expect(eventually(s) { find(s, "visible-marker").count == 1 })
    #expect(find(s, "report.js").isEmpty && find(s, "trace").isEmpty)
    #expect(eventually(s) { indexedPaths(s, box) == diskPaths(box) })
    #expect(s.rescanOps == 1)
}

@Test func restartReplaysHistoryWithoutRescan() throws {
    let box = try Sandbox("restart")
    try box.write("x/one.txt")
    try box.write("x/two.txt")
    var s = box.service()
    #expect(s.waitUntilIdle())
    let ids = Dictionary(uniqueKeysWithValues: find(s, "txt").map { ($0.name, $0.fileId) })
    s.shutdown()
    #expect(FileManager.default.fileExists(atPath: s.snapshotURL.path))
    // The WAL is folded back after the snapshot is written.
    let wal = (try? FileManager.default.attributesOfItem(atPath: box.data.appendingPathComponent("catalog.sqlite-wal").path)[.size] as? Int) ?? 0
    #expect(wal == 0)

    // Changes while the app is not running.
    try box.write("x/three.txt")
    try box.rm("x/two.txt")
    try box.mv("x/one.txt", "x/one-renamed.txt")
    usleep(500_000)

    s = box.service()
    defer { s.shutdown() }
    #expect(eventually(s) { Set(find(s, "txt").map(\.name)) == ["one-renamed.txt", "three.txt"] })
    #expect(find(s, "one-renamed").first?.fileId == ids["one.txt"])
    #expect(s.rescanOps == 0, "restart must not rescan")
    #expect(indexedPaths(s, box) == diskPaths(box))
}

@Test func recoversAfterCrashAndCorruptSnapshot() throws {
    let box = try Sandbox("crash")
    try box.write("k/base.txt")
    var s = box.service()
    #expect(s.waitUntilIdle())
    s.shutdown()  // snapshot written

    s = box.service()
    #expect(s.waitUntilIdle())
    try box.write("k/after-snapshot.txt")
    try box.rm("k/base.txt")
    #expect(eventually(s) { find(s, "after-snapshot").count == 1 && find(s, "base").isEmpty })
    s.simulateCrash()  // catalog committed, snapshot stale

    s = box.service()
    #expect(s.waitUntilIdle())
    #expect(find(s, "after-snapshot").count == 1)
    #expect(find(s, "base").isEmpty)
    #expect(s.rescanOps == 0)
    let url = s.snapshotURL
    s.shutdown()

    // A damaged snapshot is rebuilt from catalog rows, not from a disk rescan.
    var bytes = try Data(contentsOf: url)
    bytes[bytes.count / 2] ^= 0xFF
    try bytes.write(to: url)
    s = box.service()
    defer { s.shutdown() }
    #expect(s.waitUntilIdle())
    #expect(find(s, "after-snapshot").count == 1)
    #expect(s.rescanOps == 0)
}

@Test func unreadableDirectoryKeepsItsEntries() throws {
    let box = try Sandbox("perm")
    try box.write("locked/inside.txt")
    let s = box.service()
    defer {
        chmod(box.p("locked"), 0o755)
        s.shutdown()
    }
    #expect(s.waitUntilIdle())
    #expect(find(s, "inside").count == 1)
    chmod(box.p("locked"), 0o000)
    try box.write("trigger.txt")
    s.setScope(box.scope)  // forces a full reconcile that must list `locked` and fail
    #expect(s.waitUntilIdle())
    #expect(find(s, "inside").count == 1, "a listing failure is not an empty directory")
    #expect(find(s, "locked").first?.flags.contains(.noAccess) == true)
}

@Test func scopeChangeAddsAndRemovesEntries() throws {
    let box = try Sandbox("scope")
    try box.write("p/keep.txt")
    try box.write("p/debug.log")
    let s = box.service()
    defer { s.shutdown() }
    #expect(s.waitUntilIdle())
    #expect(find(s, "debug").isEmpty)
    var scope = box.scope
    scope.excludes = ["keep.txt"]
    s.setScope(scope)
    #expect(s.waitUntilIdle())
    #expect(find(s, "debug").count == 1)
    #expect(find(s, "keep").isEmpty)
}

/// A directory replaced by a new one of the same name while its child moved to a place found
/// only later in the batch: the old subtree is deleted, then the child turns up. It must not
/// come back as a moved row that the catalog holds as deleted (the name index showed a ghost).
@Test(arguments: 0..<12) func childOfReplacedDirectoryMovedAway(attempt: Int) throws {
    let box = try Sandbox("replaced-\(attempt)")
    try box.write("a/sub/f.txt")
    try box.write("b/k.txt")
    let s = box.service()
    defer { s.shutdown() }
    #expect(s.waitUntilIdle())
    let fm = box.fm
    try fm.moveItem(atPath: box.p("a/sub"), toPath: box.p("b/moved"))
    try fm.moveItem(atPath: box.p("b"), toPath: box.p("c"))
    try fm.removeItem(atPath: box.p("a"))
    try fm.createDirectory(atPath: box.p("a"), withIntermediateDirectories: true)
    #expect(eventually(s) { indexedPaths(s, box) == diskPaths(box) && indexedPaths(s, box).contains(box.p("c/moved/f.txt")) })
    s.waitUntilIdle()
    usleep(600_000)
    s.waitUntilIdle()
    #expect(indexedPaths(s, box) == diskPaths(box), "index-only \(indexedPaths(s, box).subtracting(diskPaths(box)).sorted())")
}

@Test func oldSnapshotIsRebuiltFromCatalogRowsOnce() throws {
    let box = try Sandbox("ghost")
    try box.write("keep.txt")
    try box.write("ghost.txt")
    func names(_ s: NameService) -> Set<String> { Set(indexedPaths(s, box).map { ($0 as NSString).lastPathComponent }) }
    var s = box.service()
    #expect(s.waitUntilIdle())
    // The files' own events may still arrive: applied now, they cannot be replayed later (a
    // shutdown leaves a batch in progress for the next start) and re-add ghost.txt from disk.
    usleep(800_000)
    #expect(s.waitUntilIdle())
    s.shutdown()
    // What the old bug left behind: deleted in the catalog, present in the saved snapshot. The
    // file stays on disk so no reconcile could explain the outcome.
    let c = try FileCatalog(url: box.data.appendingPathComponent("catalog.sqlite"))
    try c.db.exec("UPDATE files SET deleted = 1 WHERE name = 'ghost.txt'")
    s = box.service()
    #expect(s.waitUntilIdle())
    #expect(names(s).contains("ghost.txt"), "a current snapshot is trusted")
    s.shutdown()
    try c.db.exec("DELETE FROM meta WHERE key = 'names_snapshot_generation'")
    s = box.service()
    #expect(s.waitUntilIdle())
    #expect(!names(s).contains("ghost.txt") && names(s).contains("keep.txt"), "rows are the truth")
    s.shutdown()
    #expect(try c.meta("names_snapshot_generation") != nil, "and it happens once")
}

@Test func randomOperationsMatchDisk() throws {
    let box = try Sandbox("random")
    var rng = SystemRandomNumberGenerator()
    let names = ["报告", "report", "Data", "合同", "note", "Café"]
    for i in 0..<120 { try box.write("d\(i % 6)/s\(i % 4)/\(names[i % names.count])-\(i).txt") }
    let s = box.service()
    defer { s.shutdown() }
    #expect(s.waitUntilIdle())
    #expect(indexedPaths(s, box) == diskPaths(box))
    for round in 0..<6 {
        for _ in 0..<40 {
            let all = Array(diskPaths(box)).sorted()
            guard let victim = all.randomElement(using: &rng) else { break }
            let rel = String(victim.dropFirst(box.rootReal.count + 1))
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: try box.write("d\(Int.random(in: 0..<8, using: &rng))/n\(round)-\(Int.random(in: 0..<1000, using: &rng)).txt")
            case 1: try? box.rm(rel)
            case 2: _ = rename(victim, (victim as NSString).deletingLastPathComponent + "/r\(round)-\(Int.random(in: 0..<1000, using: &rng))")
            case 3:
                let target = box.p("d\(Int.random(in: 0..<8, using: &rng))")
                try? box.fm.createDirectory(atPath: target, withIntermediateDirectories: true)
                if !PathUtil.isWithin(target, victim) { _ = rename(victim, target + "/m\(round)-\(Int.random(in: 0..<1000, using: &rng))") }
            default: try? "save\(round)".write(toFile: victim, atomically: true, encoding: .utf8)
            }
        }
        let ok = eventually(s) { indexedPaths(s, box) == diskPaths(box) }
        let idx = indexedPaths(s, box), disk = diskPaths(box)
        #expect(s.rescanOps == 1, "round \(round): a failed batch fell back to a full reconcile: \(s.lastBatchError ?? "-")")
        #expect(ok, "round \(round): status \(s.status.phase) index-only \(idx.subtracting(disk).sorted()) disk-only \(disk.subtracting(idx).sorted())")
    }
}

@Test(arguments: [0, 1, 2, 3, 4, 5])
func changeInsideRenamedDirectory(order: Int) throws {
    let box = try Sandbox("order\(order)")
    try box.write("d/s/f.txt")
    try box.write("d/s/g.txt")
    try box.write("d/s/t/h.txt")
    try box.mkdir("e")
    let s = box.service()
    defer { s.shutdown() }
    #expect(s.waitUntilIdle())
    switch order {
    case 0: try box.rm("d/s/f.txt"); try box.mv("d/s", "d/r")
    case 1: try box.mv("d/s", "d/r"); try box.rm("d/r/f.txt")
    case 2: try box.rm("d/s/t/h.txt"); try box.mv("d/s", "e/m")
    case 3: try box.mv("d/s/g.txt", "e/g2.txt"); try box.mv("d/s", "d/r")
    case 4: try box.mv("d", "e/m"); try box.write("d/new.txt")  // moved away, recreated
    default: try box.rm("d"); try box.write("d/s/f.txt")         // deleted, recreated
    }
    let ok = eventually(s, timeout: 8) { indexedPaths(s, box) == diskPaths(box) }
    let idx = indexedPaths(s, box), disk = diskPaths(box)
    #expect(ok, "order \(order): index-only \(idx.subtracting(disk).sorted()) disk-only \(disk.subtracting(idx).sorted())")
}

// MARK: Content tasks (M2-3)

func pendingByName(_ s: NameService) -> [String: [Int64]] {
    var out: [String: [Int64]] = [:]
    for (t, path) in s.contentTasks() where t.state == 0 {
        out[(path ?? "#\(t.fileId)") .components(separatedBy: "/").suffix(2).joined(separator: "/"), default: []].append(t.kind)
    }
    return out
}

@Test func contentTasksFollowCatalogChanges() throws {
    let box = try Sandbox("content")
    try box.write("docs/a.txt", "合同 v1")
    try box.write("docs/b.pdf", "%PDF-fake")
    try box.write("docs/image.png", "x")
    try box.write("docs/sub/c.docx", "x")
    try box.write("other/d.txt", "outside")
    try box.write("other/moveme/e.md", "dir to move in")
    let s = NameService(directory: box.data, home: "/nonexistent-home")
    let content = ContentScope(folders: [box.p("docs")])
    s.start(scope: box.scope, content: content)
    defer { s.shutdown() }
    #expect(s.waitUntilIdle())
    var tasks = pendingByName(s)
    #expect(tasks == ["docs/a.txt": [1], "docs/b.pdf": [1], "sub/c.docx": [1]], "\(tasks)")
    let firstSeq = s.contentTasks().first { $0.path?.hasSuffix("a.txt") == true }!.task.opSeq

    // Edit: a newer index task replaces the pending one.
    try "合同 v2 longer".write(toFile: box.p("docs/a.txt"), atomically: true, encoding: .utf8)
    #expect(eventually(s) { s.contentTasks().contains { $0.path?.hasSuffix("a.txt") == true && $0.task.opSeq > firstSeq } })
    #expect(s.contentTasks().filter { $0.path?.hasSuffix("a.txt") == true && $0.task.state == 0 }.count == 1)

    // Move out of the content folder → delete; move a directory in → index its files.
    try box.mv("docs/b.pdf", "other/b.pdf")
    try box.mv("other/moveme", "docs/moveme")
    #expect(eventually(s) {
        let t = pendingByName(s)
        return t["other/b.pdf"] == [2] && t["moveme/e.md"] == [1]
    }, "\(pendingByName(s))")

    // Delete → delete task (the row is a tombstone, so no path).
    try box.rm("docs/sub/c.docx")
    #expect(eventually(s) { s.contentTasks().contains { $0.task.kind == 2 && $0.path == nil } })

    // Widen the scope: files in `other` become content.
    s.setContentScope(ContentScope(folders: [box.p("docs"), box.p("other")]))
    #expect(s.waitUntilIdle())
    tasks = pendingByName(s)
    #expect(tasks["other/d.txt"] == [1] && tasks["other/b.pdf"] == [1], "\(tasks)")
    // op_seq is globally increasing.
    let seqs = s.contentTasks().map(\.task.opSeq)
    #expect(Set(seqs).count == seqs.count)
}

@Test func favoritesToggleRelocateAndSurviveReopen() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xs-fav-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try UsageStore(directory: dir)
    #expect(store.toggleFavorite(path: "/a/x.pdf", fileId: 7))
    #expect(store.toggleFavorite(path: "/a/y.pdf", fileId: nil))
    #expect(store.isFavorite(path: "/a/x.pdf"))
    #expect(store.favorites().map(\.path) == ["/a/y.pdf", "/a/x.pdf"])
    #expect(!store.toggleFavorite(path: "/a/y.pdf", fileId: nil))
    store.relocateFavorite(from: "/a/x.pdf", to: "/b/x.pdf")
    let reopened = try UsageStore(directory: dir)
    #expect(reopened.favorites() == [UsageStore.Favorite(path: "/b/x.pdf", fileId: 7)])
}

/// The data directory is never indexed, not even when a content folder covers it: content
/// rules skip path exclusions, and writing the index would feed events back to it.
@Test func ownDataDirectoryStaysOutUnderAContentRoot() throws {
    let box = try Sandbox("owndata")
    try box.write("docs/a.txt", "x")
    try box.write("xsdata/note.txt", "x")
    let data = URL(fileURLWithPath: box.p("xsdata"))
    let s = NameService(directory: data, home: "/nonexistent-home")
    s.start(scope: box.scope, content: ContentScope(folders: [box.rootReal]))
    defer { s.shutdown() }
    #expect(s.waitUntilIdle())
    try box.write("xsdata/later.txt", "y")
    try box.write("docs/b.txt", "y")
    #expect(eventually(s) { pendingByName(s)["docs/b.txt"] != nil }, "\(pendingByName(s))")
    let tasks = s.contentTasks().compactMap(\.1).filter { PathUtil.isWithin($0, box.p("xsdata")) }
    #expect(tasks.isEmpty, "\(tasks)")
    let rows = indexedPaths(s, box).filter { PathUtil.isWithin($0, box.p("xsdata")) }
    #expect(rows.isEmpty, "\(rows)")
}

/// Ids identify a file for good: purging tombstones never frees the highest id, which SQLite
/// would give the next new file.
@Test func fileIdsAreNotReusedAfterTombstonesGo() throws {
    let box = try Sandbox("ids")
    try box.write("f.txt")
    try FileManager.default.createDirectory(at: box.data, withIntermediateDirectories: true)
    let c = try FileCatalog(url: box.data.appendingPathComponent("catalog.sqlite"))
    guard case .success(let e) = DiskLister.stat(box.p("f.txt")) else { Issue.record("stat"); return }
    let a = try c.insert(parent: 0, name: "a", e, seq: 1)
    let b = try c.insert(parent: 0, name: "b", e, seq: 1)
    _ = try c.deleteSubtree(b.id, seq: 2)
    try c.purgeTombstones(upTo: 5)
    let n = try c.insert(parent: 0, name: "n", e, seq: 3)
    #expect(n.id > b.id)
    // Other tombstones still go.
    _ = try c.deleteSubtree(a.id, seq: 4)
    try c.purgeTombstones(upTo: 5)
    #expect(try c.db.prepare("SELECT COUNT(*) FROM files WHERE id = ?").bind(a.id).first { $0.int(0) } == 0)
}

/// A slow listing does not keep the write lock: another writer of the catalog (the content
/// indexer) gets in while the scan waits for the disk.
@Test func slowListingDoesNotHoldTheWriteLock() throws {
    let box = try Sandbox("slowlist")
    for i in 0..<3 { try box.write("d\(i)/f.txt") }
    try box.write("slow/f.txt")
    let s = NameService(directory: box.data, home: "/nonexistent-home")
    let slow = box.p("slow")
    DiskLister.beforeListForTests = { path in if path == slow { usleep(3_000_000) } }
    defer { DiskLister.beforeListForTests = nil }
    s.start(scope: box.scope)
    defer { s.shutdown() }
    usleep(1_000_000)  // the scan is waiting for the slow directory now
    let other = try SQLite(path: box.data.appendingPathComponent("catalog.sqlite").path)
    sqlite3_busy_timeout(other.db, 0)
    let t = Date()
    var got = false
    while !got && Date().timeIntervalSince(t) < 1.5 {
        got = (try? other.exec("BEGIN IMMEDIATE; COMMIT")) != nil
        if !got { usleep(50_000) }
    }
    #expect(got, "write lock still held during the slow listing")
    #expect(s.waitUntilIdle())
}

/// Quitting during a scan does not wait for the rest of it; the next start scans again.
@Test func shutdownStopsAScanInProgress() throws {
    let box = try Sandbox("quitscan")
    try box.write("fast/a.txt")
    try box.write("slow/b.txt")
    let slow = box.p("slow")
    DiskLister.beforeListForTests = { path in if path == slow { usleep(4_000_000) } }
    let s = NameService(directory: box.data, home: "/nonexistent-home")
    s.start(scope: box.scope)
    usleep(800_000)
    let t = Date()
    s.shutdown()
    #expect(Date().timeIntervalSince(t) < 1.5, "shutdown waited \(Date().timeIntervalSince(t)) s")
    DiskLister.beforeListForTests = nil
    let again = NameService(directory: box.data, home: "/nonexistent-home")
    again.start(scope: box.scope)
    defer { again.shutdown() }
    #expect(again.waitUntilIdle())
    #expect(indexedPaths(again, box).contains(box.p("slow/b.txt")))
}

/// Upgrade: a catalog built before the hard exclusion, holding the data directory (a content
/// folder covered it), drops it at the next start, and its files get content deletions.
@Test func heldDataDirectoryIsDroppedAtStart() throws {
    let box = try Sandbox("heldowndata")
    try box.write("docs/a.txt", "x")
    try box.write("xsdata/note.txt", "x")
    let content = ContentScope(folders: [box.rootReal])
    // Built elsewhere: xsdata is an ordinary folder there, catalogued with a content task.
    let first = NameService(directory: box.data, home: "/nonexistent-home")
    first.start(scope: box.scope, content: content)
    #expect(first.waitUntilIdle())
    first.shutdown()
    // The same catalog now lives in xsdata, as an older version's data directory.
    let data = URL(fileURLWithPath: box.p("xsdata"))
    for name in ["catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm", "names"] {
        let from = box.data.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: data.appendingPathComponent(name)) }
    }
    let c = try FileCatalog(url: data.appendingPathComponent("catalog.sqlite"))
    let noteId = try c.db.prepare("SELECT id FROM files WHERE name = 'note.txt' AND deleted = 0").first { $0.int(0) }
    #expect(noteId != nil)
    // Same scopes: no full pass is due, so only the targeted relisting can drop it.
    #expect(try c.meta("fingerprint") != nil)
    let s = NameService(directory: data, home: "/nonexistent-home")
    s.start(scope: box.scope, content: content)
    defer { s.shutdown() }
    #expect(s.waitUntilIdle())
    let rows = indexedPaths(s, box).filter { PathUtil.isWithin($0, box.p("xsdata")) }
    #expect(rows.isEmpty, "\(rows.sorted().prefix(3))")
    #expect(s.contentTasks().contains { $0.task.fileId == noteId && $0.task.kind == 2 }, "content deletion for note.txt")
}

@Test func storageCountsKindsAndRemovesOnlyLeftovers() throws {
    let box = try Sandbox("storage")
    let fm = FileManager.default
    let tmp = box.data.appendingPathComponent("tmp")
    func file(_ url: URL, _ bytes: Int) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }
    try file(box.data.appendingPathComponent("catalog.sqlite"), 40_000)
    try file(box.data.appendingPathComponent("names/local.idx"), 20_000)
    try file(box.data.appendingPathComponent("content/abc/seg"), 30_000)
    try file(box.data.appendingPathComponent("user.sqlite"), 10_000)
    try file(box.data.appendingPathComponent("retired-x/catalog.sqlite"), 50_000)
    let oldOpen = tmp.appendingPathComponent("XSearch-open/old/a.pdf"), newOpen = tmp.appendingPathComponent("XSearch-open/new/b.pdf")
    let oldScratch = tmp.appendingPathComponent("xs-archive-1/x.txt")
    for u in [oldOpen, newOpen, oldScratch] { try file(u, 8_000) }
    let hourAgo = Date().addingTimeInterval(-2 * 3600)
    for u in [oldOpen.deletingLastPathComponent(), oldScratch.deletingLastPathComponent()] {
        try fm.setAttributes([.modificationDate: hourAgo], ofItemAtPath: u.path)
    }
    let s = IndexStorage.measure(in: box.data, temporary: tmp)
    #expect(s.names >= 60_000 && s.content >= 30_000 && s.personal >= 10_000)
    // retired-* and the two old temporary folders; the member opened just now may be in use.
    #expect(s.leftovers >= 66_000 && s.leftovers < 66_000 + 30_000)
    IndexStorage.removeLeftovers(in: box.data, temporary: tmp)
    #expect(!fm.fileExists(atPath: box.data.appendingPathComponent("retired-x").path))
    #expect(!fm.fileExists(atPath: oldOpen.path) && !fm.fileExists(atPath: oldScratch.path) && fm.fileExists(atPath: newOpen.path))
    #expect(fm.fileExists(atPath: box.data.appendingPathComponent("user.sqlite").path) && fm.fileExists(atPath: box.data.appendingPathComponent("content/abc/seg").path))
    #expect(IndexStorage.measure(in: box.data, temporary: tmp).leftovers < 30_000)
}

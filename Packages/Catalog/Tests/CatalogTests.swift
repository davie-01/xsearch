import Foundation
import Testing
@testable import Catalog
import NameEngine
import XSearchCore

/// Real files, real FSEvents, real SQLite. Each test gets its own scan root and data directory.
final class Sandbox {
    let root: String
    let data: URL
    let fm = FileManager.default

    init(_ label: String) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xs-catalog-\(label)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("root").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        data = base.appendingPathComponent("data")
        // FSEvents reports resolved paths (/private/var/...), so the scan root must be resolved too.
        rootReal = realpath(root, nil).map { defer { free($0) }; return String(cString: $0) } ?? root
    }

    let rootReal: String

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

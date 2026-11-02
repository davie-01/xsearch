import Foundation
import Testing
import UniformTypeIdentifiers
@testable import NameEngine
import XSearchCore

/// Deterministic xorshift so failures reproduce.
struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

let templates = ["数据共享方案.docx", "report-2202.pdf", "AI_notes.txt", "invoice[v2].xlsx", "sj_literal.md",
                 "cafe\u{301}.txt", "合同.docx", "Straße.TXT", "Report.PDF", "a b c.txt", "README", ".hidden.cfg"]
let dirNames = ["Work", "A", "Archive", "合同", "Projects", "src", "Café", "2024"]

/// Logical tree used as the oracle: plain dictionaries, paths computed independently.
struct Oracle {
    var records: [Int64: NameRecord] = [:]
    var nextId: Int64 = 1

    mutating func add(parent: Int64, name: String, dir: Bool, root: String? = nil) -> Int64 {
        let id = nextId; nextId += 1
        records[id] = NameRecord(fileId: id, parentId: parent, name: name, flags: dir ? .directory : [],
                                 size: id * 7, mtime: id % 97, rootPath: root)
        return id
    }

    func path(_ id: Int64) -> String {
        let r = records[id]!
        if r.parentId == 0 { return r.rootPath! }
        let p = path(r.parentId)
        return (p == "/" ? "" : p) + "/" + r.name
    }

    func descendants(_ id: Int64) -> [Int64] {
        records.values.filter { $0.parentId == id }.flatMap { [$0.fileId] + descendants($0.fileId) }
    }

    func matches(_ q: NameQuery) -> Set<Int64> {
        var out = Set<Int64>()
        for r in records.values {
            if r.parentId == 0 && r.rootPath == "/" { continue }
            let key = NameKey.bytes(r.name)
            guard q.termKeys.allSatisfy({ t in t.isEmpty || key.count >= t.count && (0...(key.count - t.count)).contains { Array(key[$0..<$0 + t.count]) == t } }) else { continue }
            let ext = keyExtension(key).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if !q.extensions.isEmpty && !q.extensions.contains(ext) { continue }
            if !q.kinds.isEmpty {
                let ok = r.flags.isApp ? q.kinds.contains(.app)
                    : r.flags.contains(.directory) ? q.kinds.contains(.folder)
                    : q.kinds.contains { $0.extensions.contains(ext) }
                if !ok { continue }
            }
            if !q.dirs.isEmpty && !q.dirs.contains(where: { inDir(r.fileId, $0) }) { continue }
            out.insert(r.fileId)
        }
        return out
    }

    func inDir(_ id: Int64, _ d: NameQuery.DirFilter) -> Bool {
        switch d {
        case .absolute(let target, _):
            let p = path(id)
            let keys = PathUtil.components(p).map(NameKey.bytes)
            let t = PathUtil.components(target).map(NameKey.bytes)
            // Strictly below the target, unless the target is at or above a scan root.
            let root = rootOf(id)
            let rootKeys = PathUtil.components(records[root]!.rootPath!).map(NameKey.bytes)
            if t.count <= rootKeys.count && Array(rootKeys.prefix(t.count)) == t && t.count < rootKeys.count { return true }
            return keys.count > t.count && Array(keys.prefix(t.count)) == t
        case .fragment(_, let comps):
            var chain: [[UInt8]] = []
            var cur = records[id]!.parentId
            while cur != 0, let r = records[cur] {
                chain.append(NameKey.bytes(r.name))
                cur = r.parentId
            }
            // chain is nearest-first; look for comps (in order) as consecutive ancestors.
            let rev = Array(chain.reversed())
            guard rev.count >= comps.count else { return false }
            for s in 0...(rev.count - comps.count) where Array(rev[s..<s + comps.count]) == comps { return true }
            return false
        }
    }

    func rootOf(_ id: Int64) -> Int64 {
        var cur = id
        while let p = records[cur]?.parentId, p != 0 { cur = p }
        return cur
    }
}

func randomTree(_ rng: inout Rng, size: Int, roots: [String] = ["/"]) -> Oracle {
    var o = Oracle()
    var dirs: [Int64] = roots.map { o.add(parent: 0, name: $0 == "/" ? "/" : String($0.split(separator: "/").last!), dir: true, root: $0) }
    while o.records.count < size {
        let parent = rng.pick(dirs)
        if rng.int(4) == 0 {
            dirs.append(o.add(parent: parent, name: rng.pick(dirNames) + "\(rng.int(3))", dir: true))
        } else {
            _ = o.add(parent: parent, name: "\(rng.int(5))-" + rng.pick(templates), dir: false)
        }
    }
    return o
}

let queries: [String] = [
    "数", "数据", "port", "ai", "2202", "sj", "[v2]", "report pdf", "café", "CAFÉ", "strasse", "不存在", "a b",
    "\"a b\"", "ext:pdf", "ext:docx;txt 合同", "kind:folder", "kind:doc", "kind:folder 2024", "dir:/Work0", "dir:合同0",
    "dir:Work1/A2", "report dir:/", "txt dir:/Work0/A1", "kind:pdf dir:Café2", "dir:/no/such",
]

func check(_ view: NameView, _ o: Oracle, _ label: String) {
    var matched = 0, nonEmpty = 0
    defer {
        // Guard against a vacuous comparison (empty == empty).
        #expect(matched > 1000 && nonEmpty >= queries.count / 2, "\(label): \(matched) hits, \(nonEmpty) non-empty")
    }
    for text in queries {
        let q = NameQuery.parse(text, home: "/Users/test")
        let got = view.search(q, limit: Int.max)
        let want = o.matches(q)
        matched += want.count
        if !want.isEmpty { nonEmpty += 1 }
        #expect(Set(got.hits.map(\.fileId)) == want, "\(label): \(text)")
        #expect(got.total == want.count, "\(label) total: \(text)")
        for h in got.hits { #expect(h.path == o.path(h.fileId), "\(label) path: \(text)") }
    }
}

@Test func asciiFastPathMatchesRust() {
    var all = (0x20..<0x7F).map { String(UnicodeScalar(UInt8($0))) }
    all += ["Hello World.TXT", "ABCxyz-_[]", ""]
    for s in all {
        var copy = s
        let rust = copy.withUTF8 { NameKey.rust($0) }
        #expect(NameKey.bytes(s) == rust, "\(s)")
    }
    #expect(NameKey.key("Straße") == "strasse")
    #expect(NameKey.key("cafe\u{301}") == "café")
}

@Test func snapshotMatchesOracleWithOverlayMergeAndReload() throws {
    for seed in [1, 2, 3, 4] as [UInt64] {
        var rng = Rng(state: 0x9E37_79B9 &+ seed)
        var o = randomTree(&rng, size: 1500, roots: seed % 2 == 0 ? ["/"] : ["/Work0", "/Users/test/Docs"])
        let snapshot = NameSnapshot.build(Array(o.records.values), seq: 1, fingerprint: "t")
        var view = NameView(base: snapshot)
        check(view, o, "base \(seed)")

        // Overlay: rename, move files and whole directories, delete subtrees, add new dirs/files.
        var changes: [NameChange] = []
        let ids = Array(o.records.keys).sorted()
        for step in 0..<60 {
            let id = rng.pick(ids)
            guard var r = o.records[id], r.parentId != 0 else { continue }
            let dirs = o.records.values.filter { $0.flags.contains(.directory) }.map(\.fileId)
            switch step % 5 {
            case 0:
                r.name = "renamed-\(step)-" + rng.pick(templates)
                o.records[id] = r; changes.append(.upsert(r))
            case 1:
                let target = rng.pick(dirs)
                // Never move a directory below itself.
                if target == id || o.descendants(id).contains(target) { continue }
                r.parentId = target
                o.records[id] = r; changes.append(.upsert(r))
            case 2:
                for d in [id] + o.descendants(id) { o.records[d] = nil; changes.append(.remove(d)) }
            case 3:
                let parent = rng.pick(dirs)
                let nd = o.add(parent: parent, name: "新目录\(step)", dir: true)
                changes.append(.upsert(o.records[nd]!))
                let nf = o.add(parent: nd, name: "report-new-\(step).pdf", dir: false)
                changes.append(.upsert(o.records[nf]!))
            default:
                r.mtime += 1000
                o.records[id] = r; changes.append(.upsert(r))
            }
        }
        view = view.applying(Array(changes.prefix(30))).applying(Array(changes.dropFirst(30)))
        check(view, o, "overlay \(seed)")

        // Background merge with a change committed after capture.
        let captured = view
        let merged = captured.merged(completeSeq: 3)
        let lateFile = o.add(parent: o.rootOf(ids[0]), name: "late-report.pdf", dir: false)
        let live = view.applying([.upsert(o.records[lateFile]!)])
        let rebased = live.rebased(onto: merged)
        #expect(rebased.overlayCount == 1)
        check(rebased, o, "rebased \(seed)")

        // Persist and reload.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xs-names-\(seed)-\(getpid()).idx")
        defer { try? FileManager.default.removeItem(at: url) }
        let full = rebased.merged(completeSeq: 4)
        #expect(full.base.seq == 4)
        try full.base.write(to: url)
        let loaded = NameView(base: try NameSnapshot.load(from: url, expectedFingerprint: "t"))
        check(loaded, o, "reloaded \(seed)")
        #expect(throws: NameSnapshot.LoadError.self) { try NameSnapshot.load(from: url, expectedFingerprint: "other") }
    }
}

@Test func corruptedSnapshotIsRejected() throws {
    var rng = Rng(state: 77)
    let o = randomTree(&rng, size: 200)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xs-corrupt-\(getpid()).idx")
    defer { try? FileManager.default.removeItem(at: url) }
    try NameSnapshot.build(Array(o.records.values), seq: 1, fingerprint: "t").write(to: url)
    var data = try Data(contentsOf: url)
    data[data.count / 2] ^= 0xFF
    try data.write(to: url)
    #expect(throws: NameSnapshot.LoadError.checksum) { try NameSnapshot.load(from: url, expectedFingerprint: "t") }
}

@Test func rankingPrefersExactThenPrefixThenBoundary() {
    var o = Oracle()
    let root = o.add(parent: 0, name: "/", dir: true, root: "/")
    let sub = o.add(parent: root, name: "x", dir: true)
    let a = o.add(parent: sub, name: "myreport.txt", dir: false)      // substring
    let b = o.add(parent: sub, name: "old-report.txt", dir: false)    // word boundary
    let c = o.add(parent: sub, name: "reports.txt", dir: false)       // prefix
    let d = o.add(parent: sub, name: "Report.pdf", dir: false)        // stem exact
    let view = NameView(base: NameSnapshot.build(Array(o.records.values), seq: 1, fingerprint: "t"))
    let hits = view.search(NameQuery.parse("report", home: "/"), limit: 10).hits.map(\.fileId)
    #expect(hits == [d, c, b, a])
    // Usage outranks recency within a level, never across levels.
    let used = view.search(NameQuery.parse("report", home: "/"), limit: 10, usage: [a: 5]).hits.map(\.fileId)
    #expect(used == [d, c, b, a])
    #expect(view.search(NameQuery.parse("report", home: "/"), limit: 2).total == 4)
}

@Test func literalLettersAreNotPinyin() {
    var o = Oracle()
    let root = o.add(parent: 0, name: "/", dir: true, root: "/")
    _ = o.add(parent: root, name: "数据.txt", dir: false)
    let lit = o.add(parent: root, name: "sj_notes.txt", dir: false)
    let view = NameView(base: NameSnapshot.build(Array(o.records.values), seq: 1, fingerprint: "t"))
    #expect(view.search(NameQuery.parse("sj", home: "/")).hits.map(\.fileId) == [lit])
}

@Test func complexQueriesFilterAndRank() {
    var o = Oracle()
    let root = o.add(parent: 0, name: "/", dir: true, root: "/")
    let work = o.add(parent: root, name: "合同", dir: true)
    let old = o.add(parent: root, name: "旧合同", dir: true)
    let a = o.add(parent: work, name: "采购合同.pdf", dir: false)
    let b = o.add(parent: work, name: "采购合同-草稿.docx", dir: false)
    let c = o.add(parent: old, name: "租赁合同.pdf", dir: false)
    let d = o.add(parent: root, name: "report-2024.txt", dir: false)
    let view = NameView(base: NameSnapshot.build(Array(o.records.values), seq: 1, fingerprint: "t"))
    func ids(_ s: String, _ syntax: QuerySyntax = .default) -> Set<Int64> {
        Set(view.search(NameQuery.parse(s, home: "/", syntax: syntax), limit: 100).hits.map(\.fileId))
    }
    #expect(ids("合同 -草稿") == [work, old, a, c])
    #expect(ids("租赁 | 采购 -docx") == [a, c])
    #expect(ids("*.pdf") == [a, c])
    #expect(ids("合同/*.pdf") == [a])
    #expect(ids("**/合同/**") == [a, b])
    #expect(ids(#"regex:^report-\d{4}"#) == [d])
    #expect(ids(#"regex:合同/.*\.pdf$"#) == [a, c])
    #expect(ids("合同 -草稿", QuerySyntax(operators: false)) == [b])
    // Oracle sizes are id * 7, mtimes id % 97; size: skips folders.
    #expect(ids("合同 size:>=\(a * 7)") == [a, b, c])
    #expect(ids("合同 size:<\(a * 7)").isEmpty)
    #expect(ids("合同 dm:<=1970-01-01").count == 5)
    // Ranking still follows the first positive literal.
    #expect(view.search(NameQuery.parse("采购合同 | 租赁", home: "/"), limit: 10).hits.first?.fileId == a)
}

/// Test runners may see only dynamic types (no launch-services database for them).
private var systemTypesAvailable: Bool { UTType(filenameExtension: "pdf")?.isDynamic == false }

@Test func documentTypesFromPlainExtensions() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("xs-ext-\(UUID().uuidString)/Plain.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    let plist: [String: Any] = ["CFBundleName": "Plain", "CFBundleDocumentTypes": [["CFBundleTypeRole": "Editor", "CFBundleTypeExtensions": ["OFD", "*"]]]]
    try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let types = DocumentTypes(appPath: app.path)
    #expect(types.appName == "Plain" && types.extensions == ["ofd"])
    #expect(types.allows(extension: "ofd") && !types.allows(extension: "app"))
}

@Test(.enabled(if: systemTypesAvailable)) func tabOnAppScopesToItsDocuments() throws {
    // A fake app declaring PDF and images (UTIs), a legacy extension, and a role-None type.
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("xs-app-\(UUID().uuidString)/Viewer.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    let plist: [String: Any] = ["CFBundleName": "Viewer", "CFBundleDocumentTypes": [
        ["CFBundleTypeRole": "Viewer", "LSItemContentTypes": ["com.adobe.pdf", "public.image", "public.folder", "com.apple.application-bundle"]],
        ["CFBundleTypeRole": "Editor", "CFBundleTypeExtensions": ["OFD", "*"]],
        ["CFBundleTypeRole": "None", "LSItemContentTypes": ["public.plain-text"]],
    ]]
    try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let types = DocumentTypes(appPath: app.path)
    #expect(types.appName == "Viewer" && types.extensions == ["ofd"])
    #expect(types.allows(extension: "pdf") && types.allows(extension: "heic") && types.allows(extension: "png") && types.allows(extension: "ofd"))
    #expect(!types.allows(extension: "txt") && !types.allows(extension: "docx") && !types.allows(extension: ""))
    #expect(!types.allows(extension: "app"), "containers are not documents")

    var o = Oracle()
    let root = o.add(parent: 0, name: "/", dir: true, root: "/")
    let pdf = o.add(parent: root, name: "合同.pdf", dir: false)
    let img = o.add(parent: root, name: "合同扫描.HEIC", dir: false)
    _ = o.add(parent: root, name: "合同.docx", dir: false)
    _ = o.add(parent: root, name: "合同", dir: true)
    let view = NameView(base: NameSnapshot.build(Array(o.records.values), seq: 1, fingerprint: "t"))
    var q = NameQuery.parse("合同", home: "/")
    q.documentTypes = types
    #expect(Set(view.search(q, limit: 10).hits.map(\.fileId)) == [pdf, img])
    // An empty input with the app scope lists all of its documents.
    var all = NameQuery.parse("", home: "/")
    all.documentTypes = types
    #expect(!all.isEmpty && Set(view.search(all, limit: 10).hits.map(\.fileId)) == [pdf, img])
}

@Test func topResultsAreAPrefixOfTheFullOrderOnTies() {
    // Same level, use and time: the deepest entries have the smallest ids.
    var records = [NameRecord(fileId: 100, parentId: 0, name: "/", flags: .directory, size: 0, mtime: 5, rootPath: "/")]
    records.append(NameRecord(fileId: 90, parentId: 100, name: "z", flags: .directory, size: 0, mtime: 5, rootPath: nil))
    for i in 1...30 { records.append(NameRecord(fileId: Int64(i), parentId: 90, name: "dup\(i).txt", flags: [], size: 0, mtime: 5, rootPath: nil)) }
    for i in 31...60 { records.append(NameRecord(fileId: Int64(i), parentId: 100, name: "dup\(i).txt", flags: [], size: 0, mtime: 5, rootPath: nil)) }
    let view = NameView(base: NameSnapshot.build(records, seq: 1, fingerprint: "t"))
    let q = NameQuery.parse("dup", home: "/")
    let all = view.search(q, limit: 1000).hits.map(\.path)
    #expect(all.count == 60)
    for limit in [1, 2, 7, 30, 59] { #expect(view.search(q, limit: limit).hits.map(\.path) == Array(all.prefix(limit)), "limit \(limit)") }
}

@Test func sparseIdsUseTheDictionaryAndSearchAlike() {
    let records = [NameRecord(fileId: 1, parentId: 0, name: "/", flags: .directory, size: 0, mtime: 1, rootPath: "/"),
                   NameRecord(fileId: 50_000_000_000, parentId: 1, name: "far.txt", flags: [], size: 0, mtime: 1, rootPath: nil)]
    let snap = NameSnapshot.build(records, seq: 1, fingerprint: "t")
    #expect(snap.indexOfId.isEmpty && snap.index(of: 50_000_000_000) != nil && snap.index(of: 7) == nil)
    #expect(NameView(base: snap).search(NameQuery.parse("far", home: "/"), limit: 5).hits.first?.path == "/far.txt")
}

@Test func structureChecksRejectBrokenSnapshots() {
    #expect(treeIsConsistent(parents: [-1, 0, 1, 0], subtreeEnd: [4, 3, 3, 4]))
    #expect(!treeIsConsistent(parents: [-1, 0], subtreeEnd: [2, 3]), "past the end")
    #expect(!treeIsConsistent(parents: [-1, 0], subtreeEnd: [1, 2]), "child outside its parent's range")
    #expect(!treeIsConsistent(parents: [1, -1], subtreeEnd: [2, 2]), "child before its parent")
    #expect(offsetsAreConsistent([0, 2, 2, 5], byteCount: 5))
    #expect(!offsetsAreConsistent([0, 3, 2, 5], byteCount: 5) && !offsetsAreConsistent([1, 5], byteCount: 5) && !offsetsAreConsistent([0, 4], byteCount: 5))
}

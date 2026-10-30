import Foundation
import Testing
@testable import ContentEngine

func tempDir(_ label: String) -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xs-content-\(label)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    return url.path
}

func input(_ id: UInt64, _ text: String, dir: String = "/Users/t/下载", name: String? = nil) -> ContentInput {
    ContentInput(fileId: id, opSeq: 1, revision: 1, extractorVer: 1, scopeIds: [1], dir: dir, name: name ?? "doc-\(id).txt",
                 size: Int64(text.utf8.count), mtime: Int64(id), text: text, anchorsJson: #"[{"start":0,"kind":"paragraph","index":1}]"#,
                 pagesJson: "[]", state: .complete, extractKey: "k\(id)")
}

@Test func writeSearchPreviewThroughBindings() throws {
    let path = tempDir("rt")
    defer { try? FileManager.default.removeItem(atPath: path) }
    let writer = try ContentIndexWriter.open(path: path, newInstanceId: "inst-1")
    try writer.put(doc: input(1, "关于数据共享方案的说明😀，数据共享在第二段。"))
    try writer.put(doc: input(2, "Budget report 2026", dir: "/Work/A", name: "budget.docx"))
    try writer.put(doc: input(3, "将被删除的数据共享"))
    try writer.commit(batchId: 1)
    try writer.remove(fileId: 3, opSeq: 4)
    try writer.commit(batchId: 2)
    #expect(try writer.lastCommit()?.batchId == 2)
    #expect(try writer.appliedSeqs()[3] == 4)

    let index = try ContentIndex.open(path: path)
    #expect(try index.liveCount() == 2)
    let search = try index.search(query: "数据共享", mode: .loose, filters: SearchFilters(dirs: [], exts: [], scopes: []))
    #expect(search.recall() == .trigram)
    let batch = try search.next(budgetMs: 1000, maxHits: 50)
    #expect(batch.done)
    #expect(batch.hits.map(\.fileId) == [1])
    let hit = try #require(batch.hits.first)
    #expect(hit.hitCount == 2)
    let ns = hit.snippet as NSString
    for r in hit.snippetHighlights {
        #expect(ns.substring(with: NSRange(location: Int(r.start), length: Int(r.end - r.start))) == "数据共享")
    }
    // Preview highlights are NSString ranges over the stored text (emoji = 2 UTF-16 units).
    let doc = try #require(try index.document(fileId: 1))
    let full = doc.text as NSString
    let hl = try index.highlights(fileId: 1, query: "数据共享", mode: .loose)
    #expect(hl.count == 2)
    #expect(hl.allSatisfy { full.substring(with: NSRange(location: Int($0.start), length: Int($0.end - $0.start))) == "数据共享" })
    #expect(doc.anchorsJson.contains("paragraph"))

    // Filters and operators.
    let f = try index.search(query: "budget | 共享", mode: .loose, filters: SearchFilters(dirs: ["/work/a"], exts: ["DOCX"], scopes: []))
    #expect(try f.next(budgetMs: 1000, maxHits: 50).hits.map(\.fileId) == [2])
}

@Test func errorsAndCancellation() throws {
    let path = tempDir("err")
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(throws: EngineError.self) { _ = try ContentIndex.open(path: path) }
    let writer = try ContentIndexWriter.open(path: path, newInstanceId: "i")
    for i in 1...2000 { try writer.put(doc: input(UInt64(i), "文档 \(i) alpha beta")) }
    try writer.commit(batchId: 1)
    let index = try ContentIndex.open(path: path)
    do {
        _ = try index.search(query: "\"unclosed", mode: .loose, filters: SearchFilters(dirs: [], exts: [], scopes: []))
        Issue.record("expected a query error")
    } catch EngineError.Query {
    }
    let s = try index.search(query: "a", mode: .loose, filters: SearchFilters(dirs: [], exts: [], scopes: []))
    #expect(s.recall() == .scan)
    #expect(s.candidates() == 2000)
    // Cancel from another thread: later calls return without verifying more.
    let first = try s.next(budgetMs: 0, maxHits: 5)
    DispatchQueue.global().sync { s.cancel() }
    let after = try s.next(budgetMs: 1000, maxHits: 100_000)
    #expect(after.verified == first.verified && !after.done)
}

@Test func liveScanReadsTextFilesLikeTheIndex() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xs-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let utf8 = dir.appendingPathComponent("a.md").path
    try "会议纪要\n合同 金额 100 万元".write(toFile: utf8, atomically: true, encoding: .utf8)
    let gbk = dir.appendingPathComponent("b.txt").path
    let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    try "旧文件 合同 编号".data(using: String.Encoding(rawValue: gb))!.write(to: URL(fileURLWithPath: gbk))
    let binary = dir.appendingPathComponent("c.log").path
    try Data([0x63, 0, 0xE5, 0x90, 0x88]).write(to: URL(fileURLWithPath: binary))
    let scan = try LiveScan(query: "合同 -草稿", mode: .loose, maxFileBytes: 1 << 20)
    let a = try #require(scan.check(path: utf8))
    #expect(a.hitCount == 1 && a.snippet.contains("合同"))
    #expect(scan.check(path: gbk) != nil)
    #expect(scan.check(path: binary) == nil)
    #expect(try LiveScan(query: "合同", mode: .loose, maxFileBytes: 4).check(path: utf8) == nil)
    let p = try #require(scan.preview(path: utf8))
    #expect(p.highlights.count == 1 && (p.text as NSString).substring(with: NSRange(location: Int(p.highlights[0].start), length: 2)) == "合同")
}

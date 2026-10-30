import AppKit
import ContentEngine
import Foundation
import Testing
@testable import Catalog
import XSearchCore

final class IndexerLocator {}

var extractWorker: URL {
    Bundle(for: IndexerLocator.self).bundleURL.deletingLastPathComponent().appendingPathComponent("xs-extract")
}

/// Name service + indexer over one sandbox; content folder is `docs`.
final class Pipeline {
    let box: Sandbox
    let names: NameService
    var indexer: ContentIndexer

    init(_ label: String, configure: (ContentIndexer) -> Void = { _ in }) throws {
        box = try Sandbox(label)
        names = NameService(directory: box.data, home: "/nonexistent-home")
        indexer = ContentIndexer(directory: box.data, workerExecutable: extractWorker, workers: 2, environment: ["XS_EXTRACT_FAULTS": "1"])
        configure(indexer)
    }

    func start() throws {
        try FileManager.default.createDirectory(atPath: box.p("docs"), withIntermediateDirectories: true)
        names.start(scope: box.scope, content: ContentScope(folders: [box.p("docs")]))
        #expect(names.waitUntilIdle())
        try indexer.start()
    }

    func restartIndexer(configure: (ContentIndexer) -> Void = { _ in }) throws {
        indexer.stop()
        indexer = ContentIndexer(directory: box.data, workerExecutable: extractWorker, workers: 2, environment: ["XS_EXTRACT_FAULTS": "1"])
        configure(indexer)
        try indexer.start()
    }

    /// Catalog applied, every task finished (including back-off retries).
    func settle(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            names.waitUntilIdle(timeout: 5)
            indexer.waitUntilIdle(timeout: 5)
            if indexer.status.pending == 0 && names.contentTasks().isEmpty { return true }
            usleep(50_000)
        }
        return false
    }

    /// FSEvents arrive asynchronously: settle repeatedly until the condition holds.
    func until(timeout: TimeInterval = 20, _ condition: () throws -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            _ = settle(timeout: 5)
            if (try? condition()) == true { return true }
            usleep(100_000)
        }
        return false
    }

    func search(_ q: String, dirs: [String] = []) throws -> Set<String> {
        let index = try ContentIndex.open(path: indexer.indexURL.path)
        let s = try index.search(query: q, mode: .loose, filters: SearchFilters(dirs: dirs, exts: [], scopes: []))
        var out = Set<String>()
        while true {
            let b = try s.next(budgetMs: 1000, maxHits: 1000)
            out.formUnion(b.hits.map(\.name))
            if b.done { return out }
        }
    }

    func stop() {
        indexer.stop()
        names.shutdown()
    }
}

func writeDoc(_ path: String, _ text: String) throws {
    let s = NSAttributedString(string: text)
    try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat])
        .write(to: URL(fileURLWithPath: path))
}

func writePDF(_ path: String, _ text: String) {
    let out = NSMutableData()
    var media = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(consumer: CGDataConsumer(data: out)!, mediaBox: &media, nil)!
    ctx.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    (text as NSString).draw(at: NSPoint(x: 40, y: 740), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
    NSGraphicsContext.restoreGraphicsState()
    ctx.endPDFPage()
    ctx.closePDF()
    try! (out as Data).write(to: URL(fileURLWithPath: path))
}

@Test func endToEndNewFileSearchableAndUpdated() throws {
    let p = try Pipeline("e2e")
    defer { p.stop() }
    try p.box.write("docs/notes.txt", "会议纪要 纪要独有词 alpha")
    try writeDoc(p.box.p("docs/legacy.doc"), "旧版文档 合同金额 beta")
    writePDF(p.box.p("docs/scan.pdf"), "PDF 文字层 预算 gamma")
    try FileManager.default.copyItem(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Tests/Fixtures/m0/structure.docx").standardized.path,
                                     toPath: p.box.p("docs/structure.docx"))
    try p.box.write("docs/broken.docx", "not a zip")
    try p.box.write("outside.txt", "纪要独有词 outside")
    try p.start()
    #expect(p.settle())
    #expect(try p.search("纪要独有词") == ["notes.txt"])
    #expect(try p.search("合同金额") == ["legacy.doc"])
    #expect(try p.search("预算") == ["scan.pdf"])
    #expect(try !p.search("a").isEmpty)
    #expect(p.indexer.status.failed == 1, "broken.docx is recorded as failed")

    // New file → searchable; edit → old text gone; move → dir filter; delete → gone.
    try p.box.write("docs/new.md", "新建文件 delta")
    try "会议纪要 已修改 epsilon".write(toFile: p.box.p("docs/notes.txt"), atomically: true, encoding: .utf8)
    #expect(p.until { try p.search("delta") == ["new.md"] && p.search("epsilon") == ["notes.txt"] })
    #expect(try p.search("纪要独有词").isEmpty)
    try p.box.mkdir("docs/sub")
    try p.box.mv("docs/new.md", "docs/sub/new.md")
    try p.box.rm("docs/legacy.doc")
    #expect(p.until { try p.search("delta", dirs: [p.box.p("docs/sub")]) == ["new.md"] && p.search("合同金额").isEmpty })
    // Moved out of the content folder → removed from the content index.
    try p.box.mv("docs/sub/new.md", "moved-out.md")
    #expect(p.until { try p.search("delta").isEmpty })
}

@Test(arguments: ContentIndexer.Fault.allCases)
func crashAtEveryCommitStepRecovers(fault: ContentIndexer.Fault) throws {
    var armed = true
    let p = try Pipeline("crash-\(fault.rawValue)") { ix in
        ix.fault = { f in
            guard armed, f == fault else { return false }
            armed = false
            return true
        }
    }
    defer { p.stop() }
    for i in 1...6 { try p.box.write("docs/f\(i).txt", "文件\(i) 版本一 token\(i)a") }
    try p.start()
    // Wait for the simulated crash.
    let deadline = Date().addingTimeInterval(20)
    while p.indexer.status.running && Date() < deadline { usleep(20_000) }
    #expect(!p.indexer.status.running, "indexer crashed at \(fault)")
    // A change while the indexer is down.
    try "文件1 版本二 token1b".write(toFile: p.box.p("docs/f1.txt"), atomically: true, encoding: .utf8)
    try p.restartIndexer()
    #expect(p.until { try p.search("token1b") == ["f1.txt"] })
    #expect(try p.search("token1a").isEmpty, "old version must not survive")
    for i in 2...6 { #expect(try p.search("token\(i)a") == ["f\(i).txt"], "file \(i) after \(fault)") }
}

@Test func hungParserIsQuarantined() throws {
    let p = try Pipeline("hang") { ix in
        ix.baseTimeout = 0.4
        ix.backoffBase = 0.05
        ix.maxAttempts = 2
        ix.workerFault = { $0.hasSuffix("hang.txt") ? "hang" : nil }
    }
    defer { p.stop() }
    try p.box.write("docs/hang.txt", "永远卡住")
    try p.box.write("docs/fine.txt", "正常文件 omega")
    try p.start()
    #expect(p.settle(timeout: 30))
    #expect(try p.search("omega") == ["fine.txt"])
    #expect(try p.search("卡住").isEmpty)
    #expect(p.indexer.status.failed == 1)
}

@Test func changeDuringExtractionIsRetried() throws {
    var changed = false
    var box: Sandbox?
    let p = try Pipeline("midflight") { ix in
        ix.afterExtract = { path in
            guard !changed, path.hasSuffix("live.txt"), let box else { return }
            changed = true
            try? "第二版 newer".write(toFile: box.p("docs/live.txt"), atomically: false, encoding: .utf8)
        }
    }
    box = p.box
    defer { p.stop() }
    try p.box.write("docs/live.txt", "第一版 older")
    try p.start()
    #expect(p.settle())
    #expect(changed)
    #expect(try p.search("older").isEmpty)
    #expect(try p.search("newer") == ["live.txt"])
}

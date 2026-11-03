import AppKit
import Foundation
import Testing
@testable import Extraction

final class BundleLocator {}

/// `xs-extract` is built next to the test bundle.
var workerURL: URL {
    Bundle(for: BundleLocator.self).bundleURL.deletingLastPathComponent().appendingPathComponent("xs-extract")
}

func tmp(_ name: String) -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xs-extract-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name).path
}

/// Three pages: text, blank (no text layer), text.
func makePDF(_ path: String) {
    let out = NSMutableData()
    var media = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(consumer: CGDataConsumer(data: out)!, mediaBox: &media, nil)!
    for line in ["第一页 合同 数据共享 ABC", nil, "第三页 预算 2026"] as [String?] {
        ctx.beginPDFPage(nil)
        if let line {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (line as NSString).draw(at: NSPoint(x: 40, y: 740), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    try! (out as Data).write(to: URL(fileURLWithPath: path))
}

struct AnchorJSON: Decodable { var start: Int; var kind: String; var page: Int? }
struct PageJSON: Decodable { var page: Int; var state: String }

@Test func pdfPagesAnchorsAndStates() throws {
    let path = tmp("three.pdf")
    makePDF(path)
    let r = try Extractor.extract(path: path, limits: ExtractionLimits())
    #expect(r.method == "pdfkit")
    #expect(r.text.contains("数据共享") && r.text.contains("预算 2026"))
    let anchors = try JSONDecoder().decode([AnchorJSON].self, from: Data(r.anchorsJSON.utf8))
    #expect(anchors.map(\.page) == [1, 2, 3])
    // Anchor offsets are Unicode scalar offsets into the text.
    let scalars = Array(r.text.unicodeScalars)
    let third = String(String.UnicodeScalarView(scalars[anchors[2].start...]))
    #expect(third.hasPrefix("第三页"))
    let pages = try JSONDecoder().decode([PageJSON].self, from: Data(r.pagesJSON.utf8))
    #expect(pages.map(\.state) == ["complete", "waiting_ocr", "complete"])
    #expect(r.state == "partial")
    #expect(r.warnings.contains { $0.contains("1 页") })
}

@Test func docFallsBackToAttributedString() throws {
    let path = tmp("legacy.doc")
    let source = NSAttributedString(string: "旧版 Word 文档\n\n第二段 合同金额 100 万元\n")
    let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat])
    try data.write(to: URL(fileURLWithPath: path))
    let r = try Extractor.extract(path: path, limits: ExtractionLimits())
    // AppKit writes a MiniFAT our OLE reader refuses: the Word 97 reader fails, AppKit reads it.
    #expect(r.method == "nsattributedstring")
    #expect(r.extractorVersion == Extractor.docVersion)
    #expect(r.text.contains("第二段 合同金额 100 万元"))
    let anchors = try JSONDecoder().decode([AnchorJSON].self, from: Data(r.anchorsJSON.utf8))
    #expect(anchors.map(\.kind) == ["paragraph", "paragraph"])
}

@Test func textDocxAndRefusals() throws {
    let txt = tmp("notes.md")
    try "# 会议纪要\n数据共享方案".write(toFile: txt, atomically: true, encoding: .utf8)
    let r = try Extractor.extract(path: txt, limits: ExtractionLimits())
    #expect(r.method == "text/utf-8" && r.state == "complete")
    let docx = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Tests/Fixtures/m0/structure.docx").standardized.path
    let d = try Extractor.extract(path: docx, limits: ExtractionLimits())
    #expect(d.method == "docx" && !d.text.isEmpty && d.anchorsJSON.contains("paragraph"))
    #expect(throws: ExtractionError.unsupported("png")) { try Extractor.extract(path: tmp("a.png"), limits: ExtractionLimits()) }
    let pdf = tmp("big.pdf")
    makePDF(pdf)
    #expect(throws: ExtractionError.tooLarge(10)) { try Extractor.extract(path: pdf, limits: ExtractionLimits(maxFileBytes: 10)) }
}

@Test func workerExtractsAndSurvivesHangsAndCrashes() throws {
    #expect(FileManager.default.isExecutableFile(atPath: workerURL.path), "\(workerURL.path)")
    let worker = ExtractionWorker(executable: workerURL, environment: ["XS_EXTRACT_FAULTS": "1"])
    defer { worker.stop() }
    let txt = tmp("w.txt")
    try "工作进程 提取 测试".write(toFile: txt, atomically: true, encoding: .utf8)
    guard case .extracted(let r) = worker.extract(path: txt, limits: ExtractionLimits(), timeout: 10) else { Issue.record("no result"); return }
    #expect(r.text == "工作进程 提取 测试")
    let firstPid = worker.pid

    // Hung parser: killed at the timeout, not later.
    let start = Date()
    #expect(worker.extract(path: txt, limits: ExtractionLimits(), timeout: 0.5, fault: "hang") == .timedOut)
    #expect(Date().timeIntervalSince(start) < 3)
    if let firstPid { #expect(kill(firstPid, 0) != 0, "hung worker is gone") }

    // Crashing parser.
    #expect(worker.extract(path: txt, limits: ExtractionLimits(), timeout: 10, fault: "crash") == .crashed)

    // Errors for a single file don't kill the worker; next requests restart it as needed.
    #expect(worker.extract(path: tmp("missing.pdf"), limits: ExtractionLimits(), timeout: 10) != .crashed)
    guard case .extracted = worker.extract(path: txt, limits: ExtractionLimits(), timeout: 10) else { Issue.record("not restarted"); return }
    #expect(worker.restarts == 2)
}

@Test func slidesDispatchThroughRust() throws {
    let dir = tmp("deck")
    try? FileManager.default.removeItem(atPath: dir)
    try FileManager.default.createDirectory(atPath: dir + "/ppt/slides", withIntermediateDirectories: true)
    let slide = #"<p:sld xmlns:p="p" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:p><a:r><a:t>季度汇报 预算</a:t></a:r></a:p></p:sld>"#
    try slide.write(toFile: dir + "/ppt/slides/slide1.xml", atomically: true, encoding: .utf8)
    let pptx = tmp("deck.pptx")
    try? FileManager.default.removeItem(atPath: pptx)
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = URL(fileURLWithPath: dir)
    zip.arguments = ["-qr", pptx, "ppt"]
    try zip.run()
    zip.waitUntilExit()
    #expect(ExtractionKind.of(name: "deck.PPTX") == .slide && ExtractionKind.of(name: "a.xls") == .sheet && ExtractionKind.of(name: "a.ofd") == .ofd)
    let r = try Extractor.extract(path: pptx, limits: ExtractionLimits())
    #expect(r.method == "pptx" && r.text.contains("季度汇报 预算"))
    #expect(r.anchorsJSON.contains(#""kind":"slide""#) && r.anchorsJSON.contains(#""slide":1"#))
}

@Test func rtfAndHtmlDispatch() throws {
    let rtf = tmp("memo.rtf")
    let source = NSAttributedString(string: "备忘录\n\n合同金额 100 万元\n")
    let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    try data.write(to: URL(fileURLWithPath: rtf))
    let r = try Extractor.extract(path: rtf, limits: ExtractionLimits())
    #expect(r.method == "rtf" && r.text.contains("合同金额 100 万元") && r.anchorsJSON.contains("paragraph"))
    let html = tmp("page.HTML")
    try "<html><script>var a=1</script><body><h1>标题</h1><p>正文 &amp; 附件</p></body></html>".write(toFile: html, atomically: true, encoding: .utf8)
    let h = try Extractor.extract(path: html, limits: ExtractionLimits())
    #expect(h.method == "html/utf-8" && h.text == "标题\n正文 & 附件\n")
    #expect(ExtractionKind.of(name: "a.css") == .text && ExtractionKind.of(name: "b.epub") == .ebook)
}

@Test func archiveMembersGoThroughTheirExtractors() throws {
    let dir = tmp("pack")
    try? FileManager.default.removeItem(atPath: dir)
    try FileManager.default.createDirectory(atPath: dir + "/资料", withIntermediateDirectories: true)
    let docx = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Tests/Fixtures/m0/structure.docx").standardized.path
    try FileManager.default.copyItem(atPath: docx, toPath: dir + "/资料/结构.docx")
    try "包内文本 合同编号 HT-01\n".write(toFile: dir + "/说明.txt", atomically: true, encoding: .utf8)
    try "ignored".write(toFile: dir + "/图.png", atomically: true, encoding: .utf8)
    let zipPath = tmp("pack.zip")
    try? FileManager.default.removeItem(atPath: zipPath)
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = URL(fileURLWithPath: dir)
    zip.arguments = ["-qr", zipPath, "资料", "说明.txt", "图.png"]
    try zip.run()
    zip.waitUntilExit()
    let r = try Extractor.extract(path: zipPath, limits: ExtractionLimits())
    #expect(r.method == "archive" && r.state == "complete")
    #expect(r.text.contains("合同编号 HT-01"))
    let anchors = ((try JSONSerialization.jsonObject(with: Data(r.anchorsJSON.utf8))) as? [[String: Any]] ?? [])
    let members = anchors.filter { $0["kind"] as? String == "member" }.compactMap { $0["name"] as? String }
    #expect(Set(members) == ["资料/结构.docx", "说明.txt"])
    // The docx member's paragraphs keep their kind, shifted into the joined text.
    #expect(anchors.contains { $0["kind"] as? String == "paragraph" })
}

@Test func archiveWithIncompleteMemberIsPartial() throws {
    let dir = tmp("incomplete-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try "完整的文本".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    makePDF(dir + "/scan.pdf")  // has a page without a text layer
    let zipPath = dir + "/pack.zip"
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = URL(fileURLWithPath: dir)
    zip.arguments = ["-q", zipPath, "a.txt", "scan.pdf"]
    try zip.run()
    zip.waitUntilExit()
    let r = try Extractor.extract(path: zipPath, limits: ExtractionLimits())
    #expect(r.state == "partial")
    #expect(r.warnings.contains { $0.contains("scan.pdf") })
    #expect(r.text.contains("完整的文本"))
}

@Test func cancelThenStopNeverHangs() throws {
    let txt = tmp("cancel.txt")
    try "x".write(toFile: txt, atomically: true, encoding: .utf8)
    let start = Date()
    for i in 0..<60 {
        let worker = ExtractionWorker(executable: workerURL, environment: ["XS_EXTRACT_FAULTS": "1"])
        #expect(worker.extract(path: txt, limits: ExtractionLimits(), timeout: 10) != .crashed)
        // Vary the gap: the process may end just before, during or after `stop` looks at it.
        worker.cancel()
        if i % 3 == 1 { usleep(200) } else if i % 3 == 2 { usleep(2000) }
        worker.stop()
        #expect(worker.extract(path: txt, limits: ExtractionLimits(), timeout: 10) == .cancelled)
    }
    #expect(Date().timeIntervalSince(start) < 30)
}

@Test func workerOverItsMemoryLimitIsKilled() throws {
    let txt = tmp("hog.txt")
    try "x".write(toFile: txt, atomically: true, encoding: .utf8)
    let worker = ExtractionWorker(executable: workerURL, environment: ["XS_EXTRACT_FAULTS": "1"])
    defer { worker.stop() }
    worker.memoryLimit = 100 << 20
    #expect(worker.extract(path: txt, limits: ExtractionLimits(), timeout: 20, fault: "hog") == .tooMuchMemory)
    #expect(worker.extract(path: txt, limits: ExtractionLimits(), timeout: 10) != .crashed, "the next file gets a new process")
}

@Test func everyKindRespectsTheTextBudget() throws {
    let limits = ExtractionLimits(maxFileBytes: 1 << 20, maxUnpackedBytes: 40)
    // Plain RTF, more text than the budget; 中 is three bytes, so the cut lands inside a character.
    let rtf = tmp("budget-\(UUID().uuidString).rtf")
    let long = NSAttributedString(string: String(repeating: "中文段落内容\n", count: 50))
    try long.rtf(from: NSRange(location: 0, length: long.length))!.write(to: URL(fileURLWithPath: rtf))
    let r = try Extractor.extract(path: rtf, limits: limits)
    #expect(r.text.utf8.count <= 40 && !r.text.isEmpty)
    #expect(r.state == "partial" && r.warnings.contains { $0.contains("超过上限") })
    let anchors = try JSONSerialization.jsonObject(with: Data(r.anchorsJSON.utf8)) as! [[String: Any]]
    #expect(anchors.allSatisfy { ($0["start"] as! Int) < r.text.unicodeScalars.count })
    // PDF: stops between pages.
    let pdf = tmp("budget-\(UUID().uuidString).pdf")
    makePDF(pdf)
    let p = try Extractor.extract(path: pdf, limits: ExtractionLimits(maxFileBytes: 1 << 20, maxUnpackedBytes: 10))
    #expect(p.text.utf8.count <= 10 && p.state == "partial")
    // Enough room: untouched.
    let whole = try Extractor.extract(path: pdf, limits: ExtractionLimits())
    #expect(whole.text.utf8.count > 10 && !whole.warnings.contains { $0.contains("超过上限") })
}

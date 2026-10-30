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

@Test func docViaAttributedString() throws {
    let path = tmp("legacy.doc")
    let source = NSAttributedString(string: "旧版 Word 文档\n\n第二段 合同金额 100 万元\n")
    let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat])
    try data.write(to: URL(fileURLWithPath: path))
    let r = try Extractor.extract(path: path, limits: ExtractionLimits())
    #expect(r.method == "nsattributedstring")
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

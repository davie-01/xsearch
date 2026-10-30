import Foundation
import Testing
@testable import NameEngine
import XSearchCore

/// Engine-only latency on 1,000,000 synthetic entries (ARCHITECTURE §19: input → first screen
/// P95 < 80 ms, engine time recorded separately). Opt-in: `XS_BENCH=1 scripts/swift-test.sh -c release --filter Bench`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["XS_BENCH"] == "1"))
func benchMillionEntries() throws {
    var rng = Rng(state: 42)
    var records: [NameRecord] = [NameRecord(fileId: 1, parentId: 0, name: "/", flags: .directory, size: 0, mtime: 0, rootPath: "/")]
    var dirs: [Int64] = [1]
    let words = ["报告", "report", "合同", "数据共享", "invoice", "IMG", "notes", "设计稿", "Café", "budget"]
    let exts = ["pdf", "docx", "txt", "jpg", "xlsx", "md", "swift", "png"]
    var id: Int64 = 1
    while records.count < 1_000_000 {
        id += 1
        let parent = dirs[rng.int(dirs.count)]
        if rng.int(8) == 0 {
            records.append(NameRecord(fileId: id, parentId: parent, name: "\(words[rng.int(words.count)])-\(rng.int(500))", flags: .directory, size: 0, mtime: Int64(rng.int(1_000_000))))
            dirs.append(id)
        } else {
            records.append(NameRecord(fileId: id, parentId: parent, name: "\(words[rng.int(words.count)])_\(rng.int(100_000)).\(exts[rng.int(exts.count)])", flags: [], size: 1, mtime: Int64(rng.int(1_000_000))))
        }
    }
    let t0 = Date()
    let base = NameSnapshot.build(records, seq: 1, fingerprint: "b")
    let buildMs = Date().timeIntervalSince(t0) * 1000
    var view = NameView(base: base)
    let overlay = (0..<2000).map { i -> NameChange in
        var r = records[1 + rng.int(records.count - 1)]
        r.name = "renamed-\(i).pdf"
        return .upsert(r)
    }
    view = view.applying(overlay)
    let queries = ["报", "报告", "report", "rep", "2024", "_1", "café", "数据共享 pdf", "ext:pdf 合同", "kind:folder 设计", "不存在的名字"]
    var lines: [String] = ["build \(Int(buildMs)) ms, memory \(base.memoryBytes / 1_048_576) MB, overlay \(view.overlayCount)"]
    var worstP95 = 0.0
    for text in queries {
        let q = NameQuery.parse(text, home: "/")
        var samples: [Double] = []
        var total = 0
        for _ in 0..<15 {
            let s = Date()
            total = view.search(q, limit: 200).total
            samples.append(Date().timeIntervalSince(s) * 1000)
        }
        samples.sort()
        let p50 = samples[samples.count / 2], p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        worstP95 = max(worstP95, p95)
        lines.append(String(format: "%-14@ hits %7d  p50 %6.1f ms  p95 %6.1f ms", text as NSString, total, p50, p95))
    }
    print(lines.joined(separator: "\n"))
    #expect(worstP95 < 80, "engine P95 \(worstP95) ms")
}

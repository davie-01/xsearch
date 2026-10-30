import ContentEngine
import Foundation
import XSearchCore

/// Archives (M4-2): Rust unpacks the members of extractable types into a scratch folder, each
/// member goes through the ordinary extractors (PDF and .doc are Swift-only), and the texts
/// are joined in archive order as one document. Every member starts with a part anchor named
/// after its path; its own anchors become "名称 · 第 3 页" parts. One level deep: archives
/// inside archives are skipped.
extension Extractor {
    public static var archiveVersion: UInt64 { engineVersions()["extractor.archive"].flatMap(UInt64.init) ?? 1 }

    static let memberLimit: UInt32 = 5000

    static func archive(_ path: String, limits: ExtractionLimits) throws -> ExtractionResult {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xs-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let extensions = ContentType.allCases.filter { $0 != .archive }.flatMap(\.extensions)
        let listing: ArchiveListing
        do {
            listing = try unpackArchive(path: path, dest: scratch.path, extensions: extensions, maxMemberBytes: limits.maxFileBytes,
                                        maxTotalBytes: limits.maxUnpackedBytes, maxMembers: memberLimit)
        } catch let e as EngineError {
            throw ExtractionError.unreadable("\(e)")
        }
        // Stay well inside the worker's timeout (30 s + 2 s per MB): stop with a partial result.
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        let deadline = Date().addingTimeInterval(20 + 1.5 * Double(size >> 20))
        var text = ""
        var scalars = 0
        var anchors: [[String: Any]] = []
        var warnings = listing.warnings
        var failed = 0, timedOut = false
        for m in listing.members {
            if Date() > deadline { timedOut = true; break }
            guard let r = try? extract(path: m.extractedPath, limits: limits) else { failed += 1; continue }
            try? FileManager.default.removeItem(atPath: m.extractedPath)
            if r.text.isEmpty { continue }
            let short = (m.name as NSString).lastPathComponent
            anchors.append(["start": scalars, "kind": "part", "name": m.name])
            for a in (try? JSONSerialization.jsonObject(with: Data(r.anchorsJSON.utf8)) as? [[String: Any]]) ?? [] {
                guard let start = a["start"] as? Int, let label = anchorLabel(a) else { continue }
                anchors.append(["start": scalars + start, "kind": "part", "name": "\(short) · \(label)"])
            }
            text += r.text
            scalars += r.text.unicodeScalars.count
            if !r.text.hasSuffix("\n") { text += "\n"; scalars += 1 }
        }
        if failed > 0 { warnings.append("\(failed) 个文件无法提取") }
        if timedOut { warnings.append("压缩包处理超时，后续文件未读取") }
        let partial = failed > 0 || timedOut || listing.truncated || listing.encrypted > 0 || listing.skippedTooLarge > 0
        return ExtractionResult(text: text, anchorsJSON: json(anchors), pagesJSON: "[]", state: partial ? "partial" : "complete",
                                warnings: warnings, method: "archive", extractorVersion: archiveVersion)
    }

    /// Gutter-style label of a member's anchor (the leading anchor at 0 adds nothing).
    static func anchorLabel(_ a: [String: Any]) -> String? {
        switch a["kind"] as? String {
        case "page": (a["page"] as? Int).map { "第 \($0) 页" }
        case "paragraph": (a["index"] as? Int).map { "段 \($0)" }
        case "line": (a["line"] as? Int).map { "行 \($0)" }
        case "cell": "表 \(a["table"] as? Int ?? 0)·\(a["cell"] as? String ?? "")"
        case "sheet": "\(a["sheet"] as? String ?? "")!\(a["cell"] as? String ?? "")"
        case "slide": (a["slide"] as? Int).map { "幻灯片 \($0)" }
        case "part": a["name"] as? String
        default: nil
        }
    }
}

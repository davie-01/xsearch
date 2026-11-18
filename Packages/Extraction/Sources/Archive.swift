import ContentEngine
import Foundation
import XSearchCore

/// Archives (M4-2): Rust unpacks the members of extractable types into a scratch folder, each
/// member goes through the ordinary extractors (PDF and .doc are Swift-only), and the texts
/// are joined in archive order as one document. Every member starts with a `member` anchor
/// (search returns one hit per matching member) followed by its own anchors, shifted. One
/// level deep: archives inside archives are skipped.
extension Extractor {
    public static var archiveVersion: UInt64 { engineVersions()["extractor.archive"].flatMap(UInt64.init) ?? 1 }

    static let memberLimit: UInt32 = 5000
    static let scratchPrefix = "xs-archive-"

    /// A worker killed in the middle of an archive (timeout, memory, crash) never runs its
    /// `defer`, so its scratch directory stays behind. Removed once no extraction can still be
    /// using it: older than any extraction's time limit.
    public static func removeStaleArchiveScratch(olderThan age: TimeInterval = 3600) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-age)
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(scratchPrefix) {
            let url = tmp.appendingPathComponent(name)
            if let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    static func archive(_ path: String, limits: ExtractionLimits) throws -> ExtractionResult {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(scratchPrefix + UUID().uuidString, isDirectory: true)
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
        var failed = 0, incomplete = 0, timedOut = false, full = false
        for m in listing.members {
            if Date() > deadline { timedOut = true; break }
            // Members are small on disk but can unfold into much more text.
            if text.utf8.count >= limits.maxUnpackedBytes { full = true; break }
            guard let r = try? extract(path: m.extractedPath, limits: limits) else { failed += 1; continue }
            try? FileManager.default.removeItem(atPath: m.extractedPath)
            if r.state != "complete" {
                incomplete += 1
                if incomplete <= 20, let w = r.warnings.first { warnings.append("\(m.name)：\(w)") }
            }
            if r.text.isEmpty { continue }
            // A member marker (search splits the document into one hit per member), then the
            // member's own anchors, shifted, with their kinds kept (page, paragraph, sheet…).
            anchors.append(["start": scalars, "kind": "member", "name": m.name])
            for a in (try? JSONSerialization.jsonObject(with: Data(r.anchorsJSON.utf8)) as? [[String: Any]]) ?? [] {
                guard let start = a["start"] as? Int else { continue }
                var shifted = a
                shifted["start"] = scalars + start
                anchors.append(shifted)
            }
            text += r.text
            scalars += r.text.unicodeScalars.count
            if !r.text.hasSuffix("\n") { text += "\n"; scalars += 1 }
        }
        if failed > 0 { warnings.append("\(failed) 个文件无法提取") }
        if incomplete > 0 { warnings.append("\(incomplete) 个文件只提取了一部分") }
        if full { warnings.append("压缩包正文超过上限，后续文件未读取") }
        if timedOut { warnings.append("压缩包处理超时，后续文件未读取") }
        let partial = failed > 0 || incomplete > 0 || full || timedOut || listing.truncated || listing.encrypted > 0 || listing.unreadable > 0 || listing.skippedTooLarge > 0
        return ExtractionResult(text: text, anchorsJSON: json(anchors), pagesJSON: "[]", state: partial ? "partial" : "complete",
                                warnings: warnings, method: "archive", extractorVersion: archiveVersion)
    }
}

import AppKit
import ContentEngine
import Extraction
import UniformTypeIdentifiers
import XSearchCore

/// Archive members as their own results (M4 backlog): the engine returns one hit per matching
/// member, carrying the member path; the archive stays the file on disk.
extension ContentHit {
    /// The file on disk (the archive for a member).
    var path: String { dir + "/" + name }
    var isMember: Bool { !member.isEmpty }
    var displayName: String { isMember ? (member as NSString).lastPathComponent : name }
    /// "~/下载/资料.zip › 合同/2024" for a member, the folder otherwise.
    var displayLocation: String {
        let home = NSHomeDirectory()
        guard isMember else { return PathUtil.abbreviate(dir, home: home) }
        let inner = (member as NSString).deletingLastPathComponent
        return PathUtil.abbreviate(path, home: home) + (inner.isEmpty ? "" : " › " + inner)
    }
    /// Unique per result: one archive yields several.
    var key: String { isMember ? path + "!/" + member : path }

    @MainActor var icon: NSImage {
        guard isMember else { return NSWorkspace.shared.icon(forFile: path) }
        let ext = (member as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

@MainActor
enum MemberOpener {
    private static let queue = DispatchQueue(label: "xsearch.member-open", qos: .userInitiated)

    /// Unpacking runs in the extraction worker, not in the app: a damaged archive (or a solid
    /// 7z read up to a late member) costs that process, which is killed past its time or memory.
    /// Started for each open and stopped after it, so nothing stays running in between.
    nonisolated private static let worker: ExtractionWorker = {
        let w = ExtractionWorker(executable: Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("xs-extract"))
        w.memoryLimit = 1 << 30
        return w
    }()

    /// Unpacks the member to a private temporary folder (up to 512 MB) and opens it with its
    /// default app. `done` gets a message when that fails.
    static func open(_ hit: ContentHit, done: @escaping @MainActor @Sendable (String?) -> Void = { _ in }) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("XSearch-open/\(UUID().uuidString)", isDirectory: true)
        let path = hit.path, member = hit.member, name = hit.displayName
        queue.async {
            let reason: String
            do {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                // As for indexing: 30 s plus 2 s per MB of archive, at most 5 minutes.
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                let timeout = min(300, 30 + 2 * Double(size >> 20))
                let outcome = worker.extractMember(path: path, member: member, dest: dest.path, maxBytes: 512 << 20, timeout: timeout)
                worker.stop()
                switch outcome {
                case .unpacked(let file):
                    DispatchQueue.main.async {
                        NSWorkspace.shared.openInBackground(URL(fileURLWithPath: file))
                        done(nil)
                    }
                    return
                case .notUnpacked(.timedOut): reason = L("解压超时，已停止")
                case .notUnpacked(.tooMuchMemory): reason = L("解压占用内存过多，已停止")
                case .notUnpacked(.failed(let message)): reason = message
                case .notUnpacked: reason = L("解压进程意外结束")
                }
            } catch {
                reason = "\(error)"
            }
            try? FileManager.default.removeItem(at: dest)
            let message = L("无法从压缩包中取出“%@”：%@", "\(name)", reason)
            DispatchQueue.main.async { done(message) }
        }
    }

    static let notAlone = L("压缩包内的文件不能单独收藏或移到废纸篓")

    /// Members opened from archives live in $TMPDIR/XSearch-open/<uuid>; an app may still have
    /// today's open, so only folders older than a day are removed (at launch).
    static func removeOldExtractions() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XSearch-open")
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            let url = root.appendingPathComponent(name)
            if let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

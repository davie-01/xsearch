import AppKit
import ContentEngine
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
    /// Unpacks the member to a private temporary folder and opens it with its default app.
    /// Returns a message when that fails.
    static func open(_ hit: ContentHit) -> String? {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("XSearch-open/\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = try extractArchiveMember(path: hit.path, member: hit.member, dest: dest.path, maxMemberBytes: 512 << 20)
            NSWorkspace.shared.open(URL(fileURLWithPath: file))
            return nil
        } catch {
            return "无法从压缩包中取出“\(hit.displayName)”：\(error)"
        }
    }

    static let notAlone = "压缩包内的文件不能单独收藏或移到废纸篓"

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

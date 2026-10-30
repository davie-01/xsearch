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

extension PreviewData {
    /// Only the member's part of an archive document: text, highlights and anchors shifted to
    /// start at 0 (the member's own anchors keep their kinds; member markers are dropped).
    func member(_ name: String, startingAt start: UInt32) -> PreviewData {
        let slice = memberSlice(text: document.text, anchorsJson: document.anchorsJson, highlights: highlights, start: start)
        var doc = document
        doc.text = slice.text
        doc.anchorsJson = slice.anchorsJson
        doc.name = (name as NSString).lastPathComponent
        return PreviewData(document: doc, highlights: slice.highlights)
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
}

import Foundation

/// Settings › 隐私与数据 (STORAGE.md): what the data directory holds, by kind, and the leftovers
/// that can go at any time.
public struct IndexStorage: Sendable, Equatable {
    /// `catalog.sqlite*` and the `names/` snapshot.
    public var names: Int64 = 0
    /// `content/`: every instance, a rebuild's included.
    public var content: Int64 = 0
    /// `user.sqlite*`: recents and favorites, never removed with an index.
    public var personal: Int64 = 0
    /// `retired-*` in the data directory, and in the temporary directory archive members opened
    /// from results (`XSearch-open/`) and unpacked archives (`xs-archive-*`).
    public var leftovers: Int64 = 0

    public init() {}

    public var total: Int64 { names + content + personal + leftovers }

    /// Temporary leftovers younger than this may still be in use (an app showing an opened
    /// member, an archive being indexed) and are neither counted nor removed.
    public static let leftoverAge: TimeInterval = 3600

    /// Walks the directories (allocated sizes); call it off the main thread.
    public static func measure(in directory: URL, temporary: URL = FileManager.default.temporaryDirectory, now: Date = Date()) -> IndexStorage {
        var s = IndexStorage()
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let size = allocated(directory.appendingPathComponent(name))
            if name.hasPrefix("catalog.sqlite") || name == "names" {
                s.names += size
            } else if name == "content" {
                s.content += size
            } else if name.hasPrefix("user.sqlite") {
                s.personal += size
            } else if name.hasPrefix("retired-") {
                s.leftovers += size
            }
        }
        for url in temporaryLeftovers(temporary, now: now) { s.leftovers += allocated(url) }
        return s
    }

    /// Removes the leftovers `measure` counts. Indexes and personal data stay.
    public static func removeLeftovers(in directory: URL, temporary: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        IndexFiles.removeRetired(in: directory)
        for url in temporaryLeftovers(temporary, now: now) { try? FileManager.default.removeItem(at: url) }
    }

    private static func temporaryLeftovers(_ tmp: URL, now: Date) -> [URL] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-leftoverAge)
        func old(_ url: URL) -> Bool {
            ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now) < cutoff
        }
        let open = tmp.appendingPathComponent("XSearch-open")
        let opened = ((try? fm.contentsOfDirectory(atPath: open.path)) ?? []).map { open.appendingPathComponent($0) }
        let unpacked = ((try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []).filter { $0.hasPrefix("xs-archive-") }.map { tmp.appendingPathComponent($0) }
        return (opened + unpacked).filter(old)
    }

    static func allocated(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let item = e?.nextObject() as? URL {
            if let r = try? item.resourceValues(forKeys: keys), r.isDirectory != true {
                total += Int64(r.totalFileAllocatedSize ?? r.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

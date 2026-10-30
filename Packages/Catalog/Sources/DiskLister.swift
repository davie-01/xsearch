import CScan
import Foundation
import NameEngine
import XSearchCore

struct DiskEntry {
    var name: String
    var type: UInt32
    var dev: Int64
    var ino: Int64
    var birthNs: Int64
    var mtimeNs: Int64
    var size: Int64
    var hidden: Bool
    var bundleBit: Bool
    var isMount: Bool

    var isDirectory: Bool { type == UInt32(XS_TYPE_DIR) }
    var isSymlink: Bool { type == UInt32(XS_TYPE_SYMLINK) }

    init(_ e: xs_entry, name: String) {
        self.name = name
        type = e.type
        dev = Int64(e.dev)
        ino = Int64(bitPattern: e.ino)
        birthNs = e.birth_ns
        mtimeNs = e.mtime_ns
        size = e.size
        // System apps in /Applications (Safari, …) are UF_HIDDEN symlinks into the cryptex that
        // Finder still shows; treat `.app` symlinks as visible like Finder does.
        let flaggedHidden = (e.bsd_flags & UInt32(UF_HIDDEN)) != 0 || (e.finder_flags & 0x4000) != 0
        let appLink = e.type == UInt32(XS_TYPE_SYMLINK) && name.lowercased().hasSuffix(".app")
        hidden = name.hasPrefix(".") || (flaggedHidden && !appLink)
        bundleBit = (e.finder_flags & 0x2000) != 0
        isMount = e.is_mount != 0
    }

    /// Packages are shown as one item; their contents are not indexed unless the scope says so.
    var isPackage: Bool {
        guard isDirectory else { return false }
        if bundleBit { return true }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return DiskEntry.packageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc", "photoslibrary", "musiclibrary",
        "tvlibrary", "rtfd", "pages", "numbers", "key", "xcodeproj", "xcworkspace", "playground", "dsym",
        "logicx", "band", "fcpbundle", "imovielibrary", "photolibrary", "aplibrary", "scriptd", "mdimporter",
        "qlgenerator", "prefpane", "saver", "wdgt", "lpdf", "pkg", "mpkg",
    ]

    var flags: EntryFlags {
        var f: EntryFlags = []
        if isDirectory { f.insert(.directory) }
        if isPackage { f.insert(.package) }
        if isSymlink { f.insert(.symlink) }
        return f
    }
}

enum DiskLister {
    final class Box { var entries: [DiskEntry] = [] }

    /// Lists a directory (no symlink following). Returns entries or an errno.
    static func list(_ path: String) -> Result<[DiskEntry], POSIXError> {
        let box = Box()
        let rc = path.withCString { cpath in
            xs_list_dir(cpath, { ctx, e in
                guard let ctx, let e else { return 0 }
                let box = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                let name = String(cString: e.pointee.name)
                // `.` / `..` are never returned by getattrlistbulk; skip types we do not index.
                if e.pointee.type != UInt32(XS_TYPE_OTHER) { box.entries.append(DiskEntry(e.pointee, name: name)) }
                return 0
            }, Unmanaged.passUnretained(box).toOpaque())
        }
        if rc != 0 { return .failure(POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)) }
        return .success(box.entries)
    }

    /// Where an inode lives now, in the catalog's "/" view; nil when it no longer exists.
    static func currentPath(ino: Int64, onVolumeOf path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        let rc = path.withCString { xs_path_for_inode($0, UInt64(bitPattern: ino), &buf, buf.count) }
        guard rc == 0 else { return nil }
        let raw = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return NameService.canonicalEventPath(raw)
    }

    static func stat(_ path: String) -> Result<DiskEntry, POSIXError> {
        var e = xs_entry()
        var buf = [CChar](repeating: 0, count: 1024)
        let rc = path.withCString { xs_stat_path($0, &e, &buf, buf.count) }
        if rc != 0 { return .failure(POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)) }
        let name = e.name.map { String(cString: $0) } ?? (path as NSString).lastPathComponent
        return .success(DiskEntry(e, name: name))
    }
}

/// Lists directories on a small thread pool so a recursive scan is not bound by one thread's
/// metadata latency. Results come back in completion order; the single writer applies them.
final class ParallelLister: @unchecked Sendable {
    struct Job { var id: Int64; var path: String; var fresh: Bool; var recursive: Bool }
    struct Output { var job: Job; var result: Result<[DiskEntry], POSIXError> }

    private let queue = DispatchQueue(label: "xsearch.lister", qos: .utility, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 8)
    private let lock = NSCondition()
    private var done: [Output] = []
    private(set) var pending = 0

    func submit(_ job: Job) {
        pending += 1
        queue.async { [self] in
            slots.wait()
            let result = DiskLister.list(job.path)
            slots.signal()
            lock.lock()
            done.append(Output(job: job, result: result))
            lock.signal()
            lock.unlock()
        }
    }

    /// Blocks for the next finished listing; nil when nothing is outstanding.
    func next() -> Output? {
        guard pending > 0 else { return nil }
        lock.lock()
        while done.isEmpty { lock.wait() }
        let out = done.removeLast()  // order does not matter; ids are already assigned
        lock.unlock()
        pending -= 1
        return out
    }
}

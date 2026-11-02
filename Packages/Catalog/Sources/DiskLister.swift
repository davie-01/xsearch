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

    struct Listing {
        var entries: [DiskEntry]
        /// Some entries could not be read: one missing from `entries` may still exist.
        var incomplete: Bool
    }

    /// Test hook: pretend the kernel reported an error for entries with these names.
    nonisolated(unsafe) static var unreadableForTests: (@Sendable (String) -> Bool)?

    /// Lists a directory (no symlink following). Returns entries or an errno.
    static func list(_ path: String) -> Result<Listing, POSIXError> {
        let box = Box()
        var skipped: Int32 = 0
        let rc = path.withCString { cpath in
            xs_list_dir(cpath, { ctx, e in
                guard let ctx, let e else { return 0 }
                let box = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                let name = String(cString: e.pointee.name)
                // `.` / `..` are never returned by getattrlistbulk; skip types we do not index.
                if e.pointee.type != UInt32(XS_TYPE_OTHER) { box.entries.append(DiskEntry(e.pointee, name: name)) }
                return 0
            }, Unmanaged.passUnretained(box).toOpaque(), &skipped)
        }
        if rc != 0 { return .failure(POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)) }
        if let unreadable = unreadableForTests {
            let kept = box.entries.filter { !unreadable($0.name) }
            if kept.count != box.entries.count { skipped += 1 }
            box.entries = kept
        }
        return .success(Listing(entries: box.entries, incomplete: skipped > 0))
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

/// Process-wide pool of dedicated threads for blocking directory listings. Not GCD: the
/// reconcilers that wait for listings run on GCD threads themselves, and many of them blocking
/// at once could exhaust GCD's thread limit so the listings never get a thread (deadlock).
final class ListingPool: @unchecked Sendable {
    static let shared = ListingPool(threads: 8)
    private let cond = NSCondition()
    private var jobs: [() -> Void] = []

    init(threads: Int) {
        for i in 0..<threads {
            let t = Thread { [unowned self] in self.loop() }
            t.name = "xsearch.lister.\(i)"
            t.qualityOfService = .utility
            t.start()
        }
    }

    func run(_ job: @escaping () -> Void) {
        cond.lock()
        jobs.append(job)
        cond.signal()
        cond.unlock()
    }

    private func loop() {
        while true {
            cond.lock()
            while jobs.isEmpty { cond.wait() }
            let job = jobs.removeFirst()
            cond.unlock()
            job()
        }
    }
}

/// Lists directories in parallel on `ListingPool` so a recursive scan is not bound by one
/// thread's metadata latency. Results come back in completion order; the single writer
/// applies them.
final class ParallelLister: @unchecked Sendable {
    struct Job { var id: Int64; var path: String; var fresh: Bool; var recursive: Bool }
    struct Output { var job: Job; var result: Result<DiskLister.Listing, POSIXError> }

    private let lock = NSCondition()
    private var done: [Output] = []
    private(set) var pending = 0

    func submit(_ job: Job) {
        pending += 1
        ListingPool.shared.run { [self] in
            let result = DiskLister.list(job.path)
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

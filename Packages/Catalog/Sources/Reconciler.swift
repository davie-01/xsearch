import Foundation
import NameEngine
import XSearchCore

/// Applies a batch of journal operations to the catalog by re-reading the affected directories
/// (ARCHITECTURE §9). Replay is idempotent: every decision comes from comparing the disk with
/// the catalog, never from trusting event flags. Identity rules:
/// - same name, same type: same file; a new inode there is an atomic save (id kept);
/// - a name that disappeared and a name that appeared with the same (dev, inode) and type is a
///   rename/move (id kept, a directory's subtree follows because children reference its id);
/// - a listing failure is never treated as an empty directory (§9.2): children are kept.
final class Reconciler {
    struct Context {
        /// What is scanned: the union of the name roots and the content roots.
        var roots: [String]
        var nameRoots: [String]
        var rules: ExclusionRules
        var home: String
        /// nil: content indexing off.
        var content: ContentRules?
    }

    struct Task {
        var id: Int64
        var path: String
        var recursive: Bool
    }

    private let catalog: FileCatalog
    private let ctx: Context
    private let seq: Int64
    private let publish: ([NameChange]) -> Void
    private let lister = ParallelLister()
    private var changes: [NameChange] = []
    private var writesSinceCommit = 0
    /// Listings queued and not yet applied.
    private var inFlight: [Int64: Bool] = [:]
    /// Successful listings: id → (path listed at, recursive).
    private var done: [Int64: (path: String, recursive: Bool)] = [:]
    /// Requests that arrived while a weaker listing of the same directory was in flight.
    private var deferred: [Int64: Task] = [:]
    private var submissions = 0
    private var vanished: [Int64: Row] = [:]
    private var pendingNew: [(parent: Row, parentPath: String, entry: DiskEntry)] = []
    /// Directories whose listing failed with ENOENT: possibly moved within this batch.
    private var missing = Set<Int64>()
    /// Path each missing directory was last listed at; retried whenever its path changes.
    private var triedPath: [Int64: String] = [:]
    /// Event paths that only resolved to an ancestor (part of the path is not catalogued yet,
    /// e.g. the directory was renamed in this batch). Re-planned after each round of moves.
    private var unresolved: [(path: String, recursive: Bool)] = []
    /// Directory each vanished row was last seen in (to find its volume for fsgetpath).
    private var vanishedIn: [Int64: String] = [:]
    private var chased = Set<Int64>()
    private var inTransaction = false
    /// Content bookkeeping, settled into tasks before each commit (same transaction).
    private var contentTouched = Set<Int64>()
    private var contentRemoved = Set<Int64>()
    private var movedDirs = Set<Int64>()
    private var refreshAllContent = false
    private var opCounter: Int64?
    /// Content tasks written in this batch (tests, status).
    private(set) var tasksWritten = 0
    /// Entries written to the catalog in this batch (status display).
    private(set) var touched = 0

    /// Commit and publish every this many writes, so huge rescans neither hold one giant
    /// transaction nor publish nothing until the end. The watermark only moves at the very end.
    static let chunk = 20_000

    init(catalog: FileCatalog, context: Context, seq: Int64, publish: @escaping ([NameChange]) -> Void) {
        self.catalog = catalog
        ctx = context
        self.seq = seq
        self.publish = publish
    }

    func run(_ ops: [JournalOp]) throws {
        try begin()
        do {
            var tasks: [Int64: Task] = [:]
            for op in ops { try expand(op, into: &tasks) }
            for t in tasks.values { submit(t) }
            try drain()
            // A directory renamed in this batch fails to list at its old path, and events under
            // its new path resolve only to an ancestor. Each round matches moves, then lists what
            // that made reachable; stop when a round finds nothing new to list.
            for _ in 0..<64 {
                let before = submissions
                try resolvePending()
                try chaseVanished()
                try resubmitMissing()
                try replanUnresolved()
                if submissions == before && pendingNew.isEmpty { break }
                try drain()
            }
            try deleteVanished()
            try catalog.setConsumer(FileCatalog.nameConsumer, seq)
            try commit()
        } catch {
            if inTransaction { try? catalog.db.exec("ROLLBACK"); inTransaction = false }
            throw error
        }
    }

    // MARK: Transactions

    private func begin() throws {
        try catalog.db.exec("BEGIN IMMEDIATE")
        inTransaction = true
    }

    private func commit() throws {
        try settleContent()
        try catalog.db.exec("COMMIT")
        catalog.db.resetStatements()
        inTransaction = false
        if !changes.isEmpty { publish(changes); changes.removeAll(keepingCapacity: true) }
        writesSinceCommit = 0
    }

    private func wrote(_ change: NameChange) throws {
        switch change {
        case .upsert(let r): if !r.flags.contains(.directory) { contentTouched.insert(r.fileId) }
        case .remove(let id): contentRemoved.insert(id)
        }
        changes.append(change)
        writesSinceCommit += 1
        touched += 1
        if writesSinceCommit >= Self.chunk {
            try commit()
            try begin()
        }
    }

    // MARK: Planning

    private func root(containing path: String) throws -> Row? {
        let roots = try catalog.rootRows().filter { r in ctx.roots.contains(r.name) && PathUtil.isWithin(path, r.name) }
        return roots.max { $0.name.count < $1.name.count }
    }

    private func addTask(_ t: Task, _ tasks: inout [Int64: Task]) {
        if let existing = tasks[t.id] { tasks[t.id]?.recursive = existing.recursive || t.recursive } else { tasks[t.id] = t }
    }

    private func expand(_ op: JournalOp, into tasks: inout [Int64: Task]) throws {
        switch op.kind {
        case .scope:
            refreshAllContent = true
            try syncRoots()
            for r in try catalog.rootRows() where ctx.roots.contains(r.name) {
                addTask(Task(id: r.id, path: r.name, recursive: true), &tasks)
            }
        case .rescan:
            try plan(PathUtil.standardize(op.path), recursive: true, &tasks)
        case .fsevent:
            let path = PathUtil.standardize(op.path)
            if op.flags & (EventFlag.userDropped | EventFlag.kernelDropped | EventFlag.eventIdsWrapped) != 0 {
                for r in try catalog.rootRows() where ctx.roots.contains(r.name) { addTask(Task(id: r.id, path: r.name, recursive: true), &tasks) }
                return
            }
            if op.flags & (EventFlag.mustScanSubDirs | EventFlag.rootChanged) != 0 {
                try plan(path, recursive: true, &tasks)
                return
            }
            guard isIndexable(path) else { return }
            if ctx.roots.contains(path) {
                try plan(path, recursive: false, &tasks)
            } else {
                try plan((path as NSString).deletingLastPathComponent, recursive: false, &tasks)
            }
        }
    }

    /// Reconcile `path`; when it is not catalogued yet, reconcile its nearest catalogued ancestor,
    /// which discovers it as new and scans it completely.
    private func plan(_ path: String, recursive: Bool, _ tasks: inout [Int64: Task]) throws {
        guard let root = try root(containing: path) else {
            if ctx.roots.contains(path) { try syncRoots(); if let r = try self.root(containing: path) { addTask(Task(id: r.id, path: r.name, recursive: true), &tasks) } }
            return
        }
        let (row, rowPath) = try catalog.nearest(path, root: root)
        addTask(Task(id: row.id, path: rowPath, recursive: recursive && rowPath == path), &tasks)
        if rowPath != path { unresolved.append((path, recursive)) }
    }

    private func replanUnresolved() throws {
        let items = unresolved
        unresolved.removeAll()
        for (path, recursive) in items {
            guard let root = try root(containing: path) else { continue }
            let (row, rowPath) = try catalog.nearest(path, root: root)
            if rowPath != path { unresolved.append((path, recursive)) }
            submit(Task(id: row.id, path: rowPath, recursive: recursive && rowPath == path))
        }
    }

    /// Whether an event path can concern the index at all (inside a root, no excluded ancestor).
    func isIndexable(_ path: String) -> Bool {
        isInNameScope(path) || contentCovers(path)
    }

    /// Below a name root with no component excluded. Components count as directories, so
    /// extension rules (files only) never drop an event that might concern a directory.
    func isInNameScope(_ path: String) -> Bool {
        guard let root = ctx.nameRoots.filter({ PathUtil.isWithin(path, $0) }).max(by: { $0.count < $1.count }) else { return false }
        var current = root
        let rest = root == "/" ? Substring(path.dropFirst()) : path.dropFirst(root.count + 1)
        for component in rest.split(separator: "/") {
            current = (current == "/" ? "" : current) + "/" + component
            if ctx.rules.excludes(path: current, nameKey: NameKey.bytes(String(component)), isDirectory: true,
                                  isHidden: component.hasPrefix(".")) { return false }
        }
        return true
    }

    /// The content scope needs this path: on the way to a root, or inside one with no component
    /// excluded. Hidden items and name or extension exclusions apply there too (the defaults
    /// keep `node_modules` and `.git` out, and the content scope has no such rules of its own).
    private func contentCovers(_ path: String) -> Bool {
        guard let content = ctx.content else { return false }
        if content.isAboveRoot(path) { return true }
        guard let root = content.roots.filter({ PathUtil.isWithin(path, $0) }).max(by: { $0.count < $1.count }) else { return false }
        var current = root
        let rest = root == "/" ? Substring(path.dropFirst()) : path.dropFirst(root.count + 1)
        for component in rest.split(separator: "/") {
            current = (current == "/" ? "" : current) + "/" + component
            let name = String(component)
            if ctx.rules.excludes(path: current, nameKey: NameKey.bytes(name), isDirectory: true, isHidden: component.hasPrefix("."), ignoringPrefixes: true)
                || !content.keepsDirectory(path: current, name: name) { return false }
        }
        return true
    }

    /// Decides one listed entry: in the name scope, kept for the content scope only, or dropped
    /// (nil). `parent` is the directory it was listed in.
    private func classify(_ e: DiskEntry, path: String, parent: Row) -> DiskEntry? {
        // Below a content-only directory the name rules were not walked yet.
        let inName = parent.flags.contains(.contentOnly) ? isInNameScope(path) && !excluded(path, e) : !excluded(path, e)
        if inName { return e }
        guard let content = ctx.content else { return nil }
        var kept = e
        kept.contentOnly = true
        if e.isDirectory && content.isAboveRoot(path) { return kept }
        guard content.roots.contains(where: { PathUtil.isWithin(path, $0) }),
              !ctx.rules.excludes(path: path, nameKey: NameKey.bytes(e.name), isDirectory: e.isDirectory, isHidden: e.hidden, ignoringPrefixes: true) else { return nil }
        let wanted = e.isDirectory ? content.keepsDirectory(path: path, name: e.name) : content.eligible(path: path, name: e.name, isDirectory: false)
        return wanted ? kept : nil
    }

    /// Creates rows for new roots and deletes roots no longer in scope (with their subtrees).
    private func syncRoots() throws {
        let existing = try catalog.rootRows()
        for r in existing where !ctx.roots.contains(r.name) {
            try removeSubtree(r.id)
        }
        for path in ctx.roots where !existing.contains(where: { $0.name == path }) {
            guard case .success(var e) = DiskLister.stat(path), e.isDirectory else { continue }
            e.contentOnly = !ctx.nameRoots.contains { PathUtil.isWithin(path, $0) }
            let r = try catalog.insert(parent: 0, name: path, e, seq: seq)
            try wrote(.upsert(FileCatalog.record(r)))
        }
        // A kept root can change sides when the scopes change.
        for var r in existing where ctx.roots.contains(r.name) {
            let contentOnly = !ctx.nameRoots.contains { PathUtil.isWithin(r.name, $0) }
            guard r.flags.contains(.contentOnly) != contentOnly else { continue }
            if contentOnly { r.flags.insert(.contentOnly) } else { r.flags.remove(.contentOnly) }
            try catalog.update(r, seq: seq)
            try wrote(.upsert(FileCatalog.record(r)))
        }
    }

    // MARK: Listing

    private func submit(_ t: Task) {
        if let running = inFlight[t.id] {
            if t.recursive && !running { deferred[t.id] = t }
            return
        }
        if let d = done[t.id], d.path == t.path, d.recursive || !t.recursive { return }
        queue(.init(id: t.id, path: t.path, fresh: false, recursive: t.recursive))
    }

    private func queue(_ job: ParallelLister.Job) {
        inFlight[job.id] = job.recursive
        submissions += 1
        lister.submit(job)
    }

    private func childPath(_ parent: String, _ name: String) -> String { (parent == "/" ? "" : parent) + "/" + name }

    private func excluded(_ path: String, _ e: DiskEntry) -> Bool {
        ctx.rules.excludes(path: path, nameKey: NameKey.bytes(e.name), isDirectory: e.isDirectory, isHidden: e.hidden)
    }

    private func descends(_ e: DiskEntry) -> Bool {
        e.isDirectory && !e.isMount && (!e.isPackage || ctx.rules.includePackageContents)
    }

    private func drain() throws {
        while let out = lister.next() {
            let job = out.job
            inFlight[job.id] = nil
            defer { if let t = deferred.removeValue(forKey: job.id) { submit(t) } }
            if case .success = out.result { done[job.id] = (job.path, job.recursive) }
            guard var dir = try catalog.row(id: job.id) else { continue }
            switch out.result {
            case .failure(let err):
                if err.code == .ENOENT || err.code == .ENOTDIR {
                    missing.insert(job.id)
                    if triedPath[job.id] == nil { triedPath[job.id] = job.path }
                    // The directory itself is gone: its parent's listing decides (unless it is a root,
                    // which may be temporarily unavailable and is kept).
                    if dir.parentId != 0, let parentPath = Optional((job.path as NSString).deletingLastPathComponent) {
                        submit(Task(id: dir.parentId, path: parentPath, recursive: false))
                    }
                } else if !dir.flags.contains(.noAccess) {
                    dir.flags.insert(.noAccess)
                    try catalog.update(dir, seq: seq)
                    try wrote(.upsert(FileCatalog.record(dir)))
                }
            case .success(let listing):
                let entries = listing.entries.compactMap { classify($0, path: childPath(job.path, $0.name), parent: dir) }
                if dir.flags.contains(.noAccess) {
                    dir.flags.remove(.noAccess)
                    try catalog.update(dir, seq: seq)
                    try wrote(.upsert(FileCatalog.record(dir)))
                }
                if job.fresh { try insertAll(entries, into: dir, path: job.path) } else { try reconcile(entries, dir: dir, job: job, incomplete: listing.incomplete) }
            }
        }
    }

    /// Newly created directory: nothing to compare against.
    private func insertAll(_ entries: [DiskEntry], into dir: Row, path: String) throws {
        for e in entries {
            let p = childPath(path, e.name)
            // Something may already have been moved into this new directory in this batch.
            guard let r = try catalog.insertIfAbsent(parent: dir.id, name: e.name, e, seq: seq) else { continue }
            try wrote(.upsert(FileCatalog.record(r)))
            if descends(e) { queue(.init(id: r.id, path: p, fresh: true, recursive: true)) }
        }
    }

    private func reconcile(_ entries: [DiskEntry], dir: Row, job: ParallelLister.Job, incomplete: Bool) throws {
        var existing = Dictionary(try catalog.children(of: dir.id).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for e in entries {
            let p = childPath(job.path, e.name)
            guard var r = existing.removeValue(forKey: e.name) else {
                pendingNew.append((dir, job.path, e))
                continue
            }
            // Seen alive here: an earlier listing in this batch (e.g. of a directory recreated at
            // this row's old path) may have marked it vanished.
            vanished[r.id] = nil
            // A different type, or a directory with another inode under the same name, is a
            // different object (rm -rf + mkdir, or moved away and recreated). Files keep their id
            // across inode changes: that is an atomic save.
            if r.flags.contains(.directory) != e.isDirectory || r.flags.contains(.symlink) != e.isSymlink
                || (e.isDirectory && (r.ino != e.ino || r.dev != e.dev)) {
                vanished[r.id] = r
                vanishedIn[r.id] = job.path
                pendingNew.append((dir, job.path, e))
                continue
            }
            var flags = e.flags
            if r.flags.contains(.noAccess) { flags.insert(.noAccess) }
            if r.flags != flags || r.ino != e.ino || r.dev != e.dev || r.size != e.size || r.mtimeNs != e.mtimeNs || r.birthNs != e.birthNs {
                r.flags = flags; r.ino = e.ino; r.dev = e.dev; r.size = e.size; r.mtimeNs = e.mtimeNs; r.birthNs = e.birthNs
                try catalog.update(r, seq: seq)
                try wrote(.upsert(FileCatalog.record(r)))
            }
            if descends(e) {
                if job.recursive { submit(Task(id: r.id, path: p, recursive: true)) }
            } else if try e.isDirectory && job.recursive && catalog.hasChildren(r.id) {
                // No longer descended (e.g. package contents switched off): drop its old children.
                for c in try catalog.children(of: r.id) { vanished[c.id] = c }
            }
        }
        // An entry the kernel could not report is not a deleted one.
        guard !incomplete else { return }
        for r in existing.values {
            vanished[r.id] = r
            vanishedIn[r.id] = job.path
        }
    }

    /// A vanished entry may have moved to a directory this batch did not list (its event can be
    /// in another batch, or its path did not resolve). Ask the kernel where the inode is now and
    /// reconcile that directory, so the move keeps the id instead of becoming delete + insert.
    private func chaseVanished() throws {
        for (id, r) in vanished where chased.insert(id).inserted {
            let seenIn = try vanishedIn[id] ?? catalog.path(of: r.parentId)
            guard let seenIn, let now = DiskLister.currentPath(ino: r.ino, onVolumeOf: seenIn),
                  case .success(let e) = DiskLister.stat(now), e.ino == r.ino, sameKind(r, e),
                  let root = try root(containing: now) else { continue }
            let parent = (now as NSString).deletingLastPathComponent
            guard parent != seenIn || e.name != r.name else { continue }
            let (row, rowPath) = try catalog.nearest(parent, root: root)
            if rowPath != parent { unresolved.append((parent, false)) }
            done[row.id] = nil  // listed before the entry arrived there
            submit(Task(id: row.id, path: rowPath, recursive: false))
        }
    }

    /// Matches appeared names with vanished ones by inode before inserting anything new.
    /// Moves are applied first (via temporary names, so swaps cannot collide on the unique
    /// (parent, name) index); then inserts, which evict any row still holding their slot.
    private func resolvePending() throws {
        var byInode: [Int64: [Int64: Int64]] = [:]  // dev → ino → row id
        for r in vanished.values { byInode[r.dev, default: [:]][r.ino] = r.id }
        // A directory listed twice in one batch reports the same new name twice; the latest
        // listing wins.
        var seenSlots = Set<String>()
        let pending = pendingNew.reversed().filter { seenSlots.insert("\($0.parent.id)/\($0.entry.name)").inserted }.reversed()
        pendingNew.removeAll()
        var moves: [(row: Row, parent: Row, parentPath: String, entry: DiskEntry)] = []
        var inserts: [(parent: Row, parentPath: String, entry: DiskEntry)] = []
        var claimed = Set<Int64>()
        for (parent, parentPath, e) in pending {
            var match: Row?
            if let id = byInode[e.dev]?[e.ino], let r = vanished[id], sameKind(r, e), !claimed.contains(id) {
                match = r
            } else {
                // Source directory not listed in this batch: a live row whose path no longer holds
                // this inode is the same file moved here. A row still holding it is a hard link.
                for r in try catalog.rows(dev: e.dev, ino: e.ino) where sameKind(r, e) && vanished[r.id] == nil && !claimed.contains(r.id) {
                    guard let old = try catalog.path(of: r.id) else { continue }
                    if case .success(let now) = DiskLister.stat(old), now.ino == e.ino, now.dev == e.dev { continue }
                    match = r
                    break
                }
            }
            if let r = match {
                claimed.insert(r.id)
                vanished[r.id] = nil
                moves.append((r, parent, parentPath, e))
            } else {
                inserts.append((parent, parentPath, e))
            }
        }

        for m in moves {
            var r = m.row
            r.name = "\u{1}xsearch-moving-\(r.id)"  // never a real name; no NUL (SQLite text)
            try catalog.update(r, seq: seq)
        }
        // A move under a directory the catalog still places below the moved row would create a
        // parent cycle (e.g. a/b became b/a). Apply moves that are safe now first — each can make
        // others safe; postpone the rest and locate their destination directory meanwhile.
        var remaining = moves
        while true {
            var progressed = false
            var next: [(row: Row, parent: Row, parentPath: String, entry: DiskEntry)] = []
            for m in remaining {
                // Deleted meanwhile with a subtree that another move evicted.
                guard try catalog.row(id: m.row.id) != nil else {
                    pendingNew.append((m.parent, m.parentPath, m.entry))
                    continue
                }
                if try catalog.isWithin(m.parent.id, m.row.id) { next.append(m); continue }
                try apply(m, claimed: claimed)
                progressed = true
            }
            remaining = next
            if !progressed || remaining.isEmpty { break }
        }
        for m in remaining {
            // Keep the temporary name (never published): its old slot may be taken by now. The
            // next round matches it as a move, or it is deleted with the other vanished rows.
            vanished[m.row.id] = m.row
            vanishedIn[m.row.id] = try catalog.path(of: m.row.parentId)
            pendingNew.append((m.parent, m.parentPath, m.entry))
            try chase(m.parent)
        }
        for (parent, parentPath, e) in inserts {
            try evictOccupant(parent: parent.id, name: e.name, keeping: claimed)
            let r = try catalog.insert(parent: parent.id, name: e.name, e, seq: seq)
            try wrote(.upsert(FileCatalog.record(r)))
            if descends(e) { queue(.init(id: r.id, path: childPath(parentPath, e.name), fresh: true, recursive: true)) }
        }
    }

    private func apply(_ m: (row: Row, parent: Row, parentPath: String, entry: DiskEntry), claimed: Set<Int64>) throws {
        try evictOccupant(parent: m.parent.id, name: m.entry.name, keeping: claimed)
        var r = m.row
        let e = m.entry
        var flags = e.flags
        if r.flags.contains(.noAccess) { flags.insert(.noAccess) }
        r.parentId = m.parent.id; r.name = e.name; r.flags = flags
        r.ino = e.ino; r.dev = e.dev; r.size = e.size; r.mtimeNs = e.mtimeNs; r.birthNs = e.birthNs
        try catalog.update(r, seq: seq)
        try wrote(.upsert(FileCatalog.record(r)))
        // Every file below a moved directory has a new path (the content index stores it).
        if r.flags.contains(.directory) { movedDirs.insert(r.id) }
        // Changes inside a directory moved in this batch may have been reported under paths
        // that no longer resolve: reconcile its whole subtree at the new location.
        if descends(e) { submit(Task(id: r.id, path: childPath(m.parentPath, e.name), recursive: true)) }
    }

    /// Lists the directory that currently holds `dir` on disk (found by inode).
    private func chase(_ dir: Row) throws {
        guard let seenIn = try catalog.path(of: dir.parentId) ?? catalog.path(of: dir.id),
              let now = DiskLister.currentPath(ino: dir.ino, onVolumeOf: seenIn),
              let root = try root(containing: now) else { return }
        let parent = (now as NSString).deletingLastPathComponent
        let (row, rowPath) = try catalog.nearest(parent, root: root)
        if rowPath != parent { unresolved.append((parent, false)) }
        done[row.id] = nil
        submit(Task(id: row.id, path: rowPath, recursive: false))
    }

    /// The disk says `name` in `parent` now belongs to a new or moved entry: whatever row still
    /// holds that slot (and is not itself being moved) is gone.
    /// A deleted row is no longer a candidate for a move: a descendant still listed as vanished
    /// would come back as an update of a row the catalog holds as deleted (a ghost in the name
    /// index). If it turns up elsewhere, it is simply a new entry there.
    private func removeSubtree(_ id: Int64) throws {
        for removed in try catalog.deleteSubtree(id, seq: seq) {
            vanished[removed] = nil
            try wrote(.remove(removed))
        }
    }

    private func evictOccupant(parent: Int64, name: String, keeping: Set<Int64>) throws {
        guard let occupant = try catalog.child(of: parent, named: name), !keeping.contains(occupant.id) else { return }
        vanished[occupant.id] = nil
        try removeSubtree(occupant.id)
    }

    private func resubmitMissing() throws {
        let ids = missing
        missing.removeAll()
        for id in ids {
            guard let path = try catalog.path(of: id) else { continue }
            // Same path as the failed attempt: keep waiting for a move to change it.
            guard triedPath[id] != path else { missing.insert(id); continue }
            triedPath[id] = path
            submit(Task(id: id, path: path, recursive: false))
        }
    }

    // MARK: Content tasks

    /// Turns this chunk's catalog changes into content tasks (§9.2: every change that affects
    /// extraction or index fields gets a new op_seq and task). Runs inside the open transaction,
    /// so tasks commit atomically with the catalog rows that caused them.
    private func settleContent() throws {
        defer {
            contentTouched.removeAll()
            contentRemoved.removeAll()
            movedDirs.removeAll()
            refreshAllContent = false
        }
        guard inTransaction else { return }
        // Re-read every time: IndexService also bumps op_seq (extractor upgrades, rebuilds).
        var counter = try catalog.opSeqCounter()
        let start = counter
        var dirPaths: [Int64: String] = [:]
        func dirPath(_ id: Int64) throws -> String? {
            if let p = dirPaths[id] { return p }
            guard let p = try catalog.path(of: id) else { return nil }
            dirPaths[id] = p
            return p
        }
        var touched = contentTouched
        for d in movedDirs { touched.formUnion(try catalog.descendantFiles(of: d)) }
        if refreshAllContent { touched.formUnion(try catalog.contentCandidates()) }
        touched.subtract(contentRemoved)
        for id in touched {
            guard let info = try catalog.contentInfo(id), !info.deleted, !info.flags.contains(.directory) else { continue }
            var eligible = false
            if let rules = ctx.content, ContentType.of(name: info.name) != nil, info.parentId != 0, let dir = try dirPath(info.parentId) {
                eligible = rules.eligible(path: childPath(dir, info.name), name: info.name, isDirectory: false)
            }
            if eligible {
                counter += 1
                try catalog.setContent(id, inContent: true, opSeq: counter)
                try catalog.enqueue(id, opSeq: counter, kind: .index, priority: info.mtimeNs / 1_000_000_000)
                tasksWritten += 1
            } else if info.inContent {
                counter += 1
                try catalog.setContent(id, inContent: false, opSeq: counter)
                try catalog.enqueue(id, opSeq: counter, kind: .delete, priority: Int64.max / 2)
                tasksWritten += 1
            }
        }
        for id in contentRemoved {
            guard let info = try catalog.contentInfo(id), info.inContent else { continue }
            counter += 1
            try catalog.setContent(id, inContent: false, opSeq: counter)
            try catalog.enqueue(id, opSeq: counter, kind: .delete, priority: Int64.max / 2)
            tasksWritten += 1
        }
        if counter != start { try catalog.setOpSeqCounter(counter) }
        opCounter = counter
    }

    private func sameKind(_ r: Row, _ e: DiskEntry) -> Bool {
        r.flags.contains(.directory) == e.isDirectory && r.flags.contains(.symlink) == e.isSymlink
    }

    private func deleteVanished() throws {
        for r in vanished.values {
            try removeSubtree(r.id)
        }
        vanished.removeAll()
    }
}

import Darwin
import Foundation
import XSearchCore

/// Base snapshot + incremental overlay (ARCHITECTURE §7). Immutable: queries hold one view while
/// updates publish a new one. Overlay rules:
/// - an overlay entry for a base file id masks the base entry (`nil` = deleted or moved out);
/// - new and moved-in entries live only in the overlay;
/// - a moved or renamed base directory breaks the "subtree = contiguous range" property, so
///   `dir:` then falls back to walking each candidate's current ancestor chain.
public struct NameView: Sendable {
    public let base: NameSnapshot
    let overlay: [Int64: OverlayNode]
    /// Base directories that the overlay renamed, moved or deleted.
    let modifiedBaseDirs: Int
    /// Incremented by every `applying`; lets a background merge rebase onto later changes.
    public let generation: UInt64

    /// `record == nil` is a tombstone for a base entry (deleted or moved out of scope).
    struct OverlayNode: Sendable {
        var record: NameRecord?
        var key: [UInt8]
        var generation: UInt64
    }

    public init(base: NameSnapshot, generation: UInt64 = 0) {
        self.init(base: base, overlay: [:], generation: generation)
    }

    init(base: NameSnapshot, overlay: [Int64: OverlayNode], generation: UInt64) {
        self.base = base
        self.overlay = overlay
        self.generation = generation
        modifiedBaseDirs = overlay.keys.reduce(0) { n, id in
            guard let i = base.index(of: id) else { return n }
            return base.flags[i] & EntryFlags.directory.rawValue != 0 ? n + 1 : n
        }
    }

    public var overlayCount: Int { overlay.count }
    public var count: Int {
        var n = base.count
        for (id, node) in overlay {
            let inBase = base.index(of: id) != nil
            if inBase && node.record == nil { n -= 1 } else if !inBase && node.record != nil { n += 1 }
        }
        return n
    }

    /// Applies changes; upserts and removes are idempotent, so replaying catalog rows that the
    /// base already contains is harmless.
    public func applying(_ changes: [NameChange]) -> NameView {
        let gen = generation + 1
        var next = overlay
        for change in changes {
            switch change {
            case .upsert(let r):
                next[r.fileId] = OverlayNode(record: r, key: NameKey.bytes(r.name), generation: gen)
            case .remove(let id):
                if base.index(of: id) != nil {
                    next[id] = OverlayNode(record: nil, key: [], generation: gen)
                } else {
                    next.removeValue(forKey: id)
                }
            }
        }
        return NameView(base: base, overlay: next, generation: gen)
    }

    /// Folds the whole overlay into a new base snapshot (run in the background). `completeSeq`
    /// is the catalog sequence up to which this view is known to contain every change; it is
    /// stored in the snapshot, and startup replays catalog rows changed after it.
    public func merged(completeSeq: Int64) -> NameView {
        var (records, cache) = base.exportRecords(skipping: { overlay[$0] != nil })
        for node in overlay.values {
            guard let r = node.record else { continue }
            records.append(r)
            cache[r.name] = node.key
        }
        return NameView(base: NameSnapshot.build(records, seq: completeSeq, fingerprint: base.fingerprint, keyCache: cache),
                        generation: generation)
    }

    /// Re-applies changes that reached `live` after `merged` was captured, so a background merge
    /// never drops updates committed meanwhile.
    public func rebased(onto merged: NameView) -> NameView {
        var next: [Int64: OverlayNode] = [:]
        for (id, node) in overlay where node.generation > merged.generation {
            if node.record != nil || merged.base.index(of: id) != nil { next[id] = node }
        }
        return NameView(base: merged.base, overlay: next, generation: generation)
    }

    // MARK: Node access

    /// Current record for a file id, honouring the overlay.
    public func record(_ id: Int64) -> NameRecord? {
        if let entry = overlay[id] { return entry.record }
        return base.index(of: id).map(base.record(at:))
    }

    func parentId(_ id: Int64) -> Int64? {
        if let entry = overlay[id] { return entry.record?.parentId }
        guard let i = base.index(of: id) else { return nil }
        let p = base.parents[i]
        return p < 0 ? 0 : base.fileIds[Int(p)]
    }

    /// Absolute path, or nil when the entry or one of its ancestors no longer exists.
    public func path(_ id: Int64) -> String? {
        var parts: [String] = []
        var current = id
        for _ in 0..<4096 {
            guard let r = record(current) else { return nil }
            if r.parentId == 0 {
                guard let root = r.rootPath else { return nil }
                if parts.isEmpty { return root }
                return (root == "/" ? "" : root) + "/" + parts.reversed().joined(separator: "/")
            }
            parts.append(r.name)
            current = r.parentId
        }
        return nil
    }

    func depth(_ id: Int64) -> Int {
        var d = 0, current = id
        while let p = parentId(current), p != 0, d < 4096 { d += 1; current = p }
        return d
    }

    /// True when `id` lies strictly below one of `targets` in the current tree.
    func isBelow(_ id: Int64, _ targets: Set<Int64>) -> Bool {
        var current = id
        for _ in 0..<4096 {
            guard let p = parentId(current), p != 0 else { return false }
            if targets.contains(p) { return true }
            current = p
        }
        return false
    }

    // MARK: Directory resolution for `dir:`

    func key(of id: Int64) -> [UInt8]? {
        if let entry = overlay[id] { return entry.record == nil ? nil : entry.key }
        return base.index(of: id).map { Array(base.keys.slice(base.keyId(of: $0))) }
    }

    func isDirectory(_ id: Int64) -> Bool { record(id)?.flags.contains(.directory) ?? false }

    func rootIds() -> [Int64] {
        var ids = Set(base.rootPaths.keys.filter { overlay[$0] == nil })
        for (id, node) in overlay { if let r = node.record, r.parentId == 0 { ids.insert(id) } else { ids.remove(id) } }
        return Array(ids)
    }

    func child(of parent: Int64, key: [UInt8]) -> Int64? {
        for (id, node) in overlay {
            if let r = node.record, r.parentId == parent, r.flags.contains(.directory), node.key == key { return id }
        }
        guard let pIndex = base.index(of: parent), let keyId = base.keyId(for: key),
              let c = base.childDirectory(parent: Int32(pIndex), keyId: keyId) else { return nil }
        let id = base.fileIds[c]
        // A base child that the overlay moved away is no longer here.
        if let entry = overlay[id] { return entry.record?.parentId == parent && entry.key == key ? id : nil }
        return id
    }

    func resolve(_ filter: NameQuery.DirFilter) -> Set<Int64> {
        switch filter {
        case .absolute(_, let components):
            var out = Set<Int64>()
            for root in rootIds() {
                guard let rootPath = record(root)?.rootPath else { continue }
                let rootComponents = PathUtil.components(rootPath).map(NameKey.bytes)
                if components.count <= rootComponents.count {
                    // The filter is the root itself or above it: the whole root qualifies.
                    if Array(rootComponents.prefix(components.count)) == components {
                        if components.count == rootComponents.count { out.insert(root) } else { out.insert(-root) }
                    }
                    continue
                }
                guard Array(components.prefix(rootComponents.count)) == rootComponents else { continue }
                var current: Int64? = root
                for c in components.dropFirst(rootComponents.count) { current = current.flatMap { child(of: $0, key: c) } }
                if let current { out.insert(current) }
            }
            return out
        case .fragment(_, let components):
            guard let last = components.last else { return [] }
            var out = Set<Int64>()
            func ancestorsMatch(_ id: Int64) -> Bool {
                var current = id
                for c in components.dropLast().reversed() {
                    guard let p = parentId(current), p != 0, key(of: p) == c else { return false }
                    current = p
                }
                return true
            }
            if let keyId = base.keyId(for: last) {
                for i in 0..<base.count where base.flags[i] & EntryFlags.directory.rawValue != 0 && base.keyId(of: i) == keyId {
                    let id = base.fileIds[i]
                    if overlay[id] == nil && ancestorsMatch(id) { out.insert(id) }
                }
            }
            for (id, node) in overlay {
                if let r = node.record, r.flags.contains(.directory), node.key == last, ancestorsMatch(id) { out.insert(id) }
            }
            return out
        }
    }

    // MARK: Search

    public struct Hit: Sendable, Equatable {
        public var fileId: Int64
        public var name: String
        public var path: String
        public var flags: EntryFlags
        public var size: Int64
        public var mtime: Int64
        /// 4 exact, 3 prefix, 2 word boundary, 1 substring.
        public var level: UInt8
    }

    public struct Result: Sendable {
        public var hits: [Hit]
        public var total: Int
        /// `dir:` named a path that is not in the index.
        public var unresolvedDirs: [String]
    }

    /// Complete matching set, ranked; only the top `limit` are materialized. `usage` maps file id
    /// to open count (user.sqlite) for ranking.
    public func search(_ q: NameQuery, limit: Int = 200, usage: [Int64: Int] = [:]) -> Result {
        guard !q.isEmpty else { return Result(hits: [], total: 0, unresolvedDirs: []) }
        let matcher = Matcher(q)

        // `dir:` targets. A negative id means "this root and everything in it".
        var targets: Set<Int64>?
        var unresolved: [String] = []
        if !q.dirs.isEmpty {
            var all = Set<Int64>()
            for d in q.dirs {
                let r = resolve(d)
                if r.isEmpty {
                    switch d { case .absolute(let p, _): unresolved.append(p); case .fragment(let t, _): unresolved.append(t) }
                }
                all.formUnion(r)
            }
            targets = all
        }
        if let t = targets, t.isEmpty { return Result(hits: [], total: 0, unresolvedDirs: unresolved) }
        let wholeRoots = Set(targets?.filter { $0 < 0 }.map { -$0 } ?? [])
        let below = Set(targets?.filter { $0 > 0 } ?? [])

        // Base ranges: exact while no base directory was moved; otherwise scan all and walk ancestors.
        var ranges: [Range<Int>] = [0..<base.count]
        var needWalk = false
        if targets != nil {
            if modifiedBaseDirs == 0 && below.allSatisfy({ base.index(of: $0) != nil }) {
                ranges = (below.compactMap { base.index(of: $0) }.map { $0 + 1..<Int(base.subtreeEnd[$0]) }
                    + wholeRoots.compactMap { base.index(of: $0) }.map { $0..<Int(base.subtreeEnd[$0]) })
                    .sorted { $0.lowerBound < $1.lowerBound }
                ranges = mergeRanges(ranges)
            } else {
                needWalk = true
            }
        }
        func inTargets(_ id: Int64) -> Bool {
            guard targets != nil else { return true }
            if !below.isEmpty && isBelow(id, below) { return true }
            if wholeRoots.isEmpty { return false }
            var current = id
            for _ in 0..<4096 {
                if wholeRoots.contains(current) { return true }
                guard let p = parentId(current), p != 0 else { return false }
                current = p
            }
            return false
        }

        let scanned = ranges.reduce(0) { $0 + $1.count }
        // Path patterns depend on the entry, not only its name key: no per-key cache then.
        let levels = !matcher.needsPath && scanned >= base.keys.count / 2 ? matcher.levels(base.keys) : nil
        var top = TopK(limit: limit)
        var total = 0
        // Shallower first, then by path: the end of the shown order.
        let tie: (Int64, Int64) -> Bool = { a, b in
            let da = self.depth(a), db = self.depth(b)
            return da != db ? da < db : (self.path(a) ?? "") < (self.path(b) ?? "")
        }
        let overlayEmpty = overlay.isEmpty
        let isRootFlag: (Int) -> Bool = { self.base.parents[$0] < 0 && self.base.rootPaths[self.base.fileIds[$0]] == "/" }
        base.keys.bytes.withUnsafeBufferPointer { keyBytes in
            for range in ranges {
                for i in range {
                    let k = base.keyId(of: i)
                    let level: UInt8
                    let id = base.fileIds[i]
                    if let levels {
                        level = levels[k]
                    } else if matcher.needsPath {
                        level = matcher.level(keyBytes, base.keys.range(k)) { self.path(id).map(NameKey.bytes) }
                    } else {
                        level = matcher.level(keyBytes, base.keys.range(k))
                    }
                    if level == 0 { continue }
                    let f = EntryFlags(rawValue: base.flags[i])
                    if f.contains(.contentOnly) { continue }
                    if !matcher.kindAllowed(f, extAllowed: level & 0x80 != 0) { continue }
                    if !matcher.metaAllowed(f, size: base.sizes[i], mtime: base.mtimes[i]) { continue }
                    if !overlayEmpty && overlay[id] != nil { continue }
                    if isRootFlag(i) { continue }
                    if needWalk && !inTargets(id) { continue }
                    total += 1
                    top.offer(Candidate(id: id, level: level & 0x7F, usage: usage[id] ?? 0, mtime: base.mtimes[i]), tie: tie)
                }
            }
        }
        for (id, node) in overlay {
            guard let r = node.record, !r.flags.contains(.contentOnly) else { continue }
            let level = node.key.withUnsafeBufferPointer { matcher.level($0, 0..<$0.count) { self.path(id).map(NameKey.bytes) } }
            if level == 0 || !matcher.kindAllowed(r.flags, extAllowed: level & 0x80 != 0) { continue }
            if !matcher.metaAllowed(r.flags, size: r.size, mtime: r.mtime) { continue }
            if r.parentId == 0 && r.rootPath == "/" { continue }
            if targets != nil && !inTargets(id) { continue }
            total += 1
            top.offer(Candidate(id: id, level: level & 0x7F, usage: usage[id] ?? 0, mtime: r.mtime), tie: tie)
        }

        var hits: [(Hit, Int)] = top.items.compactMap { c in
            guard let r = record(c.id), let p = path(c.id) else { return nil }
            return (Hit(fileId: c.id, name: r.name, path: p, flags: r.flags, size: r.size, mtime: r.mtime, level: c.level), depth(c.id))
        }
        hits.sort { a, b in
            if a.0.level != b.0.level { return a.0.level > b.0.level }
            let ua = usage[a.0.fileId] ?? 0, ub = usage[b.0.fileId] ?? 0
            if ua != ub { return ua > ub }
            if a.0.mtime != b.0.mtime { return a.0.mtime > b.0.mtime }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.0.path < b.0.path
        }
        return Result(hits: hits.map(\.0), total: total, unresolvedDirs: unresolved)
    }
}

func mergeRanges(_ sorted: [Range<Int>]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    for r in sorted where !r.isEmpty {
        if let last = out.last, r.lowerBound <= last.upperBound {
            out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
        } else {
            out.append(r)
        }
    }
    return out
}

/// Term matching on folded keys. A level byte carries the match level in the low 7 bits and
/// "extension allowed" in the high bit. Plain AND-ed literals take the memmem fast path; other
/// queries evaluate the expression tree, ranked by their first positive literal.
struct Matcher {
    indirect enum Node {
        case literal([UInt8])
        case glob(Glob)
        case regex(NSRegularExpression, path: Bool)
        case and([Node])
        case or([Node])
        case not(Node)
    }

    let terms: [[UInt8]]
    let tree: Node?
    let rankTerm: [UInt8]?
    let needsPath: Bool
    let extensions: Set<[UInt8]>
    let kinds: Set<FileKind>
    let kindExtensions: Set<[UInt8]>
    let size: ClosedRange<Int64>?
    let modified: ClosedRange<Int64>?
    let documents: DocumentCheck?

    /// Per-search cache of "is this extension one of the app's documents" (UTI conformance is
    /// too slow to repeat for every one of a million names; distinct extensions are few).
    final class DocumentCheck {
        let types: DocumentTypes
        private var cache: [[UInt8]: Bool] = [:]
        init(_ types: DocumentTypes) { self.types = types }
        func allows(_ ext: [UInt8]) -> Bool {
            if let hit = cache[ext] { return hit }
            let ok = types.allows(extension: String(decoding: ext, as: UTF8.self))
            cache[ext] = ok
            return ok
        }
    }

    init(_ q: NameQuery) {
        documents = q.documentTypes.map(DocumentCheck.init)
        extensions = Set(q.extensions.map { Array($0.utf8) })
        kinds = q.kinds
        kindExtensions = Set(q.kinds.flatMap(\.extensions).map { Array($0.utf8) })
        size = q.size
        modified = q.modified
        if q.isSimple {
            terms = q.termKeys
            tree = nil
            rankTerm = nil
            needsPath = false
            return
        }
        terms = []
        var path = false
        func compile(_ e: NameExpr) -> Node {
            switch e {
            case .literal(_, let key): return .literal(key)
            case .wildcard(let g):
                path = path || g.fullPath
                return .glob(g)
            case .regex(let p):
                let full = p.contains("/")
                path = path || full
                // Validated by the parser; keys are case-folded already.
                return .regex(try! NSRegularExpression(pattern: p, options: [.caseInsensitive]), path: full)
            case .and(let xs): return .and(xs.map(compile))
            case .or(let xs): return .or(xs.map(compile))
            case .not(let x): return .not(compile(x))
            }
        }
        tree = q.expr.map(compile)
        needsPath = path
        rankTerm = q.terms.first.map(NameKey.bytes)
    }

    func levels(_ pool: StringPool) -> [UInt8] {
        pool.bytes.withUnsafeBufferPointer { bytes in
            (0..<pool.count).map { level(bytes, pool.range($0)) }
        }
    }

    /// `path` gives the entry's folded full path; only path patterns call it.
    func level(_ bytes: UnsafeBufferPointer<UInt8>, _ r: Range<Int>, path: (() -> [UInt8]?)? = nil) -> UInt8 {
        let base = bytes.baseAddress! + r.lowerBound
        let n = r.count
        var best: UInt8 = 1
        if let tree {
            let key = UnsafeBufferPointer(start: base, count: n)
            var cached: [UInt8]??
            let lazyPath: () -> [UInt8]? = {
                if cached == nil { cached = .some(path?()) }
                return cached!
            }
            guard eval(tree, key, lazyPath) else { return 0 }
            if let rankTerm { best = max(1, rank(base, n, rankTerm)) }
        } else {
            for (t, term) in terms.enumerated() {
                let found = t == 0 ? rank(base, n, term) : (contains(base, n, term) ? 1 : 0)
                if found == 0 { return 0 }
                if t == 0 { best = found }
            }
        }
        guard !extensions.isEmpty || !kindExtensions.isEmpty || documents != nil else { return best | 0x80 }
        let ext = keyExtension(UnsafeBufferPointer(start: base, count: n)).map(Array.init) ?? []
        if let documents, !documents.allows(ext) { return 0 }
        if extensions.isEmpty && kindExtensions.isEmpty { return best | 0x80 }
        if !extensions.isEmpty && !extensions.contains(ext) { return 0 }
        return kindExtensions.contains(ext) ? best | 0x80 : best
    }

    func eval(_ node: Node, _ key: UnsafeBufferPointer<UInt8>, _ path: () -> [UInt8]?) -> Bool {
        switch node {
        case .literal(let term): return contains(key.baseAddress!, key.count, term)
        case .glob(let g):
            guard g.fullPath else { return g.matches(key) }
            guard g.nameMayMatch(key), let p = path() else { return false }
            return g.matches(p)
        case .regex(let re, let full):
            let subject: String
            if full { guard let p = path() else { return false }; subject = String(decoding: p, as: UTF8.self) } else { subject = String(decoding: key, as: UTF8.self) }
            return re.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
        case .and(let xs): return xs.allSatisfy { eval($0, key, path) }
        case .or(let xs): return xs.contains { eval($0, key, path) }
        case .not(let x): return !eval(x, key, path)
        }
    }

    func contains(_ base: UnsafePointer<UInt8>, _ n: Int, _ term: [UInt8]) -> Bool {
        term.withUnsafeBufferPointer { tb in tb.count == 0 || (tb.count <= n && memmem(base, n, tb.baseAddress!, tb.count) != nil) }
    }

    /// 4 exact (or stem), 3 prefix, 2 word boundary, 1 substring, 0 absent.
    func rank(_ base: UnsafePointer<UInt8>, _ n: Int, _ term: [UInt8]) -> UInt8 {
        term.withUnsafeBufferPointer { tb in
            guard tb.count > 0 else { return 1 }
            guard tb.count <= n else { return 0 }
            guard let first = memmem(base, n, tb.baseAddress!, tb.count) else { return 0 }
            let pos = UnsafeRawPointer(first) - UnsafeRawPointer(base)
            if tb.count == n { return 4 }
            // Stem equality: `report` vs `report.pdf`, `Safari` vs `Safari.app`.
            if pos == 0 && base[tb.count] == 0x2E && memchr(base + tb.count + 1, 0x2E, n - tb.count - 1) == nil { return 4 }
            if pos == 0 { return 3 }
            var p = pos
            while true {
                if isSeparator(base[p - 1]) { return 2 }
                let start = p + 1
                guard start + tb.count <= n, let next = memmem(base + start, n - start, tb.baseAddress!, tb.count) else { return 1 }
                p = UnsafeRawPointer(next) - UnsafeRawPointer(base)
            }
        }
    }

    /// `size:` applies to files only; `dm:` to everything.
    func metaAllowed(_ f: EntryFlags, size s: Int64, mtime: Int64) -> Bool {
        if let size, f.contains(.directory) || !size.contains(s) { return false }
        if let modified, !modified.contains(mtime) { return false }
        return true
    }

    func kindAllowed(_ f: EntryFlags, extAllowed: Bool) -> Bool {
        guard !kinds.isEmpty else { return true }
        if f.isApp { return kinds.contains(.app) }
        if f.contains(.directory) { return kinds.contains(.folder) }
        return extAllowed && !kindExtensions.isEmpty
    }
}

@inline(__always) func isSeparator(_ b: UInt8) -> Bool {
    switch b {
    case 0x20, 0x5F, 0x2D, 0x2E, 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x2C, 0x2B, 0x40, 0x23: true
    default: false
    }
}

struct Candidate {
    var id: Int64
    var level: UInt8
    var usage: Int
    var mtime: Int64

    /// Ordering for selection: higher is better. Must be the order results are shown in, or the
    /// best of a tie can be dropped before the final sort. `tie` is costly and rarely reached.
    func better(than o: Candidate, tie: (Int64, Int64) -> Bool) -> Bool {
        if level != o.level { return level > o.level }
        if usage != o.usage { return usage > o.usage }
        if mtime != o.mtime { return mtime > o.mtime }
        return tie(id, o.id)
    }
}

/// Bounded min-heap keeping the best `limit` candidates.
struct TopK {
    let limit: Int
    var items: [Candidate] = []

    init(limit: Int) { self.limit = max(0, limit) }

    mutating func offer(_ c: Candidate, tie: (Int64, Int64) -> Bool) {
        guard limit > 0 else { return }
        if items.count < limit {
            items.append(c)
            var i = items.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                guard items[p].better(than: items[i], tie: tie) else { break }
                items.swapAt(p, i); i = p
            }
        } else if c.better(than: items[0], tie: tie) {
            items[0] = c
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var worst = i
                if l < items.count && items[worst].better(than: items[l], tie: tie) { worst = l }
                if r < items.count && items[worst].better(than: items[r], tie: tie) { worst = r }
                if worst == i { break }
                items.swapAt(i, worst); i = worst
            }
        }
    }
}

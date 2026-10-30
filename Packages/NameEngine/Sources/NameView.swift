import Darwin
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
        let levels = scanned >= base.keys.count / 2 ? matcher.levels(base.keys) : nil
        var top = TopK(limit: limit)
        var total = 0
        let overlayEmpty = overlay.isEmpty
        let isRootFlag: (Int) -> Bool = { self.base.parents[$0] < 0 && self.base.rootPaths[self.base.fileIds[$0]] == "/" }
        base.keys.bytes.withUnsafeBufferPointer { keyBytes in
            for range in ranges {
                for i in range {
                    let k = base.keyId(of: i)
                    let level: UInt8
                    if let levels { level = levels[k] } else { level = matcher.level(keyBytes, base.keys.range(k)) }
                    if level == 0 { continue }
                    let f = EntryFlags(rawValue: base.flags[i])
                    if !matcher.kindAllowed(f, extAllowed: level & 0x80 != 0) { continue }
                    let id = base.fileIds[i]
                    if !overlayEmpty && overlay[id] != nil { continue }
                    if isRootFlag(i) { continue }
                    if needWalk && !inTargets(id) { continue }
                    total += 1
                    top.offer(Candidate(id: id, level: level & 0x7F, usage: usage[id] ?? 0, mtime: base.mtimes[i]))
                }
            }
        }
        for (id, node) in overlay {
            guard let r = node.record else { continue }
            let level = node.key.withUnsafeBufferPointer { matcher.level($0, 0..<$0.count) }
            if level == 0 || !matcher.kindAllowed(r.flags, extAllowed: level & 0x80 != 0) { continue }
            if r.parentId == 0 && r.rootPath == "/" { continue }
            if targets != nil && !inTargets(id) { continue }
            total += 1
            top.offer(Candidate(id: id, level: level & 0x7F, usage: usage[id] ?? 0, mtime: r.mtime))
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
/// "extension allowed" in the high bit.
struct Matcher {
    let terms: [[UInt8]]
    let extensions: Set<[UInt8]>
    let kinds: Set<FileKind>
    let kindExtensions: Set<[UInt8]>

    init(_ q: NameQuery) {
        terms = q.termKeys
        extensions = Set(q.extensions.map { Array($0.utf8) })
        kinds = q.kinds
        kindExtensions = Set(q.kinds.flatMap(\.extensions).map { Array($0.utf8) })
    }

    func levels(_ pool: StringPool) -> [UInt8] {
        pool.bytes.withUnsafeBufferPointer { bytes in
            (0..<pool.count).map { level(bytes, pool.range($0)) }
        }
    }

    func level(_ bytes: UnsafeBufferPointer<UInt8>, _ r: Range<Int>) -> UInt8 {
        let base = bytes.baseAddress! + r.lowerBound
        let n = r.count
        var best: UInt8 = 1
        for (t, term) in terms.enumerated() {
            let found: UInt8 = term.withUnsafeBufferPointer { tb in
                guard tb.count <= n else { return 0 }
                guard let first = memmem(base, n, tb.baseAddress!, tb.count) else { return 0 }
                if t > 0 { return 1 }
                // Ranking uses the first term only.
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
            if found == 0 { return 0 }
            if t == 0 { best = found }
        }
        guard !extensions.isEmpty || !kindExtensions.isEmpty else { return best | 0x80 }
        let ext = keyExtension(UnsafeBufferPointer(start: base, count: n)).map(Array.init) ?? []
        if !extensions.isEmpty && !extensions.contains(ext) { return 0 }
        return kindExtensions.contains(ext) ? best | 0x80 : best
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

    /// Ordering for selection: higher is better.
    func better(than o: Candidate) -> Bool {
        if level != o.level { return level > o.level }
        if usage != o.usage { return usage > o.usage }
        if mtime != o.mtime { return mtime > o.mtime }
        return id < o.id
    }
}

/// Bounded min-heap keeping the best `limit` candidates.
struct TopK {
    let limit: Int
    var items: [Candidate] = []

    init(limit: Int) { self.limit = max(0, limit) }

    mutating func offer(_ c: Candidate) {
        guard limit > 0 else { return }
        if items.count < limit {
            items.append(c)
            var i = items.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                guard items[p].better(than: items[i]) else { break }
                items.swapAt(p, i); i = p
            }
        } else if c.better(than: items[0]) {
            items[0] = c
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var worst = i
                if l < items.count && items[worst].better(than: items[l]) { worst = l }
                if r < items.count && items[worst].better(than: items[r]) { worst = r }
                if worst == i { break }
                items.swapAt(i, worst); i = worst
            }
        }
    }
}

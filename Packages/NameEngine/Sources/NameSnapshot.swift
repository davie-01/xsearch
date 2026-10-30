import CScan
import Foundation
import XSearchCore

/// Immutable base layer (ARCHITECTURE §7, M0-B 5.4): entries in directory-block depth-first
/// order so every directory's subtree is one contiguous range, with interned display names and
/// a lexicographically sorted, de-duplicated key pool so each distinct key is matched once.
public final class NameSnapshot: @unchecked Sendable {
    public let seq: Int64
    public let fingerprint: String
    let fileIds: [Int64]
    let parents: [Int32]
    let nameIds: [UInt32]
    let flags: [UInt8]
    let sizes: [Int64]
    let mtimes: [Int64]
    let subtreeEnd: [Int32]
    let names: StringPool
    let nameKeyIds: [UInt32]
    let keys: StringPool
    let rootPaths: [Int64: String]
    /// fileId → base index (-1 when absent). File ids are dense SQLite rowids.
    let indexOfId: [Int32]
    /// Directory base indices sorted by (parent index, key id): child lookup for `dir:`.
    let dirTable: [Int32]

    public var count: Int { fileIds.count }

    init(seq: Int64, fingerprint: String, fileIds: [Int64], parents: [Int32], nameIds: [UInt32], flags: [UInt8],
         sizes: [Int64], mtimes: [Int64], subtreeEnd: [Int32], names: StringPool, nameKeyIds: [UInt32],
         keys: StringPool, rootPaths: [Int64: String]) {
        self.seq = seq
        self.fingerprint = fingerprint
        self.fileIds = fileIds
        self.parents = parents
        self.nameIds = nameIds
        self.flags = flags
        self.sizes = sizes
        self.mtimes = mtimes
        self.subtreeEnd = subtreeEnd
        self.names = names
        self.nameKeyIds = nameKeyIds
        self.keys = keys
        self.rootPaths = rootPaths
        var index = [Int32](repeating: -1, count: Int((fileIds.max() ?? 0) + 1))
        for (i, id) in fileIds.enumerated() { index[Int(id)] = Int32(i) }
        indexOfId = index
        var dirs = (0..<fileIds.count).filter { flags[$0] & EntryFlags.directory.rawValue != 0 }.map(Int32.init)
        dirs.sort { a, b in
            let pa = parents[Int(a)], pb = parents[Int(b)]
            return pa != pb ? pa < pb : nameKeyIds[Int(nameIds[Int(a)])] < nameKeyIds[Int(nameIds[Int(b)])]
        }
        dirTable = dirs
    }

    public static func empty(fingerprint: String) -> NameSnapshot {
        build([], seq: 0, fingerprint: fingerprint)
    }

    func index(of id: Int64) -> Int? {
        guard id >= 0, id < indexOfId.count else { return nil }
        let i = indexOfId[Int(id)]
        return i < 0 ? nil : Int(i)
    }

    func keyId(of i: Int) -> Int { Int(nameKeyIds[Int(nameIds[i])]) }

    func record(at i: Int) -> NameRecord {
        let p = parents[i]
        return NameRecord(fileId: fileIds[i], parentId: p < 0 ? 0 : fileIds[Int(p)], name: names.string(Int(nameIds[i])),
                          flags: EntryFlags(rawValue: flags[i]), size: sizes[i], mtime: mtimes[i], rootPath: rootPaths[fileIds[i]])
    }

    /// Binary search of the sorted key pool.
    func keyId<C: Collection>(for key: C) -> Int? where C.Element == UInt8 {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys.slice(mid).lexicographicallyPrecedes(key) { lo = mid + 1 } else { hi = mid }
        }
        return lo < keys.count && keys.slice(lo).elementsEqual(key) ? lo : nil
    }

    /// Base child directory of `parent` (base index, or -1 for roots) with the given key.
    func childDirectory(parent: Int32, keyId: Int) -> Int? {
        var lo = 0, hi = dirTable.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let d = Int(dirTable[mid])
            let p = parents[d], k = self.keyId(of: d)
            if p < parent || (p == parent && k < keyId) { lo = mid + 1 } else { hi = mid }
        }
        guard lo < dirTable.count else { return nil }
        let d = Int(dirTable[lo])
        return parents[d] == parent && self.keyId(of: d) == keyId ? d : nil
    }

    // MARK: Build

    /// `keyCache` lets merges reuse keys already computed instead of calling the normalizer again.
    public static func build(_ records: [NameRecord], seq: Int64, fingerprint: String,
                             keyCache: [String: [UInt8]] = [:]) -> NameSnapshot {
        var keyOf = keyCache
        func key(_ name: String) -> [UInt8] {
            if let k = keyOf[name] { return k }
            let k = NameKey.bytes(name)
            keyOf[name] = k
            return k
        }
        // Children lists in deterministic order: by key, then raw name.
        let byId = Dictionary(records.enumerated().map { ($1.fileId, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int64: [Int]] = [:]
        var roots: [Int] = []
        for (i, r) in records.enumerated() {
            // Orphans (parent missing) would be unreachable; treat them as absent, like the catalog does.
            if r.parentId == 0 { roots.append(i) } else if byId[r.parentId] != nil { children[r.parentId, default: []].append(i) }
        }
        // One key lookup per record; sorting then compares arrays without hashing.
        let recordKeys = records.map { key($0.name) }
        let order: (Int, Int) -> Bool = { a, b in
            let ka = recordKeys[a], kb = recordKeys[b]
            return ka != kb ? ka.lexicographicallyPrecedes(kb) : records[a].name.utf8.lexicographicallyPrecedes(records[b].name.utf8)
        }
        roots.sort { (records[$0].rootPath ?? "") < (records[$1].rootPath ?? "") }
        for k in children.keys { children[k]!.sort(by: order) }

        var dfs: [Int] = []
        var parentPos: [Int32] = []
        var subtreeEnd: [Int32] = []
        dfs.reserveCapacity(records.count)
        // Iterative DFS; a stack frame is (record index, parent position, next child cursor).
        var stack: [(Int, Int32, Int)] = []
        for r in roots.reversed() { stack.append((r, -1, -1)) }
        var visiting: [Int32] = []
        while var top = stack.popLast() {
            if top.2 == -1 {
                let pos = Int32(dfs.count)
                dfs.append(top.0); parentPos.append(top.1); subtreeEnd.append(0)
                visiting.append(pos)
                top.2 = 0
            }
            let kids = children[records[top.0].fileId] ?? []
            if top.2 < kids.count {
                let child = kids[top.2]
                top.2 += 1
                stack.append(top)
                stack.append((child, visiting.last!, -1))
            } else {
                let pos = visiting.removeLast()
                subtreeEnd[Int(pos)] = Int32(dfs.count)
            }
        }

        // Intern display names; collect distinct keys and sort them.
        var nameIndex: [String: UInt32] = [:]
        var names = StringPool()
        var nameKeys: [[UInt8]] = []
        var nameIds: [UInt32] = []
        nameIds.reserveCapacity(dfs.count)
        for i in dfs {
            let name = records[i].name
            if let id = nameIndex[name] { nameIds.append(id); continue }
            let id = UInt32(names.count)
            nameIndex[name] = id
            names.append(name.utf8)
            nameKeys.append(recordKeys[i])
            nameIds.append(id)
        }
        let distinct = Array(Set(nameKeys)).sorted { $0.lexicographicallyPrecedes($1) }
        var keys = StringPool()
        var keyIndex: [[UInt8]: UInt32] = [:]
        for (i, k) in distinct.enumerated() { keys.append(k); keyIndex[k] = UInt32(i) }
        let nameKeyIds = nameKeys.map { keyIndex[$0]! }

        var rootPaths: [Int64: String] = [:]
        for r in roots { if let p = records[r].rootPath { rootPaths[records[r].fileId] = p } }
        return NameSnapshot(
            seq: seq, fingerprint: fingerprint,
            fileIds: dfs.map { records[$0].fileId }, parents: parentPos, nameIds: nameIds,
            flags: dfs.map { records[$0].flags.rawValue }, sizes: dfs.map { records[$0].size },
            mtimes: dfs.map { records[$0].mtime }, subtreeEnd: subtreeEnd, names: names,
            nameKeyIds: nameKeyIds, keys: keys, rootPaths: rootPaths)
    }

    /// Records plus a name → key cache, for merging with an overlay.
    func exportRecords(skipping masked: (Int64) -> Bool) -> ([NameRecord], [String: [UInt8]]) {
        var out: [NameRecord] = []
        out.reserveCapacity(count)
        for i in 0..<count where !masked(fileIds[i]) { out.append(record(at: i)) }
        var cache: [String: [UInt8]] = [:]
        cache.reserveCapacity(names.count)
        for n in 0..<names.count { cache[names.string(n)] = Array(keys.slice(Int(nameKeyIds[n]))) }
        return (out, cache)
    }

    public var memoryBytes: Int {
        fileIds.count * (8 + 4 + 4 + 1 + 8 + 8 + 4 + 4) + names.bytes.count + names.offsets.count * 4
            + nameKeyIds.count * 4 + keys.bytes.count + keys.offsets.count * 4 + indexOfId.count * 4 + dirTable.count * 4
    }

    // MARK: Persistence

    static let magic = Array("XSNAME01".utf8)

    public enum LoadError: Error { case badFormat, checksum, version }

    /// Writes atomically (temp file + fsync + rename), mode 0600.
    public func write(to url: URL) throws {
        var w = Writer()
        w.raw(Self.magic)
        w.string(NameKey.version)
        w.string(fingerprint)
        w.int(seq)
        w.array(fileIds); w.array(parents); w.array(nameIds); w.array(flags); w.array(sizes); w.array(mtimes)
        w.array(subtreeEnd); w.array(names.bytes); w.array(names.offsets); w.array(nameKeyIds)
        w.array(keys.bytes); w.array(keys.offsets)
        w.int(Int64(rootPaths.count))
        for (id, path) in rootPaths.sorted(by: { $0.key < $1.key }) { w.int(id); w.string(path) }
        let crc = w.data.withUnsafeBytes { xs_crc32(0, $0.baseAddress, $0.count) }
        w.int(Int64(crc))

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try w.data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                off += n
            }
        }
        guard fsync(fd) == 0, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 { fsync(dfd); close(dfd) }
    }

    public static func load(from url: URL, expectedFingerprint: String) throws -> NameSnapshot {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count > 8 else { throw LoadError.badFormat }
        let body = data.prefix(data.count - 8)
        let stored = data.suffix(8).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        let crc = body.withUnsafeBytes { xs_crc32(0, $0.baseAddress, $0.count) }
        guard Int64(crc) == stored else { throw LoadError.checksum }
        var r = Reader(data: body)
        guard try r.raw(magic.count) == magic else { throw LoadError.badFormat }
        guard try r.string() == NameKey.version, try r.string() == expectedFingerprint else { throw LoadError.version }
        let seq = try r.int()
        let fileIds: [Int64] = try r.array(), parents: [Int32] = try r.array(), nameIds: [UInt32] = try r.array()
        let flags: [UInt8] = try r.array(), sizes: [Int64] = try r.array(), mtimes: [Int64] = try r.array()
        let subtreeEnd: [Int32] = try r.array()
        var names = StringPool(); names.bytes = try r.array(); names.offsets = try r.array()
        let nameKeyIds: [UInt32] = try r.array()
        var keys = StringPool(); keys.bytes = try r.array(); keys.offsets = try r.array()
        var rootPaths: [Int64: String] = [:]
        for _ in 0..<(try r.int()) { let id = try r.int(); rootPaths[id] = try r.string() }
        let n = fileIds.count
        guard parents.count == n, nameIds.count == n, flags.count == n, sizes.count == n, mtimes.count == n,
              subtreeEnd.count == n, nameKeyIds.count == names.count,
              names.offsets.last.map({ Int($0) == names.bytes.count }) ?? false,
              keys.offsets.last.map({ Int($0) == keys.bytes.count }) ?? false,
              nameIds.allSatisfy({ Int($0) < names.count }), nameKeyIds.allSatisfy({ Int($0) < keys.count }),
              parents.allSatisfy({ $0 >= -1 && Int($0) < n }), fileIds.allSatisfy({ $0 > 0 })
        else { throw LoadError.badFormat }
        return NameSnapshot(seq: seq, fingerprint: expectedFingerprint, fileIds: fileIds, parents: parents, nameIds: nameIds,
                            flags: flags, sizes: sizes, mtimes: mtimes, subtreeEnd: subtreeEnd, names: names,
                            nameKeyIds: nameKeyIds, keys: keys, rootPaths: rootPaths)
    }
}

private struct Writer {
    var data = Data()
    mutating func raw(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func int(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func string(_ s: String) { int(Int64(s.utf8.count)); data.append(contentsOf: Array(s.utf8)) }
    mutating func array<T: FixedWidthInteger>(_ a: [T]) {
        int(Int64(a.count))
        a.withUnsafeBytes { data.append(contentsOf: $0) }
    }
}

private struct Reader {
    let data: Data
    var offset: Int
    init(data: Data) { self.data = data; offset = data.startIndex }
    mutating func raw(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= data.endIndex else { throw NameSnapshot.LoadError.badFormat }
        defer { offset += n }
        return Array(data[offset..<offset + n])
    }
    mutating func int() throws -> Int64 {
        guard offset + 8 <= data.endIndex else { throw NameSnapshot.LoadError.badFormat }
        defer { offset += 8 }
        return Int64(littleEndian: data[offset..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
    }
    mutating func string() throws -> String { String(decoding: try raw(Int(try int())), as: UTF8.self) }
    mutating func array<T: FixedWidthInteger>() throws -> [T] {
        let n = Int(try int())
        let bytes = n * MemoryLayout<T>.stride
        guard n >= 0, offset + bytes <= data.endIndex else { throw NameSnapshot.LoadError.badFormat }
        defer { offset += bytes }
        return [T](unsafeUninitializedCapacity: n) { buf, count in
            data[offset..<offset + bytes].withUnsafeBytes { src in
                UnsafeMutableRawBufferPointer(buf).copyMemory(from: src)
            }
            count = n
        }
    }
}

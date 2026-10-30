import XSearchCore

public struct EntryFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let directory = EntryFlags(rawValue: 1)
    /// A package such as `.app`: shown as one item, contents not indexed by default.
    public static let package = EntryFlags(rawValue: 2)
    public static let symlink = EntryFlags(rawValue: 4)
    /// Listing this directory failed (permission): its old children are kept, not deleted.
    public static let noAccess = EntryFlags(rawValue: 8)

    public var isApp: Bool { contains(.package) }
}

/// One logical file-name entry. `fileId` is the catalog's stable id; `parentId` is 0 for a scan
/// root, whose `rootPath` holds its absolute path.
public struct NameRecord: Sendable, Equatable {
    public var fileId: Int64
    public var parentId: Int64
    public var name: String
    public var flags: EntryFlags
    public var size: Int64
    public var mtime: Int64
    public var rootPath: String?

    public init(fileId: Int64, parentId: Int64, name: String, flags: EntryFlags, size: Int64, mtime: Int64, rootPath: String? = nil) {
        self.fileId = fileId
        self.parentId = parentId
        self.name = name
        self.flags = flags
        self.size = size
        self.mtime = mtime
        self.rootPath = rootPath
    }
}

public enum NameChange: Sendable, Equatable {
    case upsert(NameRecord)
    case remove(Int64)
}

/// Concatenated UTF-8 strings addressed by index.
struct StringPool: Sendable {
    var bytes: [UInt8] = []
    var offsets: [UInt32] = [0]

    var count: Int { offsets.count - 1 }

    mutating func append<C: Collection>(_ s: C) where C.Element == UInt8 {
        bytes.append(contentsOf: s)
        precondition(bytes.count <= UInt32.max, "name pool exceeds 4 GB")
        offsets.append(UInt32(bytes.count))
    }

    func range(_ i: Int) -> Range<Int> { Int(offsets[i])..<Int(offsets[i + 1]) }
    func slice(_ i: Int) -> ArraySlice<UInt8> { bytes[range(i)] }
    func string(_ i: Int) -> String { String(decoding: slice(i), as: UTF8.self) }
}

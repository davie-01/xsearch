/// Content index scope (ARCHITECTURE §6.1): folders whose files are extracted, plus types and
/// limits. Configured separately from the file-name scope; first launch recommends only
/// ~/Downloads (D11).
public struct ContentScope: Codable, Sendable, Equatable {
    public var folders: [String]
    public var excludes: [String]
    public var types: Set<ContentType>
    /// Settings → 单文件上限.
    public var maxFileBytes: UInt64

    public init(folders: [String], excludes: [String] = [], types: Set<ContentType> = Set(ContentType.allCases), maxFileBytes: UInt64 = 100 << 20) {
        self.folders = folders
        self.excludes = excludes
        self.types = types
        self.maxFileBytes = maxFileBytes
    }

    public static let `default` = ContentScope(folders: ["~/Downloads"])

    public func roots(home: String) -> [String] {
        let paths = Set(folders.map { PathUtil.standardize(expand($0, home: home)) }).sorted()
        return paths.filter { p in !paths.contains { $0 != p && PathUtil.isWithin(p, $0) } }
    }

    /// Changes whenever the set of content-indexed files could change.
    public func fingerprint(home: String) -> String {
        [roots(home: home).joined(separator: "\u{1}"), excludes.map { expand($0, home: home) }.joined(separator: "\u{1}"),
         types.map(\.rawValue).sorted().joined(separator: ","), "\(maxFileBytes)"].joined(separator: "\u{2}")
    }
}

/// Content types extracted in M2 (D7: .doc and .docx together; OFD M3, WPS M4, OCR M6).
public enum ContentType: String, Codable, Sendable, CaseIterable {
    case text, docx, pdf, doc

    public var extensions: Set<String> {
        switch self {
        case .docx: ["docx", "docm"]
        case .pdf: ["pdf"]
        case .doc: ["doc", "dot"]
        case .text: [
            "txt", "text", "md", "markdown", "log", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "ini", "conf", "cfg",
            "swift", "rs", "c", "h", "m", "mm", "cc", "cpp", "hpp", "py", "js", "mjs", "ts", "tsx", "jsx", "go", "java", "kt",
            "rb", "php", "sh", "zsh", "bash", "fish", "html", "htm", "css", "scss", "sql", "lua", "r", "pl", "vue", "svelte",
        ]
        }
    }

    /// Type of a file name by extension (case-insensitive), or nil when not extractable.
    public static func of(name: String) -> ContentType? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        return allCases.first { $0.extensions.contains(ext) }
    }
}

/// Decides whether a catalogued file belongs in the content index.
public struct ContentRules: Sendable {
    public let roots: [String]
    let exclusions: ExclusionRules
    let types: Set<ContentType>

    public init(_ scope: ContentScope, home: String) {
        roots = scope.roots(home: home)
        exclusions = ExclusionRules(NameScope(wholeDisk: false, folders: scope.folders, excludes: scope.excludes,
                                              includeHidden: true, includePackageContents: true), home: home)
        types = scope.types
    }

    /// `path` is the file's absolute path; directories and packages are never content.
    public func eligible(path: String, name: String, isDirectory: Bool) -> Bool {
        guard !isDirectory, let type = ContentType.of(name: name), types.contains(type) else { return false }
        guard roots.contains(where: { PathUtil.isWithin(path, $0) }) else { return false }
        // Exclusion rules are checked on every component below the root, like the name scope.
        let root = roots.filter { PathUtil.isWithin(path, $0) }.max { $0.count < $1.count }!
        var current = root
        let rest = root == "/" ? Substring(path.dropFirst()) : path.dropFirst(root.count + 1)
        let parts = rest.split(separator: "/")
        for (i, part) in parts.enumerated() {
            current = (current == "/" ? "" : current) + "/" + part
            if exclusions.excludes(path: current, nameKey: NameKey.bytes(String(part)), isDirectory: i < parts.count - 1, isHidden: false) {
                return false
            }
        }
        return true
    }
}

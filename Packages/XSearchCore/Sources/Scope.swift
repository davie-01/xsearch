import Foundation

/// File-name index scope (ARCHITECTURE §6.1). The content scope is configured separately in M2.
public struct NameScope: Codable, Sendable, Equatable {
    public var wholeDisk: Bool
    public var folders: [String]
    public var excludes: [String]
    public var includeHidden: Bool
    public var includePackageContents: Bool
    /// Folders indexed although the scan above does not reach them (an exclusion rule covers
    /// their location, e.g. WeChat's files under ~/Library). Each becomes a root of its own.
    public var extraFolders: [String]

    public init(wholeDisk: Bool, folders: [String], excludes: [String], includeHidden: Bool, includePackageContents: Bool,
                extraFolders: [String] = []) {
        self.wholeDisk = wholeDisk
        self.folders = folders
        self.excludes = excludes
        self.includeHidden = includeHidden
        self.includePackageContents = includePackageContents
        self.extraFolders = extraFolders
    }

    /// Whole disk minus system directories, ~/Library, node_modules and .git (§6.1 defaults).
    /// External and network volumes live under /Volumes and are handled as partitions in M4.
    public static let defaultExcludes = [
        "/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/cores", "/opt", "/Volumes",
        "~/Library", "node_modules", ".git",
    ]

    public static let `default` = NameScope(
        wholeDisk: true, folders: [], excludes: defaultExcludes, includeHidden: false, includePackageContents: false)

    /// Effective scan roots, standardized, with nested roots removed. An extra folder is a root
    /// of its own when the scan of the others does not reach it, and left out when it does.
    public func roots(home: String) -> [String] {
        func nonNested(_ list: [String]) -> [String] {
            let paths = Set(list.map { PathUtil.standardize(expand($0, home: home)) }).sorted()
            return paths.filter { p in !paths.contains { $0 != p && PathUtil.isWithin(p, $0) } }
        }
        var roots = wholeDisk ? ["/"] : nonNested(folders)
        let rules = ExclusionRules(self, home: home)
        for extra in nonNested(extraFolders) where !roots.contains(where: { rules.reaches(extra, from: $0) }) {
            roots.removeAll { PathUtil.isWithin($0, extra) }
            roots.append(extra)
        }
        return roots.sorted()
    }

    /// Changes whenever the set of indexed entries could change; stored with the catalog.
    public func fingerprint(home: String) -> String {
        let rules = excludes.map { expand($0, home: home) }.joined(separator: "\u{1}")
        return [roots(home: home).joined(separator: "\u{1}"), rules, "\(includeHidden)", "\(includePackageContents)", NameKey.version]
            .joined(separator: "\u{2}")
    }
}

func expand(_ path: String, home: String) -> String {
    if path == "~" { return home }
    return path.hasPrefix("~/") ? home + path.dropFirst(1) : path
}

/// Decides which directory children are indexed. Evaluated while listing a directory, so an
/// excluded directory is never descended into and nothing below it reaches the catalog.
public struct ExclusionRules: Sendable {
    enum Rule: Sendable {
        case prefix(String)          // absolute path, component-bounded
        case component([UInt8])      // any path component equals this name
        case ext([UInt8])            // `*.log`; a bare `.git` is a component name
        case glob([[UInt8]])         // path segments; `**` spans directories
    }

    let rules: [Rule]
    public let includeHidden: Bool
    public let includePackageContents: Bool

    public init(_ scope: NameScope, home: String) {
        includeHidden = scope.includeHidden
        includePackageContents = scope.includePackageContents
        rules = scope.excludes.compactMap { raw in
            let rule = expand(raw.trimmingCharacters(in: .whitespaces), home: home)
            if rule.isEmpty { return nil }
            if rule.hasPrefix("/") && !rule.contains("*") { return .prefix(PathUtil.standardize(rule)) }
            if rule.hasPrefix("*.") && !rule.dropFirst(2).contains(where: { "*?/".contains($0) }) {
                return .ext(NameKey.bytes(String(rule.dropFirst(2))))
            }
            if !rule.contains("/") && !rule.contains("*") && !rule.contains("?") { return .component(NameKey.bytes(rule)) }
            var pattern = rule
            // `dir/**` means the directory itself and everything below; the subtree is pruned.
            if pattern.hasSuffix("/**") { pattern.removeLast(3) }
            let segments = pattern.split(separator: "/").map { $0 == "**" ? [0x2A, 0x2A] : NameKey.bytes(String($0)) }
            return .glob((pattern.hasPrefix("/") ? [] : [[0x2A, 0x2A]]) + segments)
        }
    }

    /// `path` is the child's absolute path, `nameKey` its folded name.
    /// `ignoringPrefixes`: for a folder chosen by absolute path, which outranks a rule that
    /// excludes that location as such; name, extension and hidden rules still apply inside.
    /// `root`: the scan root the path is under; a path rule covering the root itself (an extra
    /// folder inside ~/Library) is outranked there, rules for places inside it still apply.
    public func excludes(path: String, nameKey: [UInt8], isDirectory: Bool, isHidden: Bool, ignoringPrefixes: Bool = false,
                         root: String? = nil) -> Bool {
        if isHidden && !includeHidden { return true }
        var segmentKeys: [[UInt8]]?
        for rule in rules {
            switch rule {
            case .prefix(let p):
                if !ignoringPrefixes && PathUtil.isWithin(path, p) && !(root.map { PathUtil.isWithin($0, p) } ?? false) { return true }
            case .component(let c):
                if nameKey == c { return true }
            case .ext(let e):
                if !isDirectory, let ext = keyExtension(nameKey), ext.elementsEqual(e) { return true }
            case .glob(let segments):
                if segmentKeys == nil { segmentKeys = PathUtil.components(path).map(NameKey.bytes) }
                if globMatch(segments[...], segmentKeys![...]) { return true }
            }
        }
        return false
    }

    /// A path rule excludes `path` itself or a place inside it. Content folders outrank path
    /// rules, so there the catalog holds content-only entries a name scan alone would not list.
    public func hasPathRule(within path: String) -> Bool {
        rules.contains { rule in
            if case .prefix(let p) = rule { return PathUtil.isWithin(p, path) || PathUtil.isWithin(path, p) }
            return false
        }
    }

    /// Whether a scan of `root` reaches `path`: inside it, and no directory on the way (the path
    /// itself included) is excluded. Hidden means a leading dot here, as for event paths.
    public func reaches(_ path: String, from root: String) -> Bool {
        guard PathUtil.isWithin(path, root) else { return false }
        var current = root
        let rest = root == "/" ? Substring(path.dropFirst()) : path.dropFirst(root.count + 1)
        for component in rest.split(separator: "/") {
            current = (current == "/" ? "" : current) + "/" + component
            if excludes(path: current, nameKey: NameKey.bytes(String(component)), isDirectory: true, isHidden: component.hasPrefix("."), root: root) {
                return false
            }
        }
        return true
    }
}

func globMatch(_ pattern: ArraySlice<[UInt8]>, _ path: ArraySlice<[UInt8]>) -> Bool {
    guard let first = pattern.first else { return path.isEmpty }
    if first == [0x2A, 0x2A] {
        let rest = pattern.dropFirst()
        var p = path
        while true {
            if globMatch(rest, p) { return true }
            if p.isEmpty { return false }
            p = p.dropFirst()
        }
    }
    guard let segment = path.first, segmentMatch(first[...], segment[...]) else { return false }
    return globMatch(pattern.dropFirst(), path.dropFirst())
}

/// `*` matches any run within one segment, `?` one byte (names are matched on folded UTF-8).
func segmentMatch(_ p: ArraySlice<UInt8>, _ s: ArraySlice<UInt8>) -> Bool {
    guard let c = p.first else { return s.isEmpty }
    if c == 0x2A {
        var rest = s
        while true {
            if segmentMatch(p.dropFirst(), rest) { return true }
            if rest.isEmpty { return false }
            rest = rest.dropFirst()
        }
    }
    guard let h = s.first, c == 0x3F || c == h else { return false }
    return segmentMatch(p.dropFirst(), s.dropFirst())
}

// Field-by-field with defaults (see QuerySyntax): upgrades keep the user's scope.
extension NameScope {
    private enum CodingKeys: String, CodingKey { case wholeDisk, folders, excludes, includeHidden, includePackageContents, extraFolders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NameScope.default
        self.init(wholeDisk: try c.decodeIfPresent(Bool.self, forKey: .wholeDisk) ?? d.wholeDisk,
                  folders: try c.decodeIfPresent([String].self, forKey: .folders) ?? d.folders,
                  excludes: try c.decodeIfPresent([String].self, forKey: .excludes) ?? d.excludes,
                  includeHidden: try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? d.includeHidden,
                  includePackageContents: try c.decodeIfPresent(Bool.self, forKey: .includePackageContents) ?? d.includePackageContents,
                  extraFolders: try c.decodeIfPresent([String].self, forKey: .extraFolders) ?? d.extraFolders)
    }
}

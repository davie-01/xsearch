/// M1 name-mode query (ARCHITECTURE §12): literal substring terms (whitespace = AND, quotes keep
/// spaces, backslash escapes), plus `dir:`, `ext:` and `kind:` filters. Operators, wildcards and
/// regex come later and are deliberately treated as literal characters here.
public struct NameQuery: Sendable, Equatable {
    public enum DirFilter: Sendable, Equatable {
        /// Absolute path, as folded component keys ("/" is the empty list).
        case absolute(path: String, components: [[UInt8]])
        /// Relative fragment such as `dir:合同/2024`: consecutive ancestor directory names.
        case fragment(text: String, components: [[UInt8]])
    }

    public struct Chip: Sendable, Equatable {
        public var label: String
        public var valid: Bool
    }

    public var terms: [String] = []
    public var termKeys: [[UInt8]] = []
    public var dirs: [DirFilter] = []
    public var extensions: Set<String> = []
    public var kinds: Set<FileKind> = []
    public var chips: [Chip] = []
    /// Input started with `in ` (content mode request, M2).
    public var contentPrefix = false

    public var hasFilters: Bool { !dirs.isEmpty || !extensions.isEmpty || !kinds.isEmpty }
    public var isEmpty: Bool { termKeys.isEmpty && !hasFilters }

    public init() {}

    public static func parse(_ input: String, home: String) -> NameQuery {
        var q = NameQuery()
        var text = Substring(input)
        if text.hasPrefix("in ") {
            q.contentPrefix = true
            text = text.dropFirst(3)
        }
        for token in tokenize(text) {
            let lower = token.text.lowercased()
            // A filter prefix only counts when it was typed unquoted: `"dir:x"` is a literal term.
            func filter(_ name: String) -> String? {
                let prefix = name + ":"
                guard lower.hasPrefix(prefix), token.quotedFrom.map({ $0 >= prefix.count }) ?? true else { return nil }
                return String(token.text.dropFirst(prefix.count))
            }
            if let value = filter("dir") {
                guard !value.isEmpty else { continue }  // still typing
                q.dirs.append(dirFilter(value, home: home))
                q.chips.append(Chip(label: "dir:" + value, valid: true))
            } else if let value = filter("ext") {
                let exts = value.split(whereSeparator: { $0 == ";" || $0 == "," })
                    .map { NameKey.key(String($0.drop(while: { $0 == "." }))) }
                    .filter { !$0.isEmpty }
                guard !exts.isEmpty else { continue }
                q.extensions.formUnion(exts)
                q.chips.append(Chip(label: "ext:" + exts.joined(separator: ";"), valid: true))
            } else if let value = filter("kind") {
                guard !value.isEmpty else { continue }
                var valid = true
                for word in value.split(whereSeparator: { $0 == ";" || $0 == "," }) {
                    if let kind = FileKind.parse(String(word)) { q.kinds.insert(kind) } else { valid = false }
                }
                q.chips.append(Chip(label: "kind:" + value, valid: valid))
            } else if !token.text.isEmpty {
                q.terms.append(token.text)
                q.termKeys.append(NameKey.bytes(token.text))
            }
        }
        return q
    }

    struct Token { var text: String; var quotedFrom: Int? }

    static func tokenize(_ s: Substring) -> [Token] {
        var out: [Token] = []
        var current = "", count = 0, quotedFrom: Int?, inQuote = false, escape = false, started = false
        func flush() {
            if started { out.append(Token(text: current, quotedFrom: quotedFrom)) }
            current = ""; count = 0; quotedFrom = nil; started = false
        }
        for ch in s {
            if escape {
                current.append(ch); count += 1; escape = false; started = true
                quotedFrom = quotedFrom ?? (count - 1)
            } else if ch == "\\" {
                escape = true
            } else if ch == "\"" {
                inQuote.toggle(); started = true
                quotedFrom = quotedFrom ?? count
            } else if ch.isWhitespace && !inQuote {
                flush()
            } else {
                current.append(ch); count += 1; started = true
            }
        }
        if escape { current.append("\\") }
        flush()
        return out
    }

    static func dirFilter(_ raw: String, home: String) -> DirFilter {
        var path = raw
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        if path.hasPrefix("/") {
            let canonical = PathUtil.standardize(path)
            return .absolute(path: canonical, components: PathUtil.components(canonical).map(NameKey.bytes))
        }
        let parts = path.split(separator: "/").map(String.init)
        return .fragment(text: raw, components: parts.map(NameKey.bytes))
    }
}

public enum PathUtil {
    /// Collapses `//`, `.` and `..` and strips trailing slashes. Does not resolve symlinks: the
    /// catalog stores paths exactly as scanned.
    public static func standardize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func components(_ absolute: String) -> [String] {
        absolute.split(separator: "/").map(String.init)
    }

    /// Component-bounded prefix test: `/Work/A` covers `/Work/A/x` but not `/Work/Archive`.
    public static func isWithin(_ path: String, _ root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || (path.hasPrefix(root) && path.utf8.dropFirst(root.utf8.count).first == 0x2F)
    }

    public static func abbreviate(_ path: String, home: String) -> String {
        isWithin(path, home) ? "~" + path.dropFirst(home.count) : path
    }
}

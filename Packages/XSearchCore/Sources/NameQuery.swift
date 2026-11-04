import Foundation

/// Name-mode query (ARCHITECTURE §12): substring terms (whitespace = AND, quotes keep spaces,
/// backslash escapes), operators `|` / leading `-` / parentheses, wildcards, `regex:`, and the
/// `dir:` / `ext:` / `kind:` / `size:` / `dm:` filters. Switched-off syntax is literal text.
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

    public var expr: NameExpr?
    /// Positive literal texts (highlighting).
    public var terms: [String] = []
    /// AND-ed literal keys when the query is only that (fast path); empty otherwise.
    public var termKeys: [[UInt8]] = []
    public var dirs: [DirFilter] = []
    public var extensions: Set<String> = []
    public var kinds: Set<FileKind> = []
    public var size: ClosedRange<Int64>?
    public var modified: ClosedRange<Int64>?
    /// Tab on an app: only documents it can open (set by the launcher, not parsed).
    public var documentTypes: DocumentTypes?
    public var chips: [Chip] = []
    /// Input started with `in ` (content mode request, M2).
    public var contentPrefix = false

    /// Only AND-ed literals: matched by the M1 fast path.
    public var isSimple: Bool { expr == nil || !termKeys.isEmpty }
    public var hasFilters: Bool { !dirs.isEmpty || !extensions.isEmpty || !kinds.isEmpty || size != nil || modified != nil || documentTypes != nil }
    public var isEmpty: Bool { expr == nil && !hasFilters }

    public init() {}

    public static func parse(_ input: String, home: String, syntax: QuerySyntax = .default, now: Date = Date()) -> NameQuery {
        var q = NameQuery()
        var text = Substring(input)
        if text.hasPrefix("in ") {
            q.contentPrefix = true
            text = text.dropFirst(3)
        }
        var parser = Parser(pieces: tokenize(text, syntax: syntax), home: home, syntax: syntax, now: now, query: q)
        let expr = parser.or()
        q = parser.query
        q.expr = expr
        q.collectTerms()
        return q
    }

    private mutating func collectTerms() {
        func positives(_ e: NameExpr, _ out: inout [String]) {
            switch e {
            case .literal(let t, _): out.append(t)
            case .and(let xs), .or(let xs): xs.forEach { positives($0, &out) }
            default: break
            }
        }
        terms = []
        if let expr { positives(expr, &terms) }
        switch expr {
        case .literal(_, let key)?: termKeys = [key]
        case .and(let xs)?:
            let keys = xs.compactMap { if case .literal(_, let k) = $0 { k } else { nil } }
            termKeys = keys.count == xs.count ? keys : []
        default: termKeys = []
        }
    }

    enum Piece: Equatable { case word(Token), or, not, open, close, regex(String) }

    struct Parser {
        var pieces: [Piece]
        var at = 0
        let home: String
        let syntax: QuerySyntax
        let now: Date
        var query: NameQuery

        /// Lenient: a missing `)`, an empty side of `|` or a dangling `-` (still typing) are ignored.
        mutating func or() -> NameExpr? {
            var xs: [NameExpr] = []
            if let x = and() { xs.append(x) }
            while at < pieces.count && pieces[at] == .or {
                at += 1
                if let x = and() { xs.append(x) }
            }
            return xs.count <= 1 ? xs.first : .or(xs)
        }

        mutating func and() -> NameExpr? {
            var xs: [NameExpr] = []
            while at < pieces.count && pieces[at] != .or {
                if pieces[at] == .close {
                    at += 1
                    if depth > 0 { depth -= 1; break }
                    continue  // stray `)`
                }
                if let x = atom() { xs.append(x) }
            }
            return xs.count <= 1 ? xs.first : .and(xs)
        }

        var depth = 0
        /// Groups and negations around the current piece: each is a level of recursion here and
        /// when the tree is matched, so pasted input is cut off instead of running the stack out.
        var nesting = 0
        static let maxNesting = 64

        mutating func atom() -> NameExpr? {
            guard at < pieces.count else { return nil }
            let piece = pieces[at]
            at += 1
            if piece == .not || piece == .open {
                guard nesting < Self.maxNesting else {
                    query.chips.append(Chip(label: L("嵌套过深：括号和排除最多 %@ 层", "\(Self.maxNesting)"), valid: false))
                    at = pieces.count
                    return nil
                }
                nesting += 1
            }
            defer { if piece == .not || piece == .open { nesting -= 1 } }
            switch piece {
            case .not:
                return atom().map { .not($0) }
            case .open:
                depth += 1
                let before = depth
                let x = or()
                if depth == before { depth -= 1 }  // closed by end of input
                return x
            case .regex(let pattern):
                let valid = (try? NSRegularExpression(pattern: pattern)) != nil
                query.chips.append(Chip(label: "regex:" + pattern, valid: valid))
                return valid ? .regex(pattern) : nil
            case .word(let token):
                return word(token)
            case .or, .close:
                return nil
            }
        }

        mutating func word(_ token: Token) -> NameExpr? {
            let lower = token.text.lowercased()
            // A filter prefix only counts when it was typed unquoted: `"dir:x"` is a literal term.
            func filter(_ name: String) -> String? {
                let prefix = name + ":"
                guard lower.hasPrefix(prefix), token.quotedFrom.map({ $0 >= prefix.count }) ?? true else { return nil }
                return String(token.text.dropFirst(prefix.count))
            }
            if let value = filter("dir") {
                guard !value.isEmpty else { return nil }  // still typing
                query.dirs.append(dirFilter(value, home: home))
                query.chips.append(Chip(label: "dir:" + value, valid: true))
            } else if let value = filter("ext") {
                let exts = value.split(whereSeparator: { $0 == ";" || $0 == "," })
                    .map { NameKey.key(String($0.drop(while: { $0 == "." }))) }
                    .filter { !$0.isEmpty }
                guard !exts.isEmpty else { return nil }
                query.extensions.formUnion(exts)
                query.chips.append(Chip(label: "ext:" + exts.joined(separator: ";"), valid: true))
            } else if let value = filter("kind") {
                guard !value.isEmpty else { return nil }
                var valid = true
                for word in value.split(whereSeparator: { $0 == ";" || $0 == "," }) {
                    if let kind = FileKind.parse(String(word)) { query.kinds.insert(kind) } else { valid = false }
                }
                query.chips.append(Chip(label: "kind:" + value, valid: valid))
            } else if let value = filter("size") {
                guard !value.isEmpty else { return nil }
                let r = MetaFilter.size(value)
                if let r { query.size = intersect(query.size, r) }
                query.chips.append(Chip(label: "size:" + value, valid: r != nil))
            } else if let value = filter("dm") {
                guard !value.isEmpty else { return nil }
                let r = MetaFilter.modified(value, now: now)
                if let r { query.modified = intersect(query.modified, r) }
                query.chips.append(Chip(label: "dm:" + value, valid: r != nil))
            } else if !token.text.isEmpty {
                if syntax.wildcards && token.quotedFrom == nil && token.text.contains(where: { $0 == "*" || $0 == "?" }) {
                    return .wildcard(Glob(token.text, home: home))
                }
                return .literal(text: token.text, key: NameKey.bytes(token.text))
            }
            return nil
        }

        func intersect(_ a: ClosedRange<Int64>?, _ b: ClosedRange<Int64>) -> ClosedRange<Int64> {
            guard let a else { return b }
            // Disjoint filters match nothing (no file has size or mtime Int64.min).
            return a.overlaps(b) ? a.clamped(to: b) : Int64.min...Int64.min
        }
    }

    struct Token: Equatable { var text: String; var quotedFrom: Int? }

    static func tokenize(_ s: Substring, syntax: QuerySyntax = .default) -> [Piece] {
        let chars = Array(s)
        var out: [Piece] = []
        var current = "", count = 0, quotedFrom: Int?, inQuote = false, escape = false, started = false
        func flush() {
            if started { out.append(.word(Token(text: current, quotedFrom: quotedFrom))) }
            current = ""; count = 0; quotedFrom = nil; started = false
        }
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            defer { i += 1 }
            if escape {
                current.append(ch); count += 1; escape = false; started = true
                quotedFrom = quotedFrom ?? (count - 1)
                continue
            }
            if !inQuote && !started {
                // `regex:` runs to the next whitespace and keeps backslashes for the pattern.
                if syntax.regex && i + 6 <= chars.count && String(chars[i..<i + 6]).lowercased() == "regex:" {
                    var j = i + 6
                    var pattern = ""
                    while j < chars.count && !(chars[j].isWhitespace && !pattern.hasSuffix("\\")) { pattern.append(chars[j]); j += 1 }
                    if !pattern.isEmpty { out.append(.regex(pattern)) }
                    i = j - 1
                    continue
                }
                if syntax.operators {
                    if ch == "(" { out.append(.open); continue }
                    if ch == "-" {
                        // A lone `-` (still typing) is ignored.
                        if i + 1 < chars.count && !chars[i + 1].isWhitespace { out.append(.not) }
                        continue
                    }
                }
            }
            if !inQuote && syntax.operators && (ch == "|" || ch == ")") {
                flush()
                out.append(ch == "|" ? .or : .close)
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

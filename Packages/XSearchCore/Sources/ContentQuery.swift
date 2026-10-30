import Foundation

/// Content-mode input (ARCHITECTURE §12): `dir:` / `ext:` / `size:` / `dm:` filters are taken
/// out; everything else goes to the engine's parser (spaces = AND, `|`, leading `-`, quotes,
/// parens, `"甲 乙"~N`, `regex:`). Switched-off syntax is quoted so the engine reads it literally.
public struct ContentQuery: Sendable, Equatable {
    public var expression: String
    public var dirs: [String]
    public var exts: [String]
    public var chips: [NameQuery.Chip]
    /// Applied to hits after verification (bytes / Unix seconds).
    public var size: ClosedRange<Int64>?
    public var modified: ClosedRange<Int64>?

    public var isEmpty: Bool { expression.trimmingCharacters(in: .whitespaces).isEmpty }

    public func allows(size s: Int64, mtime: Int64) -> Bool {
        (size?.contains(s) ?? true) && (modified?.contains(mtime) ?? true)
    }

    public static func parse(_ input: String, home: String, syntax: QuerySyntax = .default, now: Date = Date()) -> ContentQuery {
        var q = ContentQuery(expression: "", dirs: [], exts: [], chips: [])
        var kept: [String] = []
        for raw in rawTokens(input) {
            let lower = raw.lowercased()
            if lower.hasPrefix("dir:") {
                var value = String(raw.dropFirst(4))
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                guard !value.isEmpty else { continue }
                if value == "~" { value = home } else if value.hasPrefix("~/") { value = home + value.dropFirst(1) }
                if value.hasPrefix("/") {
                    q.dirs.append(PathUtil.standardize(value))
                    q.chips.append(.init(label: "dir:" + String(raw.dropFirst(4)), valid: true))
                } else {
                    // Content filters need a real folder; name fragments only work in name mode.
                    q.chips.append(.init(label: "dir:" + value + "（内容模式需要完整路径）", valid: false))
                }
            } else if lower.hasPrefix("ext:") {
                let exts = raw.dropFirst(4).split(whereSeparator: { $0 == ";" || $0 == "," })
                    .map { String($0.drop(while: { $0 == "." })).lowercased() }.filter { !$0.isEmpty }
                guard !exts.isEmpty else { continue }
                q.exts += exts
                q.chips.append(.init(label: "ext:" + exts.joined(separator: ";"), valid: true))
            } else if lower.hasPrefix("size:") || lower.hasPrefix("dm:") {
                let isSize = lower.hasPrefix("size:")
                let value = String(raw.drop(while: { $0 != ":" }).dropFirst())
                guard !value.isEmpty else { continue }
                if isSize, let r = MetaFilter.size(value) {
                    q.size = q.size.map { $0.overlaps(r) ? $0.clamped(to: r) : Int64.min...Int64.min } ?? r
                    q.chips.append(.init(label: raw, valid: true))
                } else if !isSize, let r = MetaFilter.modified(value, now: now) {
                    q.modified = q.modified.map { $0.overlaps(r) ? $0.clamped(to: r) : Int64.min...Int64.min } ?? r
                    q.chips.append(.init(label: raw, valid: true))
                } else {
                    q.chips.append(.init(label: raw, valid: false))
                }
            } else {
                kept.append(literalize(raw, syntax))
            }
        }
        q.expression = kept.joined(separator: " ")
        return q
    }

    /// Rewrites a token so that switched-off syntax reaches the engine as plain text.
    static func literalize(_ raw: String, _ syntax: QuerySyntax) -> String {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        if raw.lowercased().hasPrefix("regex:") {
            return syntax.regex ? raw : quoted(raw)
        }
        var token = raw
        if !syntax.proximity, let r = token.range(of: #"^".+"~\d+$"#, options: .regularExpression), r == token.startIndex..<token.endIndex {
            token = token.replacingOccurrences(of: "\"~", with: "\"\\~")
        }
        if !syntax.operators && !token.contains("\"") && (token.hasPrefix("-") || token.contains(where: { "|()".contains($0) })) {
            token = quoted(token)
        }
        return token
    }

    /// Whitespace-separated tokens, keeping quoted runs (and their quotes) intact.
    static func rawTokens(_ s: String) -> [String] {
        var out: [String] = [], current = "", inQuote = false, escape = false
        for ch in s {
            if escape { current.append(ch); escape = false; continue }
            if ch == "\\" { current.append(ch); escape = true; continue }
            if ch == "\"" { inQuote.toggle() }
            if ch.isWhitespace && !inQuote {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

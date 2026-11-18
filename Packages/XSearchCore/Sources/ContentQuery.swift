import Foundation

/// Content-mode input (ARCHITECTURE §12): `dir:` / `ext:` / `name:` / `size:` / `dm:` filters are
/// taken out; everything else goes to the engine's parser (spaces = AND, `|`, leading `-`, quotes,
/// parens, `"甲 乙"~N`, `regex:`). Switched-off syntax is quoted so the engine reads it literally.
public struct ContentQuery: Sendable, Equatable {
    public var expression: String
    public var dirs: [String]
    public var exts: [String]
    public var chips: [NameQuery.Chip]
    /// Applied to hits after verification (bytes / Unix seconds).
    public var size: ClosedRange<Int64>?
    public var modified: ClosedRange<Int64>?
    /// `name:` conditions: the values of one token are OR-ed, several tokens AND-ed. A value is
    /// a case-insensitive part of the file name, or with `*` / `?` the whole name.
    public var names: [[String]] = []

    public var isEmpty: Bool { expression.trimmingCharacters(in: .whitespaces).isEmpty }

    public func allows(size s: Int64, mtime: Int64) -> Bool {
        (size?.contains(s) ?? true) && (modified?.contains(mtime) ?? true)
    }

    /// The engine applies `name:` itself; this is for files read outside the index (live scan).
    public func allows(name: String) -> Bool {
        guard !names.isEmpty else { return true }
        let key = NameKey.key(name)
        let scalars = Array(key.unicodeScalars)
        return names.allSatisfy { group in
            group.contains { value in
                let pattern = NameKey.key(value)
                guard pattern.contains("*") || pattern.contains("?") else { return key.contains(pattern) }
                return Self.glob(Array(pattern.unicodeScalars)[...], scalars[...])
            }
        }
    }

    /// Whole-name match: `*` any run, `?` one scalar (the engine's rule).
    static func glob(_ p: ArraySlice<Unicode.Scalar>, _ s: ArraySlice<Unicode.Scalar>) -> Bool {
        var p = p, s = s
        var star: (ArraySlice<Unicode.Scalar>, ArraySlice<Unicode.Scalar>)?
        while let c = s.first {
            if let h = p.first, h == "?" || h == c {
                p = p.dropFirst(); s = s.dropFirst()
            } else if p.first == "*" {
                star = (p.dropFirst(), s)
                p = p.dropFirst()
            } else if let (rest, at) = star {
                p = rest
                s = at.dropFirst()
                star = (rest, s)
            } else {
                return false
            }
        }
        return p.allSatisfy { $0 == "*" }
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
            } else if lower.hasPrefix("name:") {
                var value = String(raw.dropFirst(5))
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                let values = value.split(whereSeparator: { $0 == ";" || $0 == "," }).map(String.init).filter { !$0.isEmpty }
                guard !values.isEmpty else { continue }
                q.names.append(values)
                q.chips.append(.init(label: "name:" + values.joined(separator: ";"), valid: true))
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

extension ContentQuery {
    /// Extensions a live scan reads (§8.7): text types only, narrowed by `ext:`.
    public var liveExtensions: [String] {
        let text = ContentType.text.extensions
        return (exts.isEmpty ? Array(text) : exts.filter { text.contains($0) }).sorted()
    }
}

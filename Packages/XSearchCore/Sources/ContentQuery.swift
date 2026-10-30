import Foundation

/// Content-mode input (ARCHITECTURE §12): `dir:` / `ext:` filters are taken out; everything else
/// is passed unchanged to the engine's parser (spaces = AND, `|`, leading `-`, quotes, parens).
public struct ContentQuery: Sendable, Equatable {
    public var expression: String
    public var dirs: [String]
    public var exts: [String]
    public var chips: [NameQuery.Chip]

    public var isEmpty: Bool { expression.trimmingCharacters(in: .whitespaces).isEmpty }

    public static func parse(_ input: String, home: String) -> ContentQuery {
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
            } else {
                kept.append(raw)
            }
        }
        q.expression = kept.joined(separator: " ")
        return q
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

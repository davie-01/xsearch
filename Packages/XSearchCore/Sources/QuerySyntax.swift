import Foundation

/// Syntax switches (Settings → 搜索语法, ARCHITECTURE §12). A switched-off syntax is searched as
/// plain characters: with wildcards off, `*` is a literal asterisk.
public struct QuerySyntax: Codable, Sendable, Equatable {
    /// `|`, leading `-`, parentheses (both modes).
    public var operators = true
    /// `*` `?` `**` (name mode only).
    public var wildcards = true
    /// `regex:…`
    public var regex = true
    /// `"甲 乙"~N` (content mode only).
    public var proximity = true

    public init(operators: Bool = true, wildcards: Bool = true, regex: Bool = true, proximity: Bool = true) {
        self.operators = operators
        self.wildcards = wildcards
        self.regex = regex
        self.proximity = proximity
    }

    public static let `default` = QuerySyntax()
}

/// Name-mode boolean expression over folded name keys.
public indirect enum NameExpr: Sendable, Equatable {
    case literal(text: String, key: [UInt8])
    case wildcard(Glob)
    case regex(String)
    case and([NameExpr])
    case or([NameExpr])
    case not(NameExpr)
}

/// Wildcard pattern on folded keys: `*` any run without `/`, `**` any run, `?` one character
/// (not `/`). Without `/` it must match the whole name; with `/` the whole path (a relative
/// pattern may start in any folder).
public struct Glob: Sendable, Equatable {
    enum Op: Sendable, Equatable { case literal([UInt8]), star, globstar, any }

    public let text: String
    public let fullPath: Bool
    let ops: [Op]
    /// The name part of a path pattern, for a cheap check before the path is built; nil when it
    /// contains `**` (it could then span folders).
    let lastSegment: [Op]?

    public init(_ text: String, home: String) {
        self.text = text
        var pattern = text
        if pattern == "~" { pattern = home } else if pattern.hasPrefix("~/") { pattern = home + pattern.dropFirst(1) }
        fullPath = pattern.contains("/")
        if fullPath && !pattern.hasPrefix("/") && !pattern.hasPrefix("**") { pattern = "**/" + pattern }
        ops = Glob.compile(NameKey.bytes(pattern))
        if fullPath, let slash = pattern.lastIndex(of: "/") {
            let last = String(pattern[pattern.index(after: slash)...])
            lastSegment = last.contains("**") ? nil : Glob.compile(NameKey.bytes(last))
        } else {
            lastSegment = nil
        }
    }

    static func compile(_ bytes: [UInt8]) -> [Op] {
        var ops: [Op] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x2A {
                if i + 1 < bytes.count && bytes[i + 1] == 0x2A {
                    ops.append(.globstar)
                    i += 2
                    while i < bytes.count && bytes[i] == 0x2A { i += 1 }
                } else {
                    ops.append(.star)
                    i += 1
                }
            } else if b == 0x3F {
                ops.append(.any)
                i += 1
            } else {
                let n = scalarLength(b)
                ops.append(.literal(Array(bytes[i..<min(bytes.count, i + n)])))
                i += n
            }
        }
        return ops
    }

    public func matches(_ key: UnsafeBufferPointer<UInt8>) -> Bool { Glob.run(ops, key) }

    /// Anchored match, simulated as an NFA over UTF-8 scalars.
    static func run(_ ops: [Op], _ key: UnsafeBufferPointer<UInt8>) -> Bool {
        let m = ops.count
        var states = [Bool](repeating: false, count: m + 1)
        var next = states
        func close(_ s: inout [Bool]) {
            for j in 0..<m where s[j] {
                if ops[j] == .star || ops[j] == .globstar { s[j + 1] = true }
            }
        }
        states[0] = true
        close(&states)
        var i = 0
        while i < key.count {
            let n = min(Glob.scalarLength(key[i]), key.count - i)
            let slash = key[i] == 0x2F
            for j in 0..<m + 1 { next[j] = false }
            var any = false
            for j in 0..<m where states[j] {
                switch ops[j] {
                case .literal(let lit):
                    if lit.count == n && (0..<n).allSatisfy({ lit[$0] == key[i + $0] }) { next[j + 1] = true; any = true }
                case .any:
                    if !slash { next[j + 1] = true; any = true }
                case .star:
                    if !slash { next[j] = true; any = true }
                case .globstar:
                    next[j] = true; any = true
                }
            }
            guard any else { return false }
            close(&next)
            swap(&states, &next)
            i += n
        }
        return states[m]
    }

    public func matches(_ key: [UInt8]) -> Bool { key.withUnsafeBufferPointer { matches($0) } }

    /// Cheap check before the path is built: the name must match the pattern's last part.
    public func nameMayMatch(_ key: UnsafeBufferPointer<UInt8>) -> Bool { lastSegment.map { Glob.run($0, key) } ?? true }

    static func scalarLength(_ lead: UInt8) -> Int {
        switch lead {
        case 0..<0xC0: 1
        case 0xC0..<0xE0: 2
        case 0xE0..<0xF0: 3
        default: 4
        }
    }
}

/// `size:` and `dm:` values (ARCHITECTURE §12). Sizes are bytes (1024-based units), times are
/// Unix seconds; ranges are inclusive.
public enum MetaFilter {
    /// `>10mb` `<=1g` `1m..10m` `500k` (= within that unit) `empty`.
    public static func size(_ raw: String) -> ClosedRange<Int64>? {
        let s = raw.lowercased()
        if s == "empty" || s == "空" { return 0...0 }
        if let r = s.range(of: "..") {
            guard let a = sizeValue(String(s[..<r.lowerBound])), let b = sizeValue(String(s[r.upperBound...])) else { return nil }
            return range(a.value, b.value + b.unit - 1)
        }
        let (op, rest) = comparator(s)
        guard let v = sizeValue(rest) else { return nil }
        switch op {
        case ">": return range(v.value + 1, .max)
        case ">=": return range(v.value, .max)
        case "<": return range(0, v.value - 1)
        case "<=": return range(0, v.value)
        default: return range(v.value, v.value + v.unit - 1)
        }
    }

    /// `today` `thisweek` `7d` `2024` `2024-05` `2024-05-01` with `>` `>=` `<` `<=` or `a..b`.
    public static func modified(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Int64>? {
        let s = raw.lowercased()
        if let r = s.range(of: "..") {
            guard let a = period(String(s[..<r.lowerBound]), now: now, calendar: calendar),
                  let b = period(String(s[r.upperBound...]), now: now, calendar: calendar) else { return nil }
            return range(a.lowerBound, b.upperBound)
        }
        let (op, rest) = comparator(s)
        guard let p = period(rest, now: now, calendar: calendar) else { return nil }
        switch op {
        case ">": return range(p.upperBound + 1, .max)
        case ">=": return range(p.lowerBound, .max)
        case "<": return range(.min, p.lowerBound - 1)
        case "<=": return range(.min, p.upperBound)
        default: return p
        }
    }

    static func range(_ a: Int64, _ b: Int64) -> ClosedRange<Int64>? { a <= b ? a...b : nil }

    static func comparator(_ s: String) -> (String, String) {
        for op in [">=", "<=", ">", "<", "="] where s.hasPrefix(op) { return (op, String(s.dropFirst(op.count))) }
        return ("", s)
    }

    static func sizeValue(_ s: String) -> (value: Int64, unit: Int64)? {
        let units: [(String, Int64)] = [("tb", 1 << 40), ("gb", 1 << 30), ("mb", 1 << 20), ("kb", 1 << 10),
                                        ("t", 1 << 40), ("g", 1 << 30), ("m", 1 << 20), ("k", 1 << 10), ("b", 1)]
        let (suffix, unit) = units.first { s.hasSuffix($0.0) } ?? ("", 1)
        guard let n = Double(s.dropLast(suffix.count)), n >= 0, n * Double(unit) < 9e18 else { return nil }
        return (Int64(n * Double(unit)), unit)
    }

    static func period(_ s: String, now: Date, calendar cal: Calendar) -> ClosedRange<Int64>? {
        func span(_ start: Date?, _ unit: Calendar.Component, count: Int = 1) -> ClosedRange<Int64>? {
            guard let start, let end = cal.date(byAdding: unit, value: count, to: start) else { return nil }
            return Int64(start.timeIntervalSince1970)...Int64(end.timeIntervalSince1970) - 1
        }
        func current(_ unit: Calendar.Component, offset: Int = 0) -> ClosedRange<Int64>? {
            guard let start = cal.dateInterval(of: unit, for: now)?.start else { return nil }
            return span(cal.date(byAdding: unit, value: offset, to: start), unit)
        }
        switch s {
        case "today", "今天": return current(.day)
        case "yesterday", "昨天": return current(.day, offset: -1)
        case "thisweek", "本周": return current(.weekOfYear)
        case "lastweek", "上周": return current(.weekOfYear, offset: -1)
        case "thismonth", "本月": return current(.month)
        case "lastmonth", "上月": return current(.month, offset: -1)
        case "thisyear", "今年": return current(.year)
        case "lastyear", "去年": return current(.year, offset: -1)
        default: break
        }
        // Last N days / weeks / months / years, up to now.
        let relative: [(String, Calendar.Component)] = [("d", .day), ("天", .day), ("w", .weekOfYear), ("周", .weekOfYear),
                                                         ("m", .month), ("月", .month), ("y", .year), ("年", .year)]
        for (suffix, unit) in relative where s.hasSuffix(suffix) {
            guard let n = Int(s.dropLast(suffix.count)), n > 0, let from = cal.date(byAdding: unit, value: -n, to: now) else { continue }
            return Int64(from.timeIntervalSince1970)...Int64(now.timeIntervalSince1970)
        }
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." }).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }), let year = parts[0], year >= 1970, year < 3000 else { return nil }
        var c = DateComponents(year: year, month: 1, day: 1)
        if parts.count > 1 { c.month = parts[1] }
        if parts.count > 2 { c.day = parts[2] }
        guard (1...12).contains(c.month!), (1...31).contains(c.day!) else { return nil }
        return span(cal.date(from: c), [.year, .month, .day][parts.count - 1])
    }
}

// Settings decode field by field with defaults: a field added in a later version (or missing
// from an older one) never resets the user's other choices (M5: upgrades).
extension QuerySyntax {
    private enum CodingKeys: String, CodingKey { case operators, wildcards, regex, proximity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QuerySyntax.default
        self.init(operators: try c.decodeIfPresent(Bool.self, forKey: .operators) ?? d.operators,
                  wildcards: try c.decodeIfPresent(Bool.self, forKey: .wildcards) ?? d.wildcards,
                  regex: try c.decodeIfPresent(Bool.self, forKey: .regex) ?? d.regex,
                  proximity: try c.decodeIfPresent(Bool.self, forKey: .proximity) ?? d.proximity)
    }
}

import Foundation

/// The full window's condition bar (location, type, date, size, file name), written out as
/// ordinary filters appended to the input, so the engine treats them like typed ones.
public struct SearchConditions: Equatable, Sendable {
    /// Absolute or `~` paths (`dir:`), any of them.
    public var folders: [String] = []
    /// Name mode: `kind:` categories.
    public var kinds: Set<FileKind> = []
    /// Content mode: extracted types, as `ext:`.
    public var contentTypes: Set<ContentType> = []
    /// More extensions: `key numbers`, `.pdf;docx` …
    public var extensions = ""
    /// A `dm:` shortcut (`today`, `7d` …); the dates are used when it is nil.
    public var modified: String?
    public var modifiedFrom: Date?, modifiedTo: Date?
    /// In `sizeUnit` (`kb`, `mb`, `gb`); the lower end included, the upper end excluded.
    public var sizeMin: Double?, sizeMax: Double?
    public var sizeUnit = "mb"
    /// Content mode: `name:` values, `;` between alternatives.
    public var fileName = ""

    public init() {}

    public var hasFolders: Bool { !folders.isEmpty }
    public var hasTypes: Bool { !kinds.isEmpty || !contentTypes.isEmpty || !extensionList.isEmpty }
    public var hasModified: Bool { modified != nil || modifiedFrom != nil || modifiedTo != nil }
    public var hasSize: Bool { (sizeMin ?? 0) > 0 || sizeMax != nil }
    public var fileNames: [String] {
        fileName.split(whereSeparator: { $0 == ";" || $0 == "；" }).map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
    }

    public var extensionList: [String] {
        extensions.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "," || $0 == "，" || $0 == "；" })
            .map { String($0.drop(while: { $0 == "." || $0 == "*" })).lowercased() }.filter { !$0.isEmpty }
    }

    /// The conditions as filters. Each mode reads only its own fields: name mode has no `name:`
    /// (the words already match names) and content mode no `kind:`.
    public func clauses(content: Bool, calendar: Calendar = .current) -> [String] {
        var parts = folders.map { f in
            let dir = f.replacingOccurrences(of: "\"", with: "")
            return dir.contains(where: \.isWhitespace) ? "dir:\"" + dir + "\"" : "dir:" + dir
        }
        if content {
            let exts = ContentType.allCases.filter(contentTypes.contains).flatMap { $0.extensions.sorted() } + extensionList
            if !exts.isEmpty { parts.append("ext:" + exts.joined(separator: ";")) }
            if !fileNames.isEmpty { parts.append("name:\"" + fileNames.joined(separator: ";") + "\"") }
        } else {
            if !kinds.isEmpty { parts.append("kind:" + FileKind.allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ";")) }
            if !extensionList.isEmpty { parts.append("ext:" + extensionList.joined(separator: ";")) }
        }
        if let modified {
            parts.append("dm:" + modified)
        } else {
            let day = { (d: Date) in
                let c = calendar.dateComponents([.year, .month, .day], from: d)
                return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            }
            if let from = modifiedFrom { parts.append("dm:>=" + day(from)) }
            if let to = modifiedTo { parts.append("dm:<=" + day(to)) }
        }
        let size = { (v: Double) in (v == v.rounded() ? String(Int(v)) : String(v)) + sizeUnit }
        if let v = sizeMin, v > 0 { parts.append("size:>=" + size(v)) }
        if let v = sizeMax { parts.append("size:<" + size(v)) }
        return parts
    }

    /// The input with the conditions and the refine steps: the full window's query.
    public static func query(input: String, conditions: SearchConditions, steps: [Refinement], content: Bool,
                             syntax: QuerySyntax, calendar: Calendar = .current) -> String {
        let base = ([input.trimmingCharacters(in: .whitespaces)] + conditions.clauses(content: content, calendar: calendar)).filter { !$0.isEmpty }
        return Refinement.apply(steps, to: base.joined(separator: " "), syntax: syntax)
    }
}

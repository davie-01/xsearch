import Foundation

/// Why a content file could not be extracted, for people: the catalog stores whatever the
/// extractor or the engine said (“Index(message: "invalid Zip archive: …")”, “解析超时，已隔离”),
/// which reads like a log line. `summary` sorts it into a few plain, localized reasons; `detail`
/// keeps the technical text for the tooltip and for problem reports.
public struct ExtractionFailure: Equatable, Sendable {
    public var summary: String
    /// The original message without its error-type wrapper; nil when the summary says it all.
    public var detail: String?

    public init(_ raw: String) {
        let inner = Self.unwrap(raw)
        let lower = inner.lowercased()
        func has(_ words: String...) -> Bool { words.contains { lower.contains($0.lowercased()) } }
        let summary: String
        var technical = true
        if has("assword", "encrypted", "已加密") {
            summary = L("文件已加密，需要密码才能读取")
        } else if has("解析超时", "timed out", "timeout") {
            summary = L("解析超时，已跳过")
            technical = false
        } else if has("解析器崩溃", "crash") {
            summary = L("解析时出错退出，已跳过")
            technical = false
        } else if has("内存过多", "memory") {
            summary = L("解析占用内存过多，已跳过")
            technical = false
        } else if inner.hasPrefix("超过单文件上限") {
            summary = Loc.display(inner)
            technical = false
        } else if has("不支持的类型") {
            summary = L("不支持的文件类型")
        } else if has("compression method", "unsupported") {
            summary = L("使用了不支持的压缩或编码方式")
        } else if has("提取进程无法启动") {
            summary = L("提取进程无法启动")
        } else if has("invalid", "corrupt", "malformed", "eof", "无法打开", "无法读取", "damaged", "not a") {
            summary = L("文件已损坏或格式不正确")
        } else if inner.isEmpty {
            summary = L("未记录原因")
            technical = false
        } else {
            summary = L("无法读取这个文件")
        }
        self.summary = summary
        detail = technical && !inner.isEmpty ? inner : nil
    }

    /// One line for a report: the summary, then the technical text in brackets.
    public var report: String { detail.map { summary + "（" + $0 + "）" } ?? summary }

    /// `Index(message: "x")`, `Query(message: "x")` … → `x`; quarantine suffixes go too.
    static func unwrap(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let open = s.range(of: "(message: \""), s.hasSuffix("\")") {
            s = String(s[open.upperBound..<s.index(s.endIndex, offsetBy: -2)])
        }
        for suffix in ["，已隔离"] where s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        return s.replacingOccurrences(of: "\\\"", with: "\"")
    }
}

import Foundation
import Testing
@testable import XSearchCore

/// The app's Swift sources, read from the repository this test was built from.
private func appSources() throws -> [(name: String, text: String)] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../App/Sources").standardized
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".swift") }.sorted()
    return try names.map { ($0, try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) }
}

/// A line without its `//` comment (a `//` inside a string literal is kept).
private func code(_ line: String) -> String {
    var out = ""
    var inString = false
    var previous: Character = " "
    var chars = line.makeIterator()
    while let c = chars.next() {
        if !inString && c == "/" && previous == "/" { out.removeLast(); break }
        if c == "\"" && previous != "\\" { inString.toggle() }
        out.append(c)
        previous = c
    }
    return out
}

private let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)

/// Swift source text of a literal → its value (only the escapes the UI strings use).
private func value(_ source: String) -> String {
    source.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
}

@Test func everyAppStringHasEnglish() throws {
    let call = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)"(, context: "(\w+)")?"#)
    var missing: [String] = []
    for (name, text) in try appSources() {
        let ns = text as NSString
        for m in call.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = value(ns.substring(with: m.range(at: 1)))
            let context = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3))
            if englishStrings[context.map { key + "#" + $0 } ?? key] == nil { missing.append("\(name): \(key)") }
        }
    }
    #expect(missing.isEmpty, "no English for: \(missing)")
}

@Test func noChineseLiteralOutsideL() throws {
    var bare: [String] = []
    for (name, text) in try appSources() {
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.contains("// l10n:") {
            let c = code(String(line))
            let ns = c as NSString
            for m in literal.matches(in: c, range: NSRange(location: 0, length: ns.length)) {
                let s = ns.substring(with: m.range(at: 1))
                guard s.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { continue }
                if !ns.substring(to: m.range.location).hasSuffix("L(") { bare.append("\(name):\(n + 1): \(s)") }
            }
        }
    }
    #expect(bare.isEmpty, "wrap in L(…) or mark the line `// l10n: why`: \(bare)")
}

@Test func placeholdersAndPlurals() {
    #expect(fill("第 %@/%@ 处", ["2", "9"]) == "第 2/9 处")
    #expect(fill("%2$@ before %1$@", ["a", "b"]) == "b before a")
    #expect(fill(englishStrings["%@ 个文件"]!, ["1"]) == "1 file")
    #expect(fill(englishStrings["%@ 个文件"]!, ["1,234"]) == "1,234 files")
    #expect(fill("50% of %@", ["x"]) == "50% of x")
    #expect(fill("%@", ["%@"]) == "%@", "inserted text is not filled again")
}

@Test func engineMessagesAreTranslated() {
    #expect(Loc.english("页眉") == "Header")
    #expect(Loc.english("提取失败：解析超时，已隔离") == "Extraction failed: Parsing timed out; quarantined")
    #expect(Loc.english("第 3 章") == "Chapter 3")
    #expect(Loc.english("dir:合同（内容模式需要完整路径）") == "dir:合同 (content search needs a full path)")
    #expect(Loc.english("一段没有翻译的文字") == "一段没有翻译的文字", "unknown text is shown as it is")
    #expect(Loc.display("页眉") == "页眉", "tests run in Chinese")
}

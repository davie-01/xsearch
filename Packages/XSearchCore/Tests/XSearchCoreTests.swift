import Testing
@testable import XSearchCore

@Test func parsesM1Syntax() {
    let q = NameQuery.parse("合同 dir:~/Documents ext:.doc;DOCX kind:pdf report", home: "/Users/t")
    #expect(q.terms == ["合同", "report"])
    #expect(q.extensions == ["doc", "docx"])
    #expect(q.kinds == [.pdf])
    #expect(q.dirs == [.absolute(path: "/Users/t/Documents", components: ["users", "t", "documents"].map { Array($0.utf8) })])
    #expect(q.chips.map(\.label) == ["dir:~/Documents", "ext:doc;docx", "kind:pdf"])
}

@Test func quotesEscapesAndLiteralFilterText() {
    let q = NameQuery.parse(#""a b" \"x "dir:y" dir:"~/My Docs" a\ c"#, home: "/h")
    #expect(q.terms == ["a b", "\"x", "dir:y", "a c"])
    #expect(q.dirs == [.absolute(path: "/h/My Docs", components: ["h", "my docs"].map { Array($0.utf8) })])
    // Operators are M2: `|` and `-` are literal characters in M1.
    #expect(NameQuery.parse("a|b -c", home: "/").terms == ["a|b", "-c"])
}

@Test func incompleteAndInvalidFilters() {
    #expect(NameQuery.parse("dir: ext: kind:", home: "/").isEmpty)
    let q = NameQuery.parse("kind:nonsense", home: "/")
    #expect(q.chips == [NameQuery.Chip(label: "kind:nonsense", valid: false)])
    #expect(NameQuery.parse("in 合同", home: "/").contentPrefix)
    #expect(NameQuery.parse("dir:合同/2024", home: "/").dirs == [.fragment(text: "合同/2024", components: ["合同", "2024"].map { Array($0.utf8) })])
}

@Test func pathBoundaries() {
    #expect(PathUtil.isWithin("/Work/A/x", "/Work/A"))
    #expect(PathUtil.isWithin("/Work/A", "/Work/A"))
    #expect(!PathUtil.isWithin("/Work/Archive", "/Work/A"))
    #expect(PathUtil.isWithin("/x", "/"))
    #expect(PathUtil.standardize("/a//b/./c/../d/") == "/a/b/d")
    #expect(PathUtil.abbreviate("/Users/t/Docs", home: "/Users/t") == "~/Docs")
    #expect(PathUtil.abbreviate("/Users/tom", home: "/Users/t") == "/Users/tom")
}

@Test func exclusionRules() {
    let scope = NameScope(wholeDisk: true, folders: [], excludes: ["/System", "~/Library", "node_modules", "*.log", "**/build/**", "/Users/t/p/*/tmp"],
                          includeHidden: false, includePackageContents: false)
    let rules = ExclusionRules(scope, home: "/Users/t")
    func ex(_ path: String, dir: Bool = false, hidden: Bool = false) -> Bool {
        let name = String(path.split(separator: "/").last ?? "")
        return rules.excludes(path: path, nameKey: NameKey.bytes(name), isDirectory: dir, isHidden: hidden)
    }
    #expect(ex("/System", dir: true))
    #expect(!ex("/SystemX", dir: true))
    #expect(ex("/Users/t/Library", dir: true))
    #expect(ex("/Users/t/code/node_modules", dir: true))
    #expect(ex("/Users/t/a.LOG"))
    #expect(!ex("/Users/t/logs", dir: true))
    #expect(ex("/Users/t/x/build", dir: true))
    #expect(ex("/Users/t/p/q/tmp", dir: true))
    #expect(!ex("/Users/t/p/q/r/tmp", dir: true))
    #expect(ex("/Users/t/.zshrc", hidden: true))
    #expect(NameScope.default.roots(home: "/h") == ["/"])
    let folders = NameScope(wholeDisk: false, folders: ["~/a", "~/a/b", "/x/"], excludes: [], includeHidden: false, includePackageContents: false)
    #expect(folders.roots(home: "/h") == ["/h/a", "/x"])
}

@Test func kindsAndExtensions() {
    #expect(FileKind.parse("文件夹") == .folder)
    #expect(FileKind.parse("WORD") == .word)
    #expect(FileKind.of(extension: "docx", isDirectory: false, isApp: false) == .word)
    #expect(keyExtension(Array("a.tar.gz".utf8)).map { String(decoding: $0, as: UTF8.self) } == "gz")
    #expect(keyExtension(Array(".zshrc".utf8)) == nil)
}

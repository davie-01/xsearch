import Foundation
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
    // With operators switched off, `|` and `-` are literal characters.
    #expect(NameQuery.parse("a|b -c", home: "/", syntax: QuerySyntax(operators: false)).terms == ["a|b", "-c"])
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

@Test func extraFoldersBecomeRootsOnlyWhereTheScanDoesNotReach() {
    var scope = NameScope(wholeDisk: true, folders: [], excludes: ["~/Library", "node_modules", "/Users/t/Library/W/files/old"],
                          includeHidden: false, includePackageContents: false,
                          extraFolders: ["~/Library/W/files", "~/Documents/already", "~/code/node_modules/x"])
    #expect(scope.roots(home: "/Users/t") == ["/", "/Users/t/Library/W/files", "/Users/t/code/node_modules/x"],
            "a folder the whole-disk scan reaches is not scanned twice")
    let rules = ExclusionRules(scope, home: "/Users/t")
    let root = "/Users/t/Library/W/files"
    func ex(_ path: String, root: String?) -> Bool {
        rules.excludes(path: path, nameKey: NameKey.bytes(String(path.split(separator: "/").last!)), isDirectory: true, isHidden: false, root: root)
    }
    #expect(!ex(root + "/2025-04", root: root), "~/Library is outranked inside the extra folder")
    #expect(ex(root + "/old", root: root), "a rule for a place inside it still applies")
    #expect(ex(root + "/a/node_modules", root: root), "name rules still apply")
    #expect(ex("/Users/t/Library/Caches", root: "/"), "elsewhere ~/Library stays excluded")
    #expect(rules.reaches(root + "/2025-04", from: root))
    #expect(!rules.reaches(root, from: "/"))
    // Specified folders: an extra folder inside one of them is scanned with it.
    scope.wholeDisk = false
    scope.folders = ["~/Library/W"]
    scope.extraFolders = ["~/Library/W/files/new"]
    #expect(scope.roots(home: "/Users/t") == ["/Users/t/Library/W"])
}

@Test func kindsAndExtensions() {
    #expect(FileKind.parse("文件夹") == .folder)
    #expect(FileKind.parse("WORD") == .word)
    #expect(FileKind.of(extension: "docx", isDirectory: false, isApp: false) == .word)
    #expect(keyExtension(Array("a.tar.gz".utf8)).map { String(decoding: $0, as: UTF8.self) } == "gz")
    #expect(keyExtension(Array(".zshrc".utf8)) == nil)
}

@Test func contentQuerySplitsFilters() {
    let q = ContentQuery.parse(#"合同 "数据 共享" -草稿 dir:~/Downloads ext:.pdf;DOCX (AI | IP)"#, home: "/Users/t")
    #expect(q.expression == #"合同 "数据 共享" -草稿 (AI | IP)"#)
    #expect(q.dirs == ["/Users/t/Downloads"])
    #expect(q.exts == ["pdf", "docx"])
    #expect(q.chips.map(\.valid) == [true, true])
    let r = ContentQuery.parse(#"dir:"~/My Docs" x dir:合同"#, home: "/h")
    #expect(r.dirs == ["/h/My Docs"] && r.expression == "x" && r.chips.last?.valid == false)
    #expect(ContentQuery.parse("dir:/a ext:pdf", home: "/").isEmpty)
}

@Test func contentQueryNameFilter() {
    let q = ContentQuery.parse(#"支付条件 name:验收 name:"年度 报告;Contract" ext:pdf"#, home: "/")
    #expect(q.expression == "支付条件")
    #expect(q.names == [["验收"], ["年度 报告", "Contract"]])
    #expect(q.chips.map(\.label) == ["name:验收", "name:年度 报告;Contract", "ext:pdf"])
    #expect(ContentQuery.parse("name: x", home: "/").names.isEmpty)
    #expect(ContentQuery.parse("name:合同", home: "/").isEmpty, "a name alone is not a content query")
    // Live scan: the engine's rule — all tokens, any value; case-insensitive; * and ? whole-name.
    #expect(q.allows(name: "2026 验收 CONTRACT.pdf"))
    #expect(q.allows(name: "年度 报告-验收.docx"))
    #expect(!q.allows(name: "验收单.pdf"))
    let g = ContentQuery.parse("x name:*.md;报告?.txt", home: "/")
    #expect(g.allows(name: "Notes.MD") && g.allows(name: "报告1.txt"))
    #expect(!g.allows(name: "notes.md.bak") && !g.allows(name: "报告12.txt"))
    #expect(ContentQuery.parse("x", home: "/").allows(name: "anything"))
}

@Test func nameOperatorsWildcardsAndRegex() {
    func lit(_ t: String) -> NameExpr { .literal(text: t, key: Array(t.lowercased().utf8)) }
    #expect(NameQuery.parse("a b | c -d", home: "/").expr == .or([.and([lit("a"), lit("b")]), .and([lit("c"), .not(lit("d"))])]))
    #expect(NameQuery.parse("x (a | b", home: "/").expr == .and([lit("x"), .or([lit("a"), lit("b")])]))
    #expect(NameQuery.parse("a | ", home: "/").expr == lit("a"))
    #expect(NameQuery.parse("a - b)", home: "/").expr == .and([lit("a"), lit("b")]))
    let q = NameQuery.parse("a | b", home: "/")
    #expect(!q.isSimple && q.termKeys.isEmpty && q.terms == ["a", "b"])
    #expect(NameQuery.parse("a b", home: "/").isSimple)
    // Wildcards: unquoted only, and only when switched on.
    guard case .wildcard(let g)? = NameQuery.parse("报告?.DOCX", home: "/").expr else { Issue.record("no glob"); return }
    #expect(!g.fullPath && g.matches(Array("报告1.docx".utf8)) && !g.matches(Array("报告12.docx".utf8)))
    #expect(NameQuery.parse(#""*.doc""#, home: "/").expr == lit("*.doc"))
    #expect(NameQuery.parse("*.doc", home: "/", syntax: QuerySyntax(wildcards: false)).expr == lit("*.doc"))
    let star = Glob("*.pdf", home: "/"), path = Glob("**/合同/*.pdf", home: "/"), rel = Glob("合同/*.pdf", home: "/")
    #expect(star.matches(Array("a.pdf".utf8)) && !star.matches(Array("a.pdf.zip".utf8)))
    #expect(path.fullPath && path.matches(Array("/x/合同/a.pdf".utf8)) && path.matches(Array("/合同/a.pdf".utf8)))
    #expect(!path.matches(Array("/x/合同/sub/a.pdf".utf8)))
    #expect(rel.matches(Array("/u/合同/b.pdf".utf8)) && !rel.matches(Array("/u/旧合同/b.pdf".utf8)))
    #expect(Glob("/a/**", home: "/").matches(Array("/a/b/c".utf8)))
    // regex: keeps backslashes; an invalid pattern is an invalid chip and no term.
    #expect(NameQuery.parse(#"regex:^\d+\.txt$ x"#, home: "/").expr == .and([.regex(#"^\d+\.txt$"#), lit("x")]))
    let bad = NameQuery.parse("regex:( x", home: "/")
    #expect(bad.expr == lit("x") && bad.chips == [.init(label: "regex:(", valid: false)])
    #expect(NameQuery.parse("regex:a", home: "/", syntax: QuerySyntax(regex: false)).expr == lit("regex:a"))
}

@Test func sizeAndDateFilters() {
    #expect(MetaFilter.size(">10mb") == (10 << 20) + 1...Int64.max)
    #expect(MetaFilter.size("<=1k") == 0...1024)
    #expect(MetaFilter.size("1m..2m") == 1_048_576...3_145_727)
    #expect(MetaFilter.size("1.5k") == 1536...2559)
    #expect(MetaFilter.size("empty") == 0...0)
    #expect(MetaFilter.size("abc") == nil && MetaFilter.size("<0") == nil)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 15))!
    func t(_ y: Int, _ m: Int, _ d: Int) -> Int64 { Int64(cal.date(from: DateComponents(year: y, month: m, day: d))!.timeIntervalSince1970) }
    #expect(MetaFilter.modified("today", now: now, calendar: cal) == t(2026, 10, 30)...t(2026, 10, 31) - 1)
    #expect(MetaFilter.modified("昨天", now: now, calendar: cal) == t(2026, 10, 29)...t(2026, 10, 30) - 1)
    #expect(MetaFilter.modified("2024-05", now: now, calendar: cal) == t(2024, 5, 1)...t(2024, 6, 1) - 1)
    #expect(MetaFilter.modified(">=2025", now: now, calendar: cal) == t(2025, 1, 1)...Int64.max)
    #expect(MetaFilter.modified("<2025.03.01", now: now, calendar: cal) == Int64.min...t(2025, 3, 1) - 1)
    #expect(MetaFilter.modified("2024..2025-06", now: now, calendar: cal) == t(2024, 1, 1)...t(2025, 7, 1) - 1)
    #expect(MetaFilter.modified("7d", now: now, calendar: cal)?.lowerBound == Int64(now.timeIntervalSince1970) - 7 * 86400)
    #expect(MetaFilter.modified("2024-13", now: now, calendar: cal) == nil)
    let q = NameQuery.parse("size:>1k size:<1m dm:2024 dm:bad", home: "/")
    #expect(q.size == 1025...(1 << 20) - 1 && q.modified != nil && q.chips.map(\.valid) == [true, true, true, false])
    #expect(!q.isEmpty && q.expr == nil)
}

@Test func contentSyntaxSwitchesAndMetaFilters() {
    let on = ContentQuery.parse(#""合同 金额"~5 regex:\d+ -草稿 (a|b) size:>1k dm:2024"#, home: "/")
    #expect(on.expression == #""合同 金额"~5 regex:\d+ -草稿 (a|b)"#)
    #expect(on.size == 1025...Int64.max && on.modified != nil && on.chips.count == 2)
    #expect(on.allows(size: 2048, mtime: on.modified!.lowerBound) && !on.allows(size: 10, mtime: on.modified!.lowerBound))
    let off = ContentQuery.parse(#""合同 金额"~5 regex:\d+ -草稿 (a|b) "x y""#, home: "/", syntax: QuerySyntax(operators: false, regex: false, proximity: false))
    #expect(off.expression == #""合同 金额"\~5 "regex:\\d+" "-草稿" "(a|b)" "x y""#)
    #expect(ContentQuery.parse("size:huh", home: "/").chips == [.init(label: "size:huh", valid: false)])
}

@Test func contentScopeEnablesTypesAddedLater() throws {
    // Saved by M2 with PDF switched off: later types (sheet, slide, ofd, …) come up enabled.
    let old = #"{"folders":["~/Downloads"],"excludes":[],"types":["text","docx","doc"],"maxFileBytes":1024}"#
    let s = try JSONDecoder().decode(ContentScope.self, from: Data(old.utf8))
    #expect(!s.types.contains(.pdf) && s.types.contains(.sheet) && s.types.contains(.ofd) && s.maxFileBytes == 1024)
    // A round trip keeps the user's choice, including types switched off after this version.
    var now = s
    now.types.remove(.sheet)
    let again = try JSONDecoder().decode(ContentScope.self, from: JSONEncoder().encode(now))
    #expect(again == now)
}

@Test func liveScanFollowsExtFilter() {
    func exts(_ text: String) -> [String] { ContentQuery.parse(text, home: "/h", syntax: QuerySyntax()).liveExtensions }
    #expect(exts("合同") == ContentType.text.extensions.sorted())
    #expect(exts("合同 ext:txt") == ["txt"])
    #expect(exts("合同 ext:pdf").isEmpty, "not a text type: nothing to read live")
}

/// Pasted deep nesting is cut off with a visible chip, not parsed until the stack runs out.
@Test func nameQueryNestingIsBounded() {
    let ok = NameQuery.parse(String(repeating: "(", count: 64) + "a" + String(repeating: ")", count: 64), home: "/h")
    #expect(ok.chips.allSatisfy(\.valid) && ok.expr != nil)
    for input in [String(repeating: "(", count: 100_000) + "a", String(repeating: "-", count: 100_000) + "a"] {
        let q = NameQuery.parse(input, home: "/h")
        #expect(q.chips.contains { !$0.valid && $0.label.contains("嵌套过深") }, "\(q.chips.prefix(2))")
    }
}

@Test func refinementsAddTermsToTheQuery() {
    func lit(_ t: String) -> NameExpr { .literal(text: t, key: Array(t.lowercased().utf8)) }
    let all = Refinement(term: "甲  乙", kind: .all), any = Refinement(term: "试运行 验收", kind: .any), none = Refinement(term: "草稿", kind: .none)
    #expect(all.clause == "甲 乙" && any.clause == "(试运行 | 验收)" && none.clause == "-草稿")
    #expect(Refinement(term: "年度 报告", kind: .all, exact: true).clause == #""年度 报告""#)
    #expect(Refinement(term: "x", kind: .any).clause == "x")
    #expect(Refinement.apply([all, any, none], to: "合同", syntax: .default) == "合同 甲 乙 (试运行 | 验收) -草稿")
    #expect(Refinement.apply([], to: "a | b", syntax: .default) == "a | b")
    // OR is grouped first, and filters inside the group are still filters.
    let text = Refinement.apply([none], to: "a | b ext:pdf", syntax: .default)
    #expect(text == "( a | b ext:pdf ) -草稿")
    let name = NameQuery.parse(text, home: "/")
    #expect(name.expr == .and([.or([lit("a"), lit("b")]), .not(lit("草稿"))]))
    #expect(name.extensions == ["pdf"])
    #expect(ContentQuery.parse(text, home: "/").expression == "( a | b ) -草稿")
    // Words the parser would read as syntax are quoted, and stay literal.
    #expect(Refinement(term: #"*.pdf dir:x -a "年度 报告""#, kind: .all).clause == #""*.pdf" "dir:x" "-a" "年度 报告""#)
    #expect(ContentQuery.parse(Refinement.apply([Refinement(term: "dir:x", kind: .all)], to: "y", syntax: .default), home: "/").dirs.isEmpty)
    // Without the operators OR and NOT cannot be written: those steps are left out.
    let plain = QuerySyntax(operators: false)
    #expect(!none.isUsable(plain) && !any.isUsable(plain) && all.isUsable(plain))
    #expect(Refinement.apply([all, none], to: "a", syntax: plain) == "a 甲 乙")
    #expect(Refinement.apply([Refinement(term: "  ", kind: .all)], to: "a", syntax: .default) == "a")
    #expect(Refinement.and("a | b", "c", syntax: .default) == "( a | b ) c")
    #expect(Refinement.and("", "c", syntax: .default) == "c" && Refinement.and("a", "", syntax: .default) == "a")
}

@Test func searchConditionsWriteFilters() {
    var c = SearchConditions()
    c.folders = ["~/Work Files", "/tmp"]
    c.kinds = [.pdf, .folder]
    c.contentTypes = [.sheet, .pdf]
    c.extensions = ".KEY, numbers"
    c.fileName = "验收；报告"
    c.sizeMin = 1.5
    c.sizeMax = 100
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    c.modifiedFrom = cal.date(from: DateComponents(year: 2026, month: 1, day: 5))
    c.modifiedTo = cal.date(from: DateComponents(year: 2026, month: 3, day: 31))
    // Name mode: kind:, no name:; content mode: types as extensions, name:.
    #expect(c.clauses(content: false, calendar: cal) == [#"dir:"~/Work Files""#, "dir:/tmp", "kind:folder;pdf", "ext:key;numbers",
                                                        "dm:>=2026-01-05", "dm:<=2026-03-31", "size:>=1.5mb", "size:<100mb"])
    let text = SearchConditions.query(input: "支付条件", conditions: c, steps: [Refinement(term: "草稿", kind: .none)], content: true, syntax: .default, calendar: cal)
    let q = ContentQuery.parse(text, home: "/h")
    #expect(q.expression == "支付条件 -草稿")
    #expect(q.names == [["验收", "报告"]] && q.dirs == ["/h/Work Files", "/tmp"])
    #expect(Set(q.exts) == ["pdf", "ods", "xls", "xlsm", "xlsx", "et", "key", "numbers"])
    #expect(q.size == Int64(1.5 * 1_048_576)...(100 * 1_048_576 - 1))
    #expect(!q.chips.contains { !$0.valid })
    // A shortcut wins over dates; nothing set writes nothing.
    c.modified = "7d"
    #expect(c.clauses(content: false, calendar: cal).contains("dm:7d") && !c.clauses(content: false, calendar: cal).contains { $0.hasPrefix("dm:>") })
    #expect(SearchConditions().clauses(content: true).isEmpty)
    #expect(SearchConditions.query(input: "a | b", conditions: SearchConditions(), steps: [], content: false, syntax: .default) == "a | b")
}

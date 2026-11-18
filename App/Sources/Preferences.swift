import Foundation
import Catalog
import ContentEngine
import XSearchCore

/// Settings (§6.4). Stored in UserDefaults; indexes live under Application Support.
@MainActor
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    enum SummonMode: String { case alwaysName, rememberLast }
    enum Mode: Int { case name = 0, content = 1 }

    var nameScope: NameScope {
        get {
            guard let data = defaults.data(forKey: "nameScope"), let scope = try? JSONDecoder().decode(NameScope.self, from: data) else { return .default }
            return scope
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "nameScope") }
    }

    /// Content index scope; first launch recommends only ~/Downloads (D11).
    var contentScope: ContentScope {
        get {
            guard let data = defaults.data(forKey: "contentScope"), let scope = try? JSONDecoder().decode(ContentScope.self, from: data) else { return .default }
            return scope
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "contentScope") }
    }

    /// Settings → 搜索语法 (ARCHITECTURE §12).
    var querySyntax: QuerySyntax {
        get {
            guard let data = defaults.data(forKey: "querySyntax"), let s = try? JSONDecoder().decode(QuerySyntax.self, from: data) else { return .default }
            return s
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "querySyntax") }
    }

    /// Settings → 搜索语法 → 内容匹配模式.
    var matchMode: String {
        get { defaults.string(forKey: "matchMode") ?? "loose" }
        set { defaults.set(newValue, forKey: "matchMode") }
    }

    var contentMatchMode: MatchMode {
        switch matchMode {
        case "caseSensitive": .caseSensitive
        case "strict": .strict
        default: .loose
        }
    }

    /// Settings → 打开方式.
    var openWith: OpenWith {
        get {
            guard let data = defaults.data(forKey: "openWith"), let o = try? JSONDecoder().decode(OpenWith.self, from: data) else { return OpenWith() }
            return o
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "openWith") }
    }

    var hotKey: HotKey.Combo {
        get {
            guard let data = defaults.data(forKey: "hotKey"), let c = try? JSONDecoder().decode(HotKey.Combo.self, from: data) else { return .optionSpace }
            return c
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "hotKey") }
    }

    var summonMode: SummonMode {
        get { SummonMode(rawValue: defaults.string(forKey: "summonMode") ?? "") ?? .alwaysName }
        set { defaults.set(newValue.rawValue, forKey: "summonMode") }
    }

    /// Settings › 内容索引 › 索引速度.
    var indexingMode: IndexingMode {
        get { defaults.string(forKey: "indexingMode").flatMap(IndexingMode.init) ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: "indexingMode") }
    }

    /// Content indexing paused from the menu bar or Settings; survives restarts.
    var contentIndexingPaused: Bool {
        get { defaults.bool(forKey: "contentIndexingPaused") }
        set { defaults.set(newValue, forKey: "contentIndexingPaused") }
    }

    /// Settings › 通用 › 历史记录: keep the last query in the box when summoned.
    var keepLastQuery: Bool {
        get { defaults.object(forKey: "keepLastQuery") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepLastQuery") }
    }

    /// Settings › 通用 › 历史记录: list recently opened files under an empty box.
    var showRecents: Bool {
        get { defaults.object(forKey: "showRecents") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showRecents") }
    }

    /// The first-launch guide was shown (or the install predates it).
    var onboarded: Bool {
        get { defaults.bool(forKey: "onboarded") }
        set { defaults.set(newValue, forKey: "onboarded") }
    }

    var lastMode: Mode {
        get { Mode(rawValue: defaults.integer(forKey: "lastMode")) ?? .name }
        set { defaults.set(newValue.rawValue, forKey: "lastMode") }
    }

    /// ~/Library/Application Support/XSearch, mode 0700 (§15).
    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("XSearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        return dir
    }
}

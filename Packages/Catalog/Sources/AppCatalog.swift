import Foundation
import XSearchCore

/// Application launcher index (ARCHITECTURE §7): scanned directly from the application folders,
/// independent of Spotlight and of the file-name scope. Matches bundle and localized names only.
public struct AppEntry: Sendable, Equatable {
    public var path: String
    public var displayName: String
    public var keys: [[UInt8]]
}

public enum AppCatalog {
    public static func folders(home: String) -> [String] {
        ["/Applications", "/System/Applications", home + "/Applications"]
    }

    /// Top-level `.app` bundles plus one level of plain subfolders (e.g. Utilities).
    public static func scan(home: String = NSHomeDirectory()) -> [AppEntry] {
        let fm = FileManager.default
        var out: [AppEntry] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard seen.insert(path).inserted else { return }
            let bundle = Bundle(path: path)
            let info = bundle?.infoDictionary ?? [:]
            let localized = bundle?.localizedInfoDictionary ?? [:]
            let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let display = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            var names = [display, file]
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let v = localized[key] as? String { names.append(v) }
                if let v = info[key] as? String { names.append(v) }
            }
            var unique: [String] = []
            for n in names where !n.isEmpty && !unique.contains(n) { unique.append(n) }
            out.append(AppEntry(path: path, displayName: display, keys: unique.map(NameKey.bytes)))
        }
        for folder in folders(home: home) {
            guard let items = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for item in items {
                let path = folder + "/" + item
                if item.hasSuffix(".app") { add(path); continue }
                var isDir: ObjCBool = false
                guard !item.hasPrefix("."), fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                      let sub = try? fm.contentsOfDirectory(atPath: path) else { continue }
                for s in sub where s.hasSuffix(".app") { add(path + "/" + s) }
            }
        }
        return out
    }

    /// Apps whose any name contains every term; ranked exact > prefix > substring, then name.
    public static func search(_ apps: [AppEntry], _ q: NameQuery, usage: [String: Int] = [:]) -> [AppEntry] {
        guard !q.termKeys.isEmpty, !q.hasFilters || q.kinds == [.app] else { return [] }
        func level(_ app: AppEntry) -> Int {
            var best = 0
            for key in app.keys {
                guard q.termKeys.allSatisfy({ contains(key, $0) }) else { continue }
                let first = q.termKeys[0]
                let l = key == first ? 3 : key.starts(with: first) ? 2 : 1
                best = max(best, l)
            }
            return best
        }
        return apps.map { ($0, level($0)) }.filter { $0.1 > 0 }.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            let ua = usage[a.0.path] ?? 0, ub = usage[b.0.path] ?? 0
            if ua != ub { return ua > ub }
            return a.0.displayName.localizedStandardCompare(b.0.displayName) == .orderedAscending
        }.map(\.0)
    }

    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= hay.count else { return false }
        if needle.isEmpty { return true }
        return (0...(hay.count - needle.count)).contains { i in hay[i..<i + needle.count].elementsEqual(needle) }
    }
}

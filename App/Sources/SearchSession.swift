import AppKit
import Catalog
import NameEngine
import XSearchCore

/// One result row in the launcher list.
struct ResultItem: Equatable {
    enum Group: String { case apps = "应用", files = "文件与文件夹", recents = "最近打开" }
    var group: Group
    var name: String
    var path: String
    var fileId: Int64?
    var kind: FileKind
    var ext: String
    var meta: String
}

struct SearchOutput {
    var query: NameQuery
    var text: String
    var items: [ResultItem]
    var total: Int
    var elapsedMs: Double
    var unresolvedDirs: [String]
}

/// QuerySession (ARCHITECTURE §5): searches run off the main thread; only the latest request's
/// result is delivered. Name mode has no debounce (UI-SPEC §6.1).
@MainActor
final class SearchSession {
    let names: NameService
    let usage: UsageStore?
    private let queue = DispatchQueue(label: "xsearch.query", qos: .userInteractive)
    private var latest = 0
    private var apps: [AppEntry] = []
    private var appsScannedAt = Date.distantPast
    let home = NSHomeDirectory()

    init(names: NameService, usage: UsageStore?) {
        self.names = names
        self.usage = usage
    }

    /// Re-reads the application folders at most once a minute (on panel show).
    var onAppsLoaded: (() -> Void)?

    func refreshApps() {
        guard Date().timeIntervalSince(appsScannedAt) > 60 else { return }
        appsScannedAt = Date()
        let home = self.home
        queue.async {
            let scanned = AppCatalog.scan(home: home)
            Task { @MainActor in
                let changed = scanned != self.apps
                self.apps = scanned
                if changed { self.onAppsLoaded?() }
            }
        }
    }

    func search(_ text: String, deliver: @escaping @MainActor (SearchOutput) -> Void) {
        latest += 1
        let id = latest
        let names = self.names, usage = self.usage, apps = self.apps, home = self.home
        queue.async {
            let start = DispatchTime.now()
            let q = NameQuery.parse(text, home: home)
            var items: [ResultItem] = []
            var total = 0
            var unresolved: [String] = []
            if q.isEmpty {
                for r in usage?.recents() ?? [] where FileManager.default.fileExists(atPath: r.path) {
                    items.append(Self.item(path: r.path, fileId: r.fileId, group: .recents))
                }
            } else {
                let counts = usage?.usage() ?? (byId: [:], byPath: [:])
                let appHits = AppCatalog.search(apps, q, usage: counts.byPath).prefix(6)
                for a in appHits {
                    items.append(ResultItem(group: .apps, name: a.displayName, path: a.path, fileId: nil, kind: .app, ext: "app", meta: "应用"))
                }
                let appPaths = Set(appHits.map(\.path))
                let result = names.search(q, limit: 200, usage: counts.byId)
                total = result.total + appHits.count
                unresolved = result.unresolvedDirs
                for h in result.hits where !appPaths.contains(h.path) {
                    let ext = (h.name as NSString).pathExtension.lowercased()
                    // Packages (.framework, .bundle, …) are shown like files, not folders.
                    let isFolder = h.flags.contains(.directory) && !h.flags.contains(.package)
                    let kind = FileKind.of(extension: NameKey.key(ext), isDirectory: isFolder, isApp: h.flags.isApp && ext == "app")
                    let meta = kind == .folder ? "文件夹" : kind == .app ? "应用" : Theme.shortDate(h.mtime)
                    items.append(ResultItem(group: .files, name: h.name, path: h.path, fileId: h.fileId, kind: kind, ext: ext, meta: meta))
                }
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
            let out = SearchOutput(query: q, text: text, items: items, total: total, elapsedMs: ms, unresolvedDirs: unresolved)
            Task { @MainActor in
                guard id == self.latest else { return }
                deliver(out)
            }
        }
    }

    nonisolated static func item(path: String, fileId: Int64?, group: ResultItem.Group) -> ResultItem {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let isApp = ext == "app" && isDir.boolValue
        let kind = FileKind.of(extension: ext, isDirectory: isDir.boolValue, isApp: isApp)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let meta = kind == .folder ? "文件夹" : kind == .app ? "应用" : Theme.shortDate(Int64(mtime))
        return ResultItem(group: group, name: isApp ? (name as NSString).deletingPathExtension : name, path: path, fileId: fileId, kind: kind, ext: ext, meta: meta)
    }
}

import AppKit
import Catalog
import NameEngine
import os
import XSearchCore

/// One result row in the launcher list.
struct ResultItem: Equatable {
    enum Group: String { case apps = "应用", files = "文件与文件夹", favorites = "收藏", recents = "最近打开" }
    var group: Group
    var name: String
    var path: String
    var fileId: Int64?
    var kind: FileKind
    var ext: String
    var meta: String
    var size: Int64 = 0
    var mtime: Int64 = 0
}

struct ContentStats {
    var indexed = 0
    var pending = 0
    var failed = 0
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
    /// `latest` for the query queue: requests already replaced are skipped, not computed.
    private let latestRequest = OSAllocatedUnfairLock(initialState: 0)
    private var apps: [AppEntry] = []
    private var appsScannedAt = Date.distantPast
    let home = NSHomeDirectory()
    let content = ContentSearcher()
    /// Content index figures for the footer and "no results" text.
    var contentStats: (() -> ContentStats)?

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

    func search(_ text: String, limit: Int = 200, documentTypes: DocumentTypes? = nil, deliver: @escaping @MainActor (SearchOutput) -> Void) {
        latest += 1
        let id = latest
        latestRequest.withLock { $0 = id }
        let gate = latestRequest
        let names = self.names, usage = self.usage, apps = self.apps, home = self.home
        let syntax = Preferences.shared.querySyntax
        let showRecents = Preferences.shared.showRecents
        queue.async {
            guard gate.withLock({ $0 }) == id else { return }
            let start = DispatchTime.now()
            var q = NameQuery.parse(text, home: home, syntax: syntax)
            q.documentTypes = documentTypes
            var items: [ResultItem] = []
            var total = 0
            var unresolved: [String] = []
            if q.isEmpty {
                // Favorites follow their file id when the file moved (§13); missing ones stay
                // listed so they can be removed.
                var shown = Set<String>()
                for f in usage?.favorites() ?? [] {
                    var path = f.path
                    if !FileManager.default.fileExists(atPath: path), let id = f.fileId, let moved = names.view.path(id), moved != path,
                       FileManager.default.fileExists(atPath: moved) {
                        usage?.relocateFavorite(from: path, to: moved)
                        path = moved
                    }
                    shown.insert(path)
                    items.append(Self.item(path: path, fileId: f.fileId, group: .favorites))
                }
                for r in (showRecents ? usage?.recents() ?? [] : []) where !shown.contains(r.path) && FileManager.default.fileExists(atPath: r.path) {
                    items.append(Self.item(path: r.path, fileId: r.fileId, group: .recents))
                }
            } else {
                let counts = usage?.usage() ?? (byId: [:], byPath: [:])
                let appHits = AppCatalog.search(apps, q, usage: counts.byPath).prefix(6)
                for a in appHits {
                    items.append(ResultItem(group: .apps, name: a.displayName, path: a.path, fileId: nil, kind: .app, ext: "app", meta: "应用"))
                }
                let appPaths = Set(appHits.map(\.path))
                let result = names.search(q, limit: limit, usage: counts.byId)
                total = result.total + appHits.count
                unresolved = result.unresolvedDirs
                for h in result.hits where !appPaths.contains(h.path) {
                    let ext = (h.name as NSString).pathExtension.lowercased()
                    // Packages (.framework, .bundle, …) are shown like files, not folders.
                    let isFolder = h.flags.contains(.directory) && !h.flags.contains(.package)
                    let kind = FileKind.of(extension: NameKey.key(ext), isDirectory: isFolder, isApp: h.flags.isApp && ext == "app")
                    let meta = kind == .folder ? "文件夹" : kind == .app ? "应用" : Theme.shortDate(h.mtime)
                    items.append(ResultItem(group: .files, name: h.name, path: h.path, fileId: h.fileId, kind: kind, ext: ext, meta: meta,
                                            size: h.size, mtime: h.mtime))
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

    /// Text-type files under `dirs` from the name index, for the live scan (§8.7): the name
    /// scope's exclusion rules apply as they do everywhere else. `truncated`: a folder had more
    /// candidates than one scan reads.
    func liveFiles(dirs: [String], extensions: [String]) -> (files: [LiveFile], unresolved: [String], truncated: Bool) {
        guard !extensions.isEmpty else { return ([], [], false) }
        let exts = extensions.joined(separator: ";")
        let limit = 200_000
        var files: [LiveFile] = []
        var seen = Set<Int64>()  // overlapping folders
        var unresolved: [String] = []
        var truncated = false
        for d in dirs {
            let q = NameQuery.parse("dir:\"\(d)\" ext:\(exts)", home: home)
            let r = names.search(q, limit: limit)
            unresolved += r.unresolvedDirs
            truncated = truncated || r.total > r.hits.count
            for h in r.hits where !h.flags.contains(.directory) && seen.insert(h.fileId).inserted {
                files.append(LiveFile(fileId: h.fileId, path: h.path, size: h.size, mtime: h.mtime))
            }
        }
        // Newest first, like indexed results.
        return (files.sorted { $0.mtime > $1.mtime }, unresolved, truncated)
    }

    nonisolated static func item(path: String, fileId: Int64?, group: ResultItem.Group) -> ResultItem {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let isApp = ext == "app" && isDir.boolValue
        let kind = FileKind.of(extension: ext, isDirectory: isDir.boolValue, isApp: isApp)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let missing = attrs == nil
        let meta = missing ? "文件已不存在" : kind == .folder ? "文件夹" : kind == .app ? "应用" : Theme.shortDate(Int64(mtime))
        return ResultItem(group: group, name: isApp ? (name as NSString).deletingPathExtension : name, path: path, fileId: fileId, kind: kind, ext: ext, meta: meta,
                          size: (attrs?[.size] as? Int64) ?? 0, mtime: Int64(mtime))
    }
}

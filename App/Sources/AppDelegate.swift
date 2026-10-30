import AppKit
import Catalog
import NameEngine
import XSearchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var names: NameService!
    private var indexer: ContentIndexer?
    private var statusTimer: Timer?
    private let contentStatusItem = NSMenuItem(title: "内容索引：正在打开", action: nil, keyEquivalent: "")
    private var usage: UsageStore?
    private var session: SearchSession!
    private var launcher: LauncherController!
    private var readerWindow: ReaderWindowController?
    /// Recreated with the launcher: it reads through the current session's content searcher.
    private var reader: ReaderWindowController {
        if let readerWindow { return readerWindow }
        let r = ReaderWindowController(searcher: session.content)
        r.onOpenFile = { [weak self] path, id in self?.usage?.recordOpen(path: path, fileId: id) }
        readerWindow = r
        return r
    }

    private var fullWindow: FullWindowController?
    private var full: FullWindowController {
        if let fullWindow { return fullWindow }
        let f = FullWindowController(session: session, usage: usage)
        f.onRead = { [weak self] hit, expression, n in self?.reader.show(hit, expression: expression, startAt: n) }
        f.nameScope = { Preferences.shared.nameScope }
        f.contentScope = { [weak self] in self?.currentContentScope ?? .default }
        fullWindow = f
        return f
    }

    /// Callbacks shared by every launcher instance (startup and index rebuild).
    private func wireLauncher() {
        launcher.openSettings = { [weak self] in self?.openSettings(tab: .scope) }
        launcher.openDiagnostics = { [weak self] in self?.openSettings(tab: .diagnostics) }
        launcher.onRead = { [weak self] hit, expression, n in self?.reader.show(hit, expression: expression, startAt: n) }
        launcher.onExpand = { [weak self] text, mode in self?.full.show(text: text, mode: mode) }
        readerWindow?.close()
        readerWindow = nil
        fullWindow?.close()
        fullWindow = nil
    }
    private var hotKey: HotKey!
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindowController?
    private let indexStatusItem = NSMenuItem(title: "文件名索引：正在打开", action: nil, keyEquivalent: "")
    private let hotKeyItem = NSMenuItem(title: "打开搜索", action: #selector(showLauncher), keyEquivalent: "")
    private var hotKeyConflict = false

    /// Development overrides: XS_DATA_DIR (data directory), XS_NAME_ROOTS (comma-separated scan
    /// roots). Used for smoke tests that must not touch the real index or protected folders.
    private let env = ProcessInfo.processInfo.environment
    private var dataDirectory: URL { env["XS_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? Preferences.dataDirectory }
    private var nameScope: NameScope {
        guard let roots = env["XS_NAME_ROOTS"] else { return Preferences.shared.nameScope }
        var s = NameScope.default
        s.wholeDisk = false
        s.folders = roots.split(separator: ",").map(String.init)
        s.excludes = ["node_modules", ".git"]
        return s
    }

    /// XS_CONTENT_ROOTS (comma-separated) overrides the content scope for development.
    private var contentScope: ContentScope {
        guard let roots = env["XS_CONTENT_ROOTS"] else { return Preferences.shared.contentScope }
        return ContentScope(folders: roots.split(separator: ",").map(String.init))
    }

    /// Starts IndexService (in-process, own queue) with the bundled extraction worker.
    private func startIndexer() {
        let worker = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("xs-extract")
        let ix = ContentIndexer(directory: dataDirectory, workerExecutable: worker, workers: 2)
        do {
            try ix.start()
            indexer = ix
        } catch {
            indexer = nil
            contentStatusItem.title = "内容索引无法启动：\(String(describing: error).prefix(60))"
        }
        session.content.indexPath = { [weak ix] in ix?.indexURL.path }
        session.contentStats = { [weak ix] in
            guard let st = ix?.status else { return ContentStats() }
            return ContentStats(indexed: st.indexed, pending: st.pending, failed: st.failed)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let data = dataDirectory
        names = NameService(directory: data)
        usage = try? UsageStore(directory: data)
        session = SearchSession(names: names, usage: usage)
        launcher = LauncherController(session: session, usage: usage)
        wireLauncher()
        session.onAppsLoaded = { [weak self] in self?.launcher.appsDidLoad() }
        session.refreshApps()

        names.onStatus = { [weak self] _ in
            Task { @MainActor in self?.statusChanged() }
        }
        names.start(scope: nameScope, content: contentScope)
        startIndexer()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusChanged() }
        }

        buildStatusItem()
        hotKey = HotKey { [weak self] in self?.launcher.toggle() }
        registerHotKey(Preferences.shared.hotKey)
        // Development: show the launcher with a query (screenshots, UI checks).
        if let text = env["XS_LAUNCHER_TEXT"] {
            let delay = env["XS_LAUNCHER_DELAY"].flatMap(Double.init) ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launcher.show(text: text) }
        }
        // Dev: open the full window directly (XS_FULL_MODE=content for content mode).
        if let text = env["XS_FULL_TEXT"] {
            let mode: Preferences.Mode = env["XS_FULL_MODE"] == "content" ? .content : .name
            let reader = env["XS_READER"] != nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.full.openFirstInReader = reader
                self?.full.show(text: text, mode: mode)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        indexer?.stop()
        names.shutdown()
    }

    /// Reopening the app (e.g. from Finder) shows the launcher.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher.show()
        return false
    }

    // MARK: Hotkey

    @discardableResult
    func registerHotKey(_ combo: HotKey.Combo) -> Bool {
        let ok = hotKey.register(combo)
        hotKeyConflict = !ok
        hotKeyItem.title = ok ? "打开搜索" : "快捷键 \(combo.display) 已被占用，点此修改"
        hotKeyItem.action = ok ? #selector(showLauncher) : #selector(openGeneralSettings)
        hotKeyItem.keyEquivalent = ""
        if ok { hotKeyItem.toolTip = combo.display }
        updateHotKeyHint(ok ? combo : nil)
        if !ok {
            let alert = NSAlert()
            alert.messageText = "快捷键 \(combo.display) 已被其他应用占用"
            alert.informativeText = "可以在设置中改用其他组合键，或者从菜单栏图标打开搜索。"
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "稍后")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { openSettings(tab: .general) }
        }
        return ok
    }

    private func updateHotKeyHint(_ combo: HotKey.Combo?) {
        let title = hotKeyItem.title
        guard let combo else { hotKeyItem.attributedTitle = nil; return }
        let s = NSMutableAttributedString(string: title + "\t")
        s.append(NSAttributedString(string: combo.display, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 260)]
        s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
        hotKeyItem.attributedTitle = s
    }

    // MARK: Menu bar (UI-SPEC §6.6)

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "XSearch")
        let menu = NSMenu()
        menu.delegate = self
        indexStatusItem.isEnabled = false
        menu.addItem(indexStatusItem)
        contentStatusItem.isEnabled = false
        menu.addItem(contentStatusItem)
        menu.addItem(.separator())
        hotKeyItem.target = self
        menu.addItem(hotKeyItem)
        let prefs = NSMenuItem(title: "设置…", action: #selector(openGeneralSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 XSearch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusChanged()
    }

    func menuWillOpen(_ menu: NSMenu) { statusChanged() }

    private func statusChanged() {
        let st = names.status
        switch st.phase {
        case .starting: indexStatusItem.title = "文件名索引：正在打开"
        case .scanning: indexStatusItem.title = "文件名索引：正在建立 · \(Theme.count(st.count)) 项"
        case .ready: indexStatusItem.title = "文件名索引：已就绪 · \(Theme.count(st.count)) 项"
        case .failed(let message): indexStatusItem.title = "文件名索引出错：\(message.prefix(60))"
        }
        if let st = indexer?.status {
            var parts = ["内容索引：\(Theme.count(st.indexed)) 个文件"]
            if st.pending > 0 { parts.append("待处理 \(Theme.count(st.pending))") }
            if st.failed > 0 { parts.append("\(st.failed) 个失败") }
            contentStatusItem.title = parts.joined(separator: " · ")
        }
        launcher?.updateStatus()
        settings?.refresh()
    }

    // MARK: Actions

    @objc func showLauncher() { launcher.show() }

    @objc func openGeneralSettings() { openSettings(tab: .general) }

    func openSettings(tab: SettingsTab) {
        if settings == nil {
            settings = SettingsWindowController(names: names, delegate: self)
        }
        settings?.show(tab: tab)
    }

    func applyScope(_ scope: NameScope) {
        Preferences.shared.nameScope = scope
        names.setScope(scope)
    }

    func applyContentScope(_ scope: ContentScope) {
        Preferences.shared.contentScope = scope
        names.setContentScope(scope)
    }

    var currentContentScope: ContentScope { contentScope }

    /// Settings › 隐私与数据 › 重建内容索引: new instance in the background, switch when caught up.
    func rebuildContentIndex() {
        try? indexer?.rebuildContentIndex()
        statusChanged()
    }
    var contentStatus: ContentIndexer.Status? { indexer?.status }
    var nameService: NameService { names }

    /// Deletes the rebuildable name index (catalog + snapshot) and scans again. user.sqlite stays.
    func rebuildNameIndex() {
        indexer?.stop()
        names.shutdown()
        let data = dataDirectory
        // File ids are catalog ids: the content index is rebuilt together with the catalog.
        for name in ["catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm", "names", "content"] {
            try? FileManager.default.removeItem(at: data.appendingPathComponent(name))
        }
        names = NameService(directory: data)
        names.onStatus = { [weak self] _ in Task { @MainActor in self?.statusChanged() } }
        session = SearchSession(names: names, usage: usage)
        launcher = LauncherController(session: session, usage: usage)
        wireLauncher()
        session.onAppsLoaded = { [weak self] in self?.launcher.appsDidLoad() }
        session.refreshApps()
        settings?.names = names
        names.start(scope: nameScope, content: contentScope)
        startIndexer()
    }

    var currentHotKey: HotKey.Combo { Preferences.shared.hotKey }

    func changeHotKey(_ combo: HotKey.Combo) -> Bool {
        let previous = Preferences.shared.hotKey
        if hotKey.register(combo) {
            Preferences.shared.hotKey = combo
            hotKeyConflict = false
            hotKeyItem.title = "打开搜索"
            hotKeyItem.action = #selector(showLauncher)
            updateHotKeyHint(combo)
            return true
        }
        hotKey.register(previous)
        return false
    }
}

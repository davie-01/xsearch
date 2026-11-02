import AppKit
import Catalog
import NameEngine
import XSearchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var names: NameService!
    /// Content indexer in IndexService.xpc (in-process without the bundled service).
    private var indexer: IndexServiceClient?
    private var statusTimer: Timer?
    private var menuOpen = false
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
        f.onRead = { [weak self, weak f] hit, expression, n in self?.reader.show(hit, expression: expression, mode: f?.matchMode, startAt: n) }
        f.nameScope = { Preferences.shared.nameScope }
        f.contentScope = { [weak self] in self?.currentContentScope ?? .default }
        fullWindow = f
        return f
    }

    /// An agent app (LSUIElement) shows no menu bar, but key equivalents such as ⌘W, ⌘C and
    /// ⌘V are still dispatched through `NSApp.mainMenu`: without one, normal windows (full
    /// window, reader, settings) cannot be closed with ⌘W and text fields cannot copy or paste.
    private func installKeyMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector?, String, NSEvent.ModifierFlags)]) {
            let menu = NSMenu(title: title)
            for (t, action, key, mods) in items {
                let item = NSMenuItem(title: t, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = mods
                menu.addItem(item)
            }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }
        submenu("XSearch", [("退出 XSearch", #selector(NSApplication.terminate(_:)), "q", .command)])
        submenu("编辑", [
            ("撤销", Selector(("undo:")), "z", .command), ("重做", Selector(("redo:")), "z", [.command, .shift]),
            ("剪切", #selector(NSText.cut(_:)), "x", .command), ("拷贝", #selector(NSText.copy(_:)), "c", .command),
            ("粘贴", #selector(NSText.paste(_:)), "v", .command), ("全选", #selector(NSText.selectAll(_:)), "a", .command),
        ])
        submenu("窗口", [
            ("关闭", #selector(NSWindow.performClose(_:)), "w", .command),
            ("最小化", #selector(NSWindow.performMiniaturize(_:)), "m", .command),
        ])
        NSApp.mainMenu = main
    }

    private var onboarding: OnboardingWindowController?

    @objc func checkForUpdates() { Updater.shared.checkForUpdates() }

    func clearRecents() { usage?.clearOpens() }

    /// First-launch guide (UI-SPEC §6.5); also from the menu bar.
    @objc func showOnboarding() {
        if let onboarding { onboarding.present(); return }
        let model = OnboardingModel(scope: currentContentScope, hotKey: Preferences.shared.hotKey.display)
        model.onFinish = { [weak self] scope in
            Preferences.shared.onboarded = true
            if scope != self?.currentContentScope { self?.applyContentScope(scope) }
        }
        model.onTry = { [weak self] in
            self?.onboarding?.close()
            self?.onboarding = nil
            self?.launcher.show()
        }
        // Dev: XS_ONBOARDING_STEP=0…3 opens a given step (screenshots).
        if let step = env["XS_ONBOARDING_STEP"].flatMap(Int.init) { model.step = step }
        let controller = OnboardingWindowController(model: model)
        onboarding = controller
        controller.present()
        // Extractable files in Downloads, from the name index (still filling on a first launch).
        let count = { [weak self, weak model] in
            guard let self, let model else { return }
            let exts = ContentType.allCases.flatMap(\.extensions).joined(separator: ";")
            model.downloadsCount = self.names.search(NameQuery.parse("dir:~/Downloads ext:\(exts)", home: NSHomeDirectory()), limit: 0).total
        }
        count()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { count() }
    }

    /// Callbacks shared by every launcher instance (startup and index rebuild).
    private func wireLauncher() {
        launcher.onVisibilityChange = { [weak self] in self?.updateStatusTimer() }
        launcher.openSettings = { [weak self] in self?.openSettings(tab: .scope) }
        launcher.openDiagnostics = { [weak self] in self?.openSettings(tab: .diagnostics) }
        launcher.onRead = { [weak self] hit, expression, n, live in self?.reader.show(hit, expression: expression, live: live, startAt: n) }
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
    /// Starts IndexService.xpc (warm-up at launch) with the bundled extraction worker.
    private func startIndexer() {
        let worker = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("xs-extract")
        let ix = IndexServiceClient(dataDirectory: dataDirectory, worker: worker)
        ix.onError = { [weak self] message in self?.contentStatusItem.title = "内容索引出错：\(message.prefix(60))" }
        ix.onUpdate = { [weak self] in self?.showContentStatus() }
        ix.maxFileBytes = contentScope.maxFileBytes
        names.onContentTasks = { [weak ix] in
            Task { @MainActor in ix?.wake() }
        }
        session.content.maxFileBytes = contentScope.maxFileBytes
        ix.start()
        indexer = ix
        session.content.indexPath = { [ix] in ix.indexPath }
        session.contentStats = { [weak ix] in
            guard let st = ix?.status else { return ContentStats() }
            return ContentStats(indexed: st.indexed, pending: st.pending, failed: st.failed)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MemberOpener.removeOldExtractions()
        let data = dataDirectory
        // A first launch has no catalog yet; installs that predate the guide skip it.
        let fresh = !FileManager.default.fileExists(atPath: data.appendingPathComponent("catalog.sqlite").path)
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
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After the close: the window still counts as visible during this notification.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateStatusTimer() } }
            }
        }
        updateStatusTimer()

        buildStatusItem()
        installKeyMenu()
        _ = Updater.shared  // starts scheduled checks when a feed is configured
        // Dev: XS_CHECK_UPDATES=1 checks right away (update flow tests).
        if env["XS_CHECK_UPDATES"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Updater.shared.checkForUpdates() }
        }
        hotKey = HotKey { [weak self] in self?.launcher.toggle() }
        registerHotKey(Preferences.shared.hotKey)
        if env["XS_ONBOARDING"] == "1" || (!Preferences.shared.onboarded && fresh) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showOnboarding() }
        } else if !Preferences.shared.onboarded {
            Preferences.shared.onboarded = true
        }
        PerfLog.watchMainThread()
        // Dev: XS_TYPE="in wp |a|⌫" types into the launcher key by key (performance checks);
        // "|" separates 150 ms steps, "⌫" deletes one character.
        if let keys = env["XS_TYPE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.launcher.typeForTesting(keys) }
        }
        // Development: show the launcher with a query (screenshots, UI checks).
        if let text = env["XS_LAUNCHER_TEXT"] {
            let delay = env["XS_LAUNCHER_DELAY"].flatMap(Double.init) ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launcher.show(text: text) }
        }
        // Dev: open a settings tab directly (XS_SETTINGS_TAB=搜索语法).
        if let tab = env["XS_SETTINGS_TAB"].flatMap(SettingsTab.init(rawValue:)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.openSettings(tab: tab) }
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
        // Template: the system colours it for the menu bar. Not bundled under `swift run`.
        let symbol = Bundle.main.image(forResource: "XSearchTemplate-18") ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "XSearch")
        symbol?.isTemplate = true
        symbol?.accessibilityDescription = "XSearch"
        statusItem.button?.image = symbol
        let menu = NSMenu()
        menu.delegate = self
        indexStatusItem.isEnabled = false
        menu.addItem(indexStatusItem)
        contentStatusItem.isEnabled = false
        menu.addItem(contentStatusItem)
        menu.addItem(.separator())
        hotKeyItem.target = self
        menu.addItem(hotKeyItem)
        let update = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        let guide = NSMenuItem(title: "使用引导…", action: #selector(showOnboarding), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        let prefs = NSMenuItem(title: "设置…", action: #selector(openGeneralSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 XSearch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusChanged()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        statusChanged()
        updateStatusTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        updateStatusTimer()
    }

    /// Status is polled only while someone can see it. Also how readers learn the index path
    /// after a rebuild, so opening the launcher refreshes at once.
    private func updateStatusTimer() {
        let visible = menuOpen || launcher?.isVisible == true || NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        guard visible != (statusTimer != nil) else { return }
        if visible {
            let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.statusChanged() }
            }
            timer.tolerance = 0.5
            statusTimer = timer
            statusChanged()
        } else {
            statusTimer?.invalidate()
            statusTimer = nil
        }
    }

    private func statusChanged() {
        let st = names.status
        switch st.phase {
        case .starting: indexStatusItem.title = "文件名索引：正在打开"
        case .scanning: indexStatusItem.title = "文件名索引：正在建立 · \(Theme.count(st.count)) 项"
        case .ready: indexStatusItem.title = "文件名索引：\(st.watching ? "已就绪" : "未实时更新") · \(Theme.count(st.count)) 项"
        case .failed(let message): indexStatusItem.title = "文件名索引出错：\(message.prefix(60))"
        }
        // The snapshot arrives asynchronously from the service (`showContentStatus`).
        indexer?.refresh()
        launcher?.updateStatus()
        settings?.refresh()
    }

    private func showContentStatus() {
        guard let st = indexer?.status else { return }
        var parts = ["内容索引：\(Theme.count(st.indexed)) 个文件"]
        if st.pending > 0 { parts.append("待处理 \(Theme.count(st.pending))") }
        if st.failed > 0 { parts.append("\(st.failed) 个失败") }
        contentStatusItem.title = parts.joined(separator: " · ")
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
        indexer?.setMaxFileBytes(scope.maxFileBytes)
        session.content.maxFileBytes = scope.maxFileBytes
    }

    var currentContentScope: ContentScope { contentScope }

    /// Settings › 隐私与数据 › 重建内容索引: new instance in the background, switch when caught up.
    func rebuildContentIndex() {
        indexer?.rebuildContentIndex()
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

import AppKit
import Catalog
import NameEngine
import XSearchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var names: NameService!
    private var usage: UsageStore?
    private var session: SearchSession!
    private var launcher: LauncherController!
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let data = dataDirectory
        names = NameService(directory: data)
        usage = try? UsageStore(directory: data)
        session = SearchSession(names: names, usage: usage)
        launcher = LauncherController(session: session, usage: usage)
        launcher.openSettings = { [weak self] in self?.openSettings(tab: .scope) }
        session.onAppsLoaded = { [weak self] in self?.launcher.appsDidLoad() }
        session.refreshApps()

        names.onStatus = { [weak self] _ in
            Task { @MainActor in self?.statusChanged() }
        }
        names.start(scope: nameScope)

        buildStatusItem()
        hotKey = HotKey { [weak self] in self?.launcher.toggle() }
        registerHotKey(Preferences.shared.hotKey)
        // Development: show the launcher with a query (screenshots, UI checks).
        if let text = env["XS_LAUNCHER_TEXT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.launcher.show(text: text) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        let content = NSMenuItem(title: "内容索引：下一个版本提供", action: nil, keyEquivalent: "")
        content.isEnabled = false
        menu.addItem(content)
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

    /// Deletes the rebuildable name index (catalog + snapshot) and scans again. user.sqlite stays.
    func rebuildNameIndex() {
        names.shutdown()
        let data = dataDirectory
        for name in ["catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm", "names"] {
            try? FileManager.default.removeItem(at: data.appendingPathComponent(name))
        }
        names = NameService(directory: data)
        names.onStatus = { [weak self] _ in Task { @MainActor in self?.statusChanged() } }
        session = SearchSession(names: names, usage: usage)
        launcher = LauncherController(session: session, usage: usage)
        launcher.openSettings = { [weak self] in self?.openSettings(tab: .scope) }
        session.onAppsLoaded = { [weak self] in self?.launcher.appsDidLoad() }
        session.refreshApps()
        settings?.names = names
        names.start(scope: nameScope)
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

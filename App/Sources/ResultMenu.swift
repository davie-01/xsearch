import AppKit
import XSearchCore

/// Context menu of a launcher result (docs/m5/右键菜单.md): Finder's file menu, trimmed per
/// kind of result. Built fresh on each right click from what the row is.
@MainActor
enum ResultMenu {
    /// What the clicked row is; decides which items appear.
    struct Target {
        enum Kind { case app, folder, file, member, missing }
        var kind: Kind
        var path: String
        var name: String
        var isFavorite = false
        /// Listed under 最近打开 (offers removing it from there).
        var isRecent = false
        /// A content hit: offers the reader window.
        var canRead = false
        /// Text copied by 复制路径 (an archive member: "包路径!/成员").
        var copyPathText: String
    }

    /// What the menu asks its owner to do; everything else it does itself.
    struct Actions {
        var open: () -> Void
        var reveal: () -> Void
        var read: (() -> Void)?
        var quickLook: (() -> Void)?
        var toggleFavorite: () -> Void
        var trash: () -> Void
        var removeRecent: () -> Void
        /// After an action that leaves the panel up: a short confirmation in the footer.
        var toast: (String) -> Void
        /// Before handing the file to another app.
        var willLeave: () -> Void
    }

    static func build(_ menu: NSMenu, for t: Target, actions a: Actions) {
        menu.removeAllItems()
        let url = URL(fileURLWithPath: t.path)
        func add(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], _ run: @escaping () -> Void) {
            let item = ClosureItem(title: title, run: run)
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        func separator() { if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) } }

        switch t.kind {
        case .missing:
            // Only what still makes sense for a path that is gone.
            if t.isFavorite { add(L("从收藏中移除"), a.toggleFavorite) }
            if t.isRecent { add(L("从最近打开中移除"), a.removeRecent) }
            separator()
            add(L("复制路径")) { copy(string: t.copyPathText); a.toast(L("已复制路径")) }
            return
        case .member:
            add(L("打开"), key: "\r", a.open)
            if let read = a.read { add(L("在阅读窗口中打开"), key: "\r", modifiers: .command, read) }
            add(L("在访达中显示压缩包"), a.reveal)
            separator()
            add(L("复制路径")) { copy(string: t.copyPathText); a.toast(L("已复制路径")) }
            return
        case .app, .folder, .file:
            break
        }

        add(L("打开"), key: "\r", a.open)
        if t.canRead, let read = a.read { add(L("在阅读窗口中打开"), key: "\r", modifiers: .command, read) }
        if t.kind == .file, let sub = openWith(url, willLeave: a.willLeave) {
            let item = NSMenuItem(title: L("打开方式"), action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        // ⌘↵ reveals in name mode only (content mode uses it for the reader).
        if t.canRead { add(L("在访达中显示"), a.reveal) } else { add(L("在访达中显示"), key: "\r", modifiers: .command, a.reveal) }
        if t.kind != .app, let quickLook = a.quickLook {
            if t.canRead { add(L("快速查看"), quickLook) } else { add(L("快速查看"), key: " ", quickLook) }
        }
        if t.kind == .folder {
            add(L("在终端中打开")) {
                a.willLeave()
                if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
        separator()
        add(L("复制“%@”", "\(t.name)")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
            a.toast(L("已复制"))
        }
        add(L("复制路径")) { copy(string: t.copyPathText); a.toast(L("已复制路径")) }
        separator()
        add(t.isFavorite ? L("取消收藏") : L("收藏"), key: "d", modifiers: .command, a.toggleFavorite)
        if t.isRecent { add(L("从最近打开中移除"), a.removeRecent) }
        // Apps are left out: moving one to the trash from a search list is too easy a mistake.
        if t.kind != .app {
            separator()
            add(L("移到废纸篓"), key: "\u{8}", modifiers: .command, a.trash)
        }
    }

    /// Apps that open the file, the default first; nil when there is none.
    private static func openWith(_ url: URL, willLeave: @escaping () -> Void) -> NSMenu? {
        let ws = NSWorkspace.shared
        let preferred = ws.urlForApplication(toOpen: url)
        var apps = ws.urlsForApplications(toOpen: url)
        if let preferred { apps.removeAll { $0.standardizedFileURL == preferred.standardizedFileURL }; apps.insert(preferred, at: 0) }
        guard !apps.isEmpty else { return nil }
        let menu = NSMenu()
        var seen = Set<String>()
        for (i, app) in apps.enumerated() {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            // The same app installed twice shows once.
            guard seen.insert(name).inserted else { continue }
            let item = ClosureItem(title: i == 0 && preferred != nil ? L("%@（默认）", "\(name)") : name) {
                willLeave()
                ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
            let icon = appIcon(atPath: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            if i == 0 && preferred != nil && apps.count > 1 { menu.addItem(.separator()) }
        }
        return menu
    }

    private static func copy(string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// A menu item that runs a closure.
final class ClosureItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

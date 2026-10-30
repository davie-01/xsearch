import AppKit
import Catalog
import ContentEngine
import Quartz
import XSearchCore

/// Window whose key equivalents go to the controller first.
final class KeyWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Full window (⌘E, UI-SPEC §6.2): the launcher's query with a sidebar of filters (folders,
/// types, modified time, match mode), a sortable multi-select table and a preview. A normal
/// window: clicking outside does not close it.
@MainActor
final class FullWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Row {
        var name: String
        var path: String
        var dir: String
        var size: Int64
        var mtime: Int64
        var hits: Int?
        var kind: FileKind
        var isFolder: Bool
        var fileId: Int64?
        var hit: ContentHit?
    }

    private let session: SearchSession
    private let usage: UsageStore?
    /// Its own searcher: the launcher's may be cancelled or reused independently.
    private let content = ContentSearcher()
    private let field = NSSearchField()
    private let modeControl = NSSegmentedControl(labels: ["名称", "内容"], trackingMode: .selectOne, target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let table = ResultTable()
    private let tableScroll = NSScrollView()
    private let quickLook = QLPreviewView(frame: .zero, style: .normal)!
    private let textPreview = PreviewPane()
    private let sidebar = NSStackView()
    private let timePopup = NSPopUpButton()
    private let matchPopup = NSPopUpButton()
    private var folderChecks: [(path: String, box: NSButton)] = []
    private var typeChecks: [(token: String, box: NSButton)] = []
    private var ranked: [Row] = []
    private var rows: [Row] = []
    private var mode: Preferences.Mode = .name
    private var expression = ""
    private var previewToken = 0

    var onRead: ((ContentHit, String, Int) -> Void)?
    /// Dev hook (XS_READER): open the first content result in the reader once.
    var openFirstInReader = false
    var nameScope: () -> NameScope = { .default }
    var contentScope: () -> ContentScope = { .default }

    static let times: [(String, String?)] = [("不限", nil), ("今天", "today"), ("最近 7 天", "7d"), ("最近 30 天", "30d"), ("今年", "thisyear")]
    static let kinds: [(FileKind, String)] = [(.folder, "文件夹"), (.pdf, "PDF"), (.word, "文档"), (.sheet, "表格"), (.slide, "演示"), (.ofd, "OFD"),
                                              (.text, "文本 / 代码"), (.image, "图片"), (.video, "视频"), (.audio, "音频"), (.archive, "压缩包"), (.app, "应用")]
    static let contentTypes: [(ContentType, String)] = [(.text, "文本 / 代码"), (.pdf, "PDF"), (.docx, "Word（docx）"), (.doc, "Word（doc）"),
                                                        (.sheet, "Excel"), (.slide, "PowerPoint"), (.ofd, "OFD")]

    init(session: SearchSession, usage: UsageStore?) {
        self.session = session
        self.usage = usage
        content.indexPath = session.content.indexPath
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 830),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 980, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("XSearchFull")
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] in self?.key($0) ?? false }
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func build() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        field.placeholderString = "搜索文件名，或切换到内容"
        field.font = .systemFont(ofSize: 15)
        field.controlSize = .large
        field.delegate = self
        field.sendsSearchStringImmediately = true
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        let top = NSStackView(views: [field, modeControl, countLabel])
        top.spacing = 12
        top.edgeInsets = NSEdgeInsets(top: 36, left: 252, bottom: 12, right: 20)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 6
        sidebar.edgeInsets = NSEdgeInsets(top: 40, left: 16, bottom: 16, right: 12)
        let sidebarScroll = NSScrollView()
        // Flipped document: the filters start at the top, not the bottom, of the scroll view.
        let sidebarDoc = FlippedView()
        sidebarDoc.translatesAutoresizingMaskIntoConstraints = false
        sidebarDoc.addSubview(sidebar)
        sidebarScroll.documentView = sidebarDoc
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        let sidebarBox = NSView()
        sidebarBox.wantsLayer = true
        sidebarBox.layer?.backgroundColor = Theme.sidebar.cgColor

        for (id, title, width) in [("name", "名称", 300.0), ("dir", "位置", 280.0), ("hits", "命中", 60.0), ("size", "大小", 80.0), ("mtime", "修改时间", 130.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "name" || id == "dir")
            table.addTableColumn(c)
        }
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        table.onReturn = { [weak self] flags in self?.openSelected(reveal: flags.contains(.command)) }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true

        textPreview.locate.title = "阅读窗口 ⌘↵"
        textPreview.onLocate = { [weak self] in self?.openReader() }
        let preview = NSView()
        for v in [quickLook, textPreview] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            preview.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: preview.leadingAnchor), v.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
                v.topAnchor.constraint(equalTo: preview.topAnchor), v.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            ])
        }
        textPreview.isHidden = true

        for v in [sidebarBox, sidebarScroll, top, tableScroll, preview] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarBox)
        sidebarBox.addSubview(sidebarScroll)
        for v in [top, tableScroll, preview] as [NSView] { root.addSubview(v) }
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)
        NSLayoutConstraint.activate([
            sidebarBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarBox.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarBox.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarBox.widthAnchor.constraint(equalToConstant: 236),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarBox.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarBox.trailingAnchor),
            sidebarScroll.topAnchor.constraint(equalTo: sidebarBox.topAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarBox.bottomAnchor),
            sidebarDoc.widthAnchor.constraint(equalTo: sidebarScroll.widthAnchor),
            sidebarDoc.topAnchor.constraint(equalTo: sidebarScroll.contentView.topAnchor),
            sidebar.topAnchor.constraint(equalTo: sidebarDoc.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: sidebarDoc.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: sidebarDoc.trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: sidebarDoc.bottomAnchor),
            top.topAnchor.constraint(equalTo: root.topAnchor),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: top.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: sidebarBox.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.topAnchor.constraint(equalTo: top.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            preview.topAnchor.constraint(equalTo: top.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            preview.widthAnchor.constraint(equalToConstant: 440),
        ])

        timePopup.addItems(withTitles: Self.times.map(\.0))
        timePopup.target = self
        timePopup.action = #selector(filtersChanged)
        matchPopup.addItems(withTitles: ["宽松（默认）", "区分大小写", "严格原文"])
        matchPopup.target = self
        matchPopup.action = #selector(filtersChanged)
        rebuildSidebar()
    }

    private func sectionTitle(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 11.5, weight: .semibold)
        t.textColor = .tertiaryLabelColor
        return t
    }

    private func check(_ title: String) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(filtersChanged))
        b.font = .systemFont(ofSize: 13)
        b.lineBreakMode = .byTruncatingMiddle
        return b
    }

    /// Folders and types depend on the mode; checked folders and types narrow the query, none
    /// checked means no restriction.
    private func rebuildSidebar() {
        sidebar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let home = NSHomeDirectory()
        let folders: [String]
        if mode == .content {
            folders = contentScope().roots(home: home)
        } else {
            let scope = nameScope()
            folders = scope.wholeDisk ? ["~/Desktop", "~/Documents", "~/Downloads"].map { home + $0.dropFirst() } : scope.folders.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        }
        sidebar.addArrangedSubview(sectionTitle(mode == .content ? "内容索引范围" : "位置"))
        folderChecks = folders.map { path in
            let b = check(PathUtil.abbreviate(path, home: home))
            b.toolTip = path
            sidebar.addArrangedSubview(b)
            return (path, b)
        }
        if folders.isEmpty { sidebar.addArrangedSubview(sectionTitle("（未设置）")) }
        sidebar.setCustomSpacing(16, after: sidebar.arrangedSubviews.last!)
        sidebar.addArrangedSubview(sectionTitle("文件类型"))
        if mode == .content {
            typeChecks = Self.contentTypes.map { type, label in
                let b = check(label)
                sidebar.addArrangedSubview(b)
                return ("ext:" + type.extensions.sorted().joined(separator: ";"), b)
            }
        } else {
            typeChecks = Self.kinds.map { kind, label in
                let b = check(label)
                sidebar.addArrangedSubview(b)
                return ("kind:" + kind.rawValue, b)
            }
        }
        sidebar.setCustomSpacing(16, after: sidebar.arrangedSubviews.last!)
        sidebar.addArrangedSubview(sectionTitle("修改时间"))
        sidebar.addArrangedSubview(timePopup)
        if mode == .content {
            sidebar.setCustomSpacing(16, after: timePopup)
            sidebar.addArrangedSubview(sectionTitle("匹配模式"))
            sidebar.addArrangedSubview(matchPopup)
        }
        table.tableColumns.first { $0.identifier.rawValue == "hits" }?.isHidden = mode != .content
    }

    // MARK: Query

    /// Opens with the launcher's input and mode (UI-SPEC §6.2: the query carries over).
    func show(text: String, mode: Preferences.Mode) {
        // The index instance can change (content rebuild): follow the launcher's searcher.
        content.indexPath = session.content.indexPath
        matchPopup.selectItem(at: ["loose", "caseSensitive", "strict"].firstIndex(of: Preferences.shared.matchMode) ?? 0)
        field.stringValue = text
        if mode != self.mode {
            self.mode = mode
            modeControl.selectedSegment = mode == .content ? 1 : 0
            rebuildSidebar()
        }
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(field)
        runSearch()
    }

    func controlTextDidChange(_ obj: Notification) { runSearch() }

    @objc private func modeChanged() {
        mode = modeControl.selectedSegment == 1 ? .content : .name
        rebuildSidebar()
        runSearch()
    }

    @objc private func filtersChanged() { runSearch() }

    /// The input plus the sidebar's filters, in the ordinary query syntax.
    private var effectiveText: String {
        var parts = [field.stringValue]
        let dirs = folderChecks.filter { $0.box.state == .on }.map { "dir:\"\($0.path)\"" }
        parts += dirs
        let types = typeChecks.filter { $0.box.state == .on }.map(\.token)
        if mode == .name, !types.isEmpty {
            parts.append("kind:" + types.map { String($0.dropFirst(5)) }.joined(separator: ";"))
        } else if !types.isEmpty {
            parts.append("ext:" + types.map { String($0.dropFirst(4)) }.joined(separator: ";"))
        }
        if let t = Self.times[max(0, timePopup.indexOfSelectedItem)].1 { parts.append("dm:" + t) }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func runSearch() {
        let text = effectiveText
        if mode == .content {
            content.mode = [MatchMode.loose, .caseSensitive, .strict][max(0, matchPopup.indexOfSelectedItem)]
            content.search(text, home: NSHomeDirectory(), syntax: Preferences.shared.querySyntax) { [weak self] out in self?.applyContent(out) }
        } else {
            content.cancel()
            session.search(text, limit: 5000) { [weak self] out in self?.applyNames(out) }
        }
    }

    private func applyNames(_ out: SearchOutput) {
        guard mode == .name else { return }
        ranked = out.items.filter { $0.group != .favorites && $0.group != .recents || out.query.isEmpty }.map { item in
            Row(name: item.name, path: item.path, dir: (item.path as NSString).deletingLastPathComponent, size: item.size, mtime: item.mtime,
                hits: nil, kind: item.kind, isFolder: item.kind == .folder, fileId: item.fileId, hit: nil)
        }
        countLabel.stringValue = out.query.isEmpty ? "" : "\(Theme.count(out.total)) 项" + (out.total > ranked.count ? "（显示前 \(Theme.count(ranked.count)) 项）" : "")
        resort(keepSelection: false)
    }

    private func applyContent(_ out: ContentOutput) {
        guard mode == .content else { return }
        expression = out.query.expression
        let new = out.hits.map { h in
            Row(name: h.name, path: h.dir + "/" + h.name, dir: h.dir, size: h.size, mtime: h.mtime, hits: Int(h.hitCount),
                kind: FileKind.of(extension: NameKey.key((h.name as NSString).pathExtension), isDirectory: false, isApp: false),
                isFolder: false, fileId: Int64(h.fileId), hit: h)
        }
        ranked = out.append ? ranked + new : new
        if let e = out.error {
            countLabel.stringValue = e
        } else {
            countLabel.stringValue = out.query.isEmpty ? "" : "\(Theme.count(ranked.count)) 个文件" + (out.done ? "" : " · 仍在搜索… 已核验 \(out.verified)/\(out.candidates)")
        }
        resort(keepSelection: out.append)
        if openFirstInReader, let first = rows.first?.hit {
            openFirstInReader = false
            onRead?(first, expression, 0)
        }
    }

    // MARK: Sorting

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        resort(keepSelection: true)
    }

    /// Engine ranking unless a column header was clicked; a second click reverses.
    private func resort(keepSelection: Bool) {
        let selected = Set(table.selectedRowIndexes.map { rows[$0].path })
        rows = ranked
        if let d = table.sortDescriptors.first, let key = d.key {
            let asc = d.ascending
            func cmp(_ a: Row, _ b: Row) -> Bool {
                switch key {
                case "name": return a.name.localizedStandardCompare(b.name) == (asc ? .orderedAscending : .orderedDescending)
                case "dir": return a.dir.localizedStandardCompare(b.dir) == (asc ? .orderedAscending : .orderedDescending)
                case "hits": return asc ? (a.hits ?? 0) < (b.hits ?? 0) : (a.hits ?? 0) > (b.hits ?? 0)
                case "size": return asc ? a.size < b.size : a.size > b.size
                default: return asc ? a.mtime < b.mtime : a.mtime > b.mtime
                }
            }
            rows.sort(by: cmp)
        }
        table.reloadData()
        if keepSelection {
            table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].path) }), byExtendingSelection: false)
        } else if !rows.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        } else {
            showPreview(nil)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let r = rows[row]
        let cell = tableView.makeView(withIdentifier: .init("full-" + id), owner: nil) as? NSTableCellView ?? makeCell(id)
        switch id {
        case "name":
            cell.textField?.stringValue = r.name
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: r.path)
        case "dir": cell.textField?.stringValue = PathUtil.abbreviate(r.dir, home: NSHomeDirectory())
        case "hits": cell.textField?.stringValue = r.hits.map(String.init) ?? ""
        case "size": cell.textField?.stringValue = r.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)
        default: cell.textField?.stringValue = r.mtime > 0 ? Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(r.mtime))) : ""
        }
        return cell
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func makeCell(_ id: String) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init("full-" + id)
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 13)
        text.lineBreakMode = id == "dir" ? .byTruncatingHead : .byTruncatingMiddle
        text.textColor = id == "name" ? .labelColor : .secondaryLabelColor
        if id == "size" || id == "hits" { text.alignment = .right }
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = cell.leadingAnchor
        if id == "name" {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            ])
            leading = icon.trailingAnchor
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Multi-select drag out as file URLs.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        URL(fileURLWithPath: rows[row].path) as NSURL
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let sel = table.selectedRowIndexes
        showPreview(sel.count == 1 ? rows[sel.first!] : nil)
    }

    private func showPreview(_ row: Row?) {
        previewToken += 1
        guard let row else {
            quickLook.previewItem = nil
            textPreview.clear()
            return
        }
        if let hit = row.hit {
            quickLook.isHidden = true
            textPreview.isHidden = false
            let token = previewToken
            content.preview(fileId: hit.fileId, expression: expression) { [weak self] data in
                guard let self, token == self.previewToken else { return }
                if let data { self.textPreview.show(data, path: row.path) } else { self.textPreview.clear() }
            }
        } else {
            textPreview.isHidden = true
            quickLook.isHidden = false
            quickLook.previewItem = URL(fileURLWithPath: row.path) as NSURL
        }
    }

    // MARK: Actions

    private var selectedRows: [Row] { table.selectedRowIndexes.map { rows[$0] } }

    @objc private func doubleClicked() {
        if table.clickedRow >= 0 { openSelected(reveal: false) }
    }

    private func openSelected(reveal: Bool) {
        let urls = selectedRows.map { URL(fileURLWithPath: $0.path) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        for r in selectedRows { usage?.recordOpen(path: r.path, fileId: r.fileId) }
        // One content hit: honour 打开方式 at the previewed occurrence.
        if !reveal, selectedRows.count == 1, selectedRows[0].hit != nil {
            if let message = Opener.open(path: urls[0].path, line: textPreview.currentLine, page: textPreview.currentPage), let window {
                let alert = NSAlert()
                alert.messageText = message
                alert.beginSheetModal(for: window)
            }
            return
        }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting(urls) } else { urls.forEach { NSWorkspace.shared.open($0) } }
    }

    private func openReader() {
        guard let r = selectedRows.first, let hit = r.hit else { return }
        onRead?(hit, expression, max(0, textPreview.currentHit))
    }

    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift] else { return false }
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", event.keyCode) {
        case ("1", _): modeControl.selectedSegment = 0; modeChanged(); return true
        case ("2", _): modeControl.selectedSegment = 1; modeChanged(); return true
        case (_, 36), (_, 76):
            if mode == .content { openReader() } else { openSelected(reveal: true) }
            return true
        case ("d", _): toggleFavorites(); return true
        case ("g", _) where mode == .content && !textPreview.isHidden:
            flags.contains(.shift) ? textPreview.goPrev() : textPreview.goNext()
            return true
        case ("c", _) where flags.contains(.shift):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedRows.map(\.path).joined(separator: "\n"), forType: .string)
            return true
        case ("f", _): window?.makeFirstResponder(field); return true
        case (_, 51) where window?.firstResponder === table:
            trashSelected()
            return true
        default: return false
        }
    }

    private func toggleFavorites() {
        guard let usage else { return }
        for r in selectedRows { usage.toggleFavorite(path: r.path, fileId: r.fileId) }
    }

    /// ⌘⌫ with the table focused (so ⌘⌫ in the search field still edits text); asks first.
    private func trashSelected() {
        let targets = selectedRows
        guard !targets.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = targets.count == 1 ? "将“\(targets[0].name)”移到废纸篓？" : "将选中的 \(targets.count) 项移到废纸篓？"
        alert.informativeText = "可以在废纸篓中恢复。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            var failed: [String] = []
            var gone = Set<String>()
            for r in targets {
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: r.path), resultingItemURL: nil)
                    self.usage?.remove(path: r.path)
                    gone.insert(r.path)
                } catch {
                    failed.append(r.name)
                }
            }
            self.ranked.removeAll { gone.contains($0.path) }
            self.resort(keepSelection: false)
            if !failed.isEmpty {
                let a = NSAlert()
                a.messageText = "有 \(failed.count) 项没能移到废纸篓"
                a.informativeText = failed.prefix(5).joined(separator: "、")
                a.beginSheetModal(for: window)
            }
        }
    }
}

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

/// Full window (⌘E, UI-SPEC §6.2): mode and search field on top, a condition bar under them
/// (location, type, date, size, file name, match mode, “在结果中” steps), a sortable
/// multi-select table with a preview for content, and a status bar. A normal window: clicking
/// outside does not close it.
@MainActor
final class FullWindowController: NSWindowController, NSWindowDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
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
        /// A heading row (“收藏”, “最近打开”) above the empty-input lists: `name` is its title.
        var isGroup = false
        /// Listed under “最近打开” (its menu offers removing it from there).
        var isRecent = false
        /// Unique per row (archive members share the archive's path).
        var key: String { hit?.key ?? path }
        var isMember: Bool { hit?.isMember == true }
    }

    private enum Pill: String { case location, type, time, size, fileName, match, refine }

    private let session: SearchSession
    private let usage: UsageStore?
    /// Its own searcher: the launcher's may be cancelled or reused independently.
    private let content = ContentSearcher()
    /// The match mode of this window's results (the reader needs the same one).
    var matchMode: MatchMode { content.mode }
    private let field = NSSearchField()
    private let modeControl = NSSegmentedControl()
    private let pillBar = NSStackView()
    private var pills: [Pill: ConditionPill] = [:]
    private let clearAll = ConditionForm.link(L("清除全部"), target: nil, action: nil)
    private let queryToggle = NSButton()
    private let queryRow = NSStackView()
    private let queryText = NSTextField(labelWithString: "")
    private let table = ResultTable()
    private let tableScroll = NSScrollView()
    private let placeholder = ResultPlaceholderView()
    private let textPreview = PreviewPane()
    private var previewArea: NSView?
    private let previewDivider = NSBox()
    private lazy var previewWidth = previewArea!.widthAnchor.constraint(equalToConstant: 440)
    private lazy var previewDividerWidth = previewDivider.widthAnchor.constraint(equalToConstant: 1)
    private let statusText = NSTextField(labelWithString: "")
    private let showAllButton = NSButton(title: L("显示全部"), target: nil, action: nil)
    private let keysText = NSTextField(labelWithString: "")
    private var ranked: [Row] = []
    private var rows: [Row] = []
    private var mode: Preferences.Mode = .name
    private var expression = ""
    private var previewToken = 0
    /// The condition bar, per mode (their fields differ); folders added with “选择其他文件夹…”.
    private var conditions: [Preferences.Mode: SearchConditions] = [.name: .init(), .content: .init()]
    private var extraFolders: [Preferences.Mode: [String]] = [:]
    private var matchIndex = 0
    /// “在结果中” steps, newest last, ANDed onto the query in both modes.
    private var refinements: [Refinement] = []
    private var popover: NSPopover?
    private var popoverPill: Pill?
    /// The open popover's controls, read back when they change.
    private var popoverControls: [String: NSControl] = [:]
    private var refineStepsColumn: NSStackView?
    private var refineUndoButton: NSButton?
    /// Name results: the engine counts every match but hands over the best `nameCap`. “显示全部”
    /// (or sorting by a column, up to `autoAllLimit` matches) fetches them all, so a column sort
    /// orders every match instead of the top few thousand.
    private static let nameCap = 5000
    private static let autoAllLimit = 100_000
    private var showAllNames = false
    private var lastNames: SearchOutput?
    private var lastContent: ContentOutput?

    var onRead: ((ContentHit, String, Int) -> Void)?
    /// Extract these catalog files again; replies how many were queued.
    var reindex: (([Int64], @escaping @MainActor @Sendable (Int) -> Void) -> Void)?
    /// Opens Settings at the index scope (the content placeholder links there).
    var onOpenScopeSettings: (() -> Void)?
    /// Dev hook (XS_READER): open the first content result in the reader once.
    var openFirstInReader = false
    var nameScope: () -> NameScope = { .default }
    var contentScope: () -> ContentScope = { .default }

    static let times: [(String, String?)] = [(L("不限"), nil), (L("今天"), "today"), (L("最近 7 天"), "7d"), (L("最近 30 天"), "30d"), (L("本月"), "thismonth"), (L("今年"), "thisyear")]
    /// Size presets in MB: lower end included, upper end excluded.
    static let sizes: [(String, Double?, Double?)] = [(L("小于 1 MB"), nil, 1), (L("1 – 100 MB"), 1, 100), (L("大于 100 MB"), 100, nil)]
    static let units = ["kb", "mb", "gb"]
    static let kinds: [(FileKind, String)] = [(.folder, L("文件夹")), (.pdf, "PDF"), (.word, L("文档")), (.sheet, L("表格")), (.slide, L("演示")), (.ofd, "OFD"),
                                              (.text, L("文本 / 代码")), (.image, L("图片")), (.video, L("视频")), (.audio, L("音频")), (.archive, L("压缩包")), (.app, L("应用"))]
    static let contentTypes: [(ContentType, String)] = [(.pdf, "PDF"), (.docx, L("Word（docx、odt）")), (.doc, L("Word（doc）")), (.sheet, "Excel"), (.slide, "PowerPoint"),
                                                        (.text, L("文本 / 代码")), (.ofd, "OFD"), (.web, L("网页")), (.ebook, L("电子书")), (.rtf, "RTF"), (.archive, L("压缩包")), (.wps, L("WPS 文字")), (.email, L("邮件")), (.mindmap, L("思维导图"))]
    static let matchModes = [L("宽松"), L("区分大小写"), L("严格原文")]

    init(session: SearchSession, usage: UsageStore?) {
        self.session = session
        self.usage = usage
        content.indexSource = session.content
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 830),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 1140, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("XSearchFull")
        super.init(window: window)
        QuickLookKeyboard.install()
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

        // Toolbar: mode first (it decides what the field searches), then the field and ⌘/ help.
        modeControl.segmentCount = 2
        for (i, (title, symbol, tip)) in [(L("名称"), "doc.on.doc", L("按文件名搜索（⌘1）")), (L("内容"), "text.magnifyingglass", L("在文件内容中搜索（⌘2）"))].enumerated() {
            modeControl.setLabel(title, forSegment: i)
            modeControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), forSegment: i)
            modeControl.setImageScaling(.scaleProportionallyDown, forSegment: i)
            modeControl.setToolTip(tip, forSegment: i)
        }
        modeControl.trackingMode = .selectOne
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        field.font = .systemFont(ofSize: 15)
        field.controlSize = .large
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(fieldAction)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let help = NSButton(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: L("语法速查"))!, target: self, action: #selector(showSyntaxHelp))
        help.isBordered = false
        help.contentTintColor = .secondaryLabelColor
        help.toolTip = L("语法速查（⌘/）")
        help.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        let toolbar = ConditionForm.row([modeControl, field, help], spacing: 14)
        // Below the window buttons, from the same left edge as the condition bar.
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        // Condition bar: fixed-width pills, then 清除全部 (always laid out, hidden when unused) and
        // the query toggle, so nothing moves as conditions come and go.
        pillBar.spacing = 8
        clearAll.target = self
        clearAll.action = #selector(clearAllConditions)
        queryToggle.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: L("查看等价的查询文本"))
        queryToggle.isBordered = false
        queryToggle.setButtonType(.toggle)
        queryToggle.contentTintColor = .secondaryLabelColor
        queryToggle.toolTip = L("查看等价的查询文本")
        queryToggle.target = self
        queryToggle.action = #selector(toggleQueryRow)
        let barSpacer = NSView()
        barSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let sep = NSBox()
        sep.boxType = .separator
        sep.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let conds = ConditionForm.row([pillBar, barSpacer, clearAll, sep, queryToggle])
        queryText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        queryText.textColor = .secondaryLabelColor
        queryText.isSelectable = true
        queryText.lineBreakMode = .byTruncatingMiddle
        queryText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let queryCaption = NSTextField(labelWithString: L("等价查询"))
        queryCaption.font = .systemFont(ofSize: 11.5, weight: .medium)
        queryCaption.textColor = .tertiaryLabelColor
        let copy = ConditionForm.link(L("复制"), target: self, action: #selector(copyQuery))
        let querySpacer = NSView()
        querySpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        queryRow.setViews([queryCaption, queryText, querySpacer, copy], in: .leading)
        queryRow.spacing = 8
        queryRow.isHidden = true
        let header = ConditionForm.column([toolbar, conds, queryRow], spacing: 8)
        header.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 10, right: 0)
        conds.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        queryRow.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        for v in [toolbar, conds, queryRow] { v.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        toolbar.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let headerBox = NSBox()
        headerBox.boxType = .custom
        headerBox.borderWidth = 0
        headerBox.fillColor = Theme.sidebar
        headerBox.contentViewMargins = .zero
        let headerLine = NSBox()
        headerLine.boxType = .separator

        for (id, title, width) in [("name", L("名称"), 320.0), ("dir", L("位置"), 300.0), ("kind", L("类型"), 90.0), ("hits", L("命中"), 60.0),
                                   ("size", L("大小"), 90.0), ("mtime", L("修改时间"), 140.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "name" || id == "dir" || id == "kind")
            if id == "size" || id == "hits" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        // The table's width changes with the mode (no preview for names): columns share it.
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        table.onReturn = { [weak self] flags in self?.openSelected(reveal: flags.contains(.command)) }
        table.onSpace = { [weak self] in self?.toggleQuickLook() }
        table.isAtTop = { [weak self] in (self?.table.selectedRow ?? 0) <= (self?.firstSelectableRow ?? 0) }
        table.onLeave = { [weak self] in self?.focusInput() }
        table.onTyping = { [weak self] event in
            self?.focusInput()
            self?.field.currentEditor()?.keyDown(with: event)
        }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.contextMenu = { [weak self] row in self?.contextMenu(row: row) }
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .noBorder

        textPreview.locate.title = L("阅读窗口 ⌘↵")
        textPreview.onLocate = { [weak self] in self?.openReader() }
        let preview = NSView()
        textPreview.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(textPreview)
        NSLayoutConstraint.activate([
            textPreview.leadingAnchor.constraint(equalTo: preview.leadingAnchor), textPreview.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            textPreview.topAnchor.constraint(equalTo: preview.topAnchor), textPreview.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
        ])
        previewArea = preview
        previewDivider.boxType = .separator

        // Status bar: the count (and 显示全部) on the left, shortcuts on the right.
        statusText.font = .systemFont(ofSize: 12)
        statusText.textColor = .secondaryLabelColor
        statusText.lineBreakMode = .byTruncatingTail
        showAllButton.bezelStyle = .push
        showAllButton.controlSize = .mini
        showAllButton.font = .systemFont(ofSize: 11)
        showAllButton.target = self
        showAllButton.action = #selector(showAllClicked)
        showAllButton.isHidden = true
        keysText.lineBreakMode = .byTruncatingHead
        keysText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let status = ConditionForm.row([statusText, showAllButton, statusSpacer, keysText])
        status.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        let statusBox = NSBox()
        statusBox.boxType = .custom
        statusBox.borderWidth = 0
        statusBox.fillColor = Theme.sidebar
        statusBox.contentViewMargins = .zero
        let statusLine = NSBox()
        statusLine.boxType = .separator

        let views: [NSView] = [headerBox, header, headerLine, tableScroll, previewDivider, preview, placeholder, statusBox, statusLine, status]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerBox.topAnchor.constraint(equalTo: root.topAnchor),
            headerBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerBox.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerLine.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            tableScroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: statusLine.topAnchor),
            previewDivider.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            previewDivider.bottomAnchor.constraint(equalTo: statusLine.topAnchor),
            previewDivider.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor),
            previewDividerWidth,
            preview.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: previewDivider.trailingAnchor),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: statusLine.topAnchor),
            previewWidth,
            placeholder.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            placeholder.bottomAnchor.constraint(equalTo: statusLine.topAnchor),

            statusLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusLine.bottomAnchor.constraint(equalTo: statusBox.topAnchor),
            statusBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBox.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBox.heightAnchor.constraint(equalToConstant: 28),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.centerYAnchor.constraint(equalTo: statusBox.centerYAnchor),
        ])
        placeholder.isHidden = true
        applyMode()
    }

    /// Everything that depends on the mode: pills, columns, placeholder text, preview.
    private func applyMode() {
        modeControl.selectedSegment = mode == .content ? 1 : 0
        field.placeholderString = mode == .content ? L("搜索文档正文，例如 支付条件") : L("搜索文件和文件夹名称")
        rebuildPills()
        for c in table.tableColumns {
            switch c.identifier.rawValue {
            case "kind", "size": c.isHidden = mode == .content
            case "hits": c.isHidden = mode != .content
            default: break
            }
        }
        table.sortDescriptors = []
        updatePreviewVisibility()
    }

    // MARK: Condition bar

    private func rebuildPills() {
        popover?.close()
        pillBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pills = [:]
        let order: [(Pill, String, CGFloat)] = mode == .content
            ? [(.location, L("位置"), 140), (.type, L("类型"), 140), (.time, L("时间"), 140), (.size, L("大小"), 116), (.fileName, L("文件名"), 140), (.match, L("匹配"), 112), (.refine, L("在结果中"), 150)]
            : [(.location, L("位置"), 170), (.type, L("类型"), 170), (.time, L("时间"), 146), (.size, L("大小"), 130), (.refine, L("在结果中"), 180)]
        for (id, label, width) in order {
            let pill = ConditionPill(label: label, width: width)
            pill.onOpen = { [weak self] in self?.openPopover(id) }
            pill.onClear = { [weak self] in self?.clear(id) }
            pills[id] = pill
            pillBar.addArrangedSubview(pill)
        }
        updatePills()
    }

    private var current: SearchConditions {
        get { conditions[mode] ?? SearchConditions() }
        set { conditions[mode] = newValue }
    }

    /// Pill values from the state; also 清除全部 and the query row.
    private func updatePills() {
        let c = current
        let home = NSHomeDirectory()
        func set(_ id: Pill, _ on: Bool, _ value: String) {
            pills[id]?.isOn = on
            pills[id]?.value = value
        }
        set(.location, c.hasFolders, c.hasFolders ? c.folders.map { PathUtil.abbreviate($0, home: home) }.joined(separator: L("、")) : L("全部"))
        let typeNames = mode == .content ? Self.contentTypes.filter { c.contentTypes.contains($0.0) }.map(\.1) : Self.kinds.filter { c.kinds.contains($0.0) }.map(\.1)
        set(.type, c.hasTypes, c.hasTypes ? (typeNames + c.extensionList.map { "." + $0 }).joined(separator: L("、")) : L("全部"))
        set(.time, c.hasModified, timeLabel(c))
        set(.size, c.hasSize, sizeLabel(c))
        set(.fileName, !c.fileNames.isEmpty, c.fileNames.isEmpty ? L("不限") : c.fileNames.joined(separator: ";"))
        set(.match, matchIndex != 0, Self.matchModes[matchIndex])
        let steps = refinements.map(stepLabel)
        set(.refine, !refinements.isEmpty, steps.count == 1 ? steps[0] : steps.isEmpty ? L("筛选") : L("%@ 步", "\(steps.count)"))
        if steps.count > 1 { pills[.refine]?.toolTip = L("在结果中") + L("：") + steps.joined(separator: L("；")) }
        let any = activeCount > 0
        clearAll.alphaValue = any ? 1 : 0
        clearAll.isEnabled = any
        queryText.stringValue = queryString
        queryText.toolTip = queryString
    }

    private var activeCount: Int {
        let c = current
        return [c.hasFolders, c.hasTypes, c.hasModified, c.hasSize, mode == .content && !c.fileNames.isEmpty, mode == .content && matchIndex != 0].filter { $0 }.count + refinements.count
    }

    private func timeLabel(_ c: SearchConditions) -> String {
        if let m = c.modified { return Self.times.first { $0.1 == m }?.0 ?? m }
        let f = DateFormatter()
        f.locale = Loc.locale
        f.setLocalizedDateFormatFromTemplate("yMd")
        switch (c.modifiedFrom, c.modifiedTo) {
        case let (a?, b?): return f.string(from: a) + " – " + f.string(from: b)
        case let (a?, nil): return L("%@ 之后", f.string(from: a))
        case let (nil, b?): return L("%@ 之前", f.string(from: b))
        default: return L("不限")
        }
    }

    private func sizeLabel(_ c: SearchConditions) -> String {
        if c.sizeUnit == "mb", let preset = Self.sizes.first(where: { $0.1 == c.sizeMin && $0.2 == c.sizeMax }) { return preset.0 }
        let n = { (v: Double) in (v == v.rounded() ? String(Int(v)) : String(v)) + " " + c.sizeUnit.uppercased() }
        switch (c.sizeMin.flatMap { $0 > 0 ? $0 : nil }, c.sizeMax) {
        case let (a?, b?): return n(a) + " – " + n(b)
        case let (a?, nil): return "≥ " + n(a)
        case let (nil, b?): return "< " + n(b)
        default: return L("不限")
        }
    }

    private func stepLabel(_ s: Refinement) -> String {
        let term = s.exact ? "“" + s.term + "”" : s.term
        switch s.kind {
        case .all: return L("含 %@", term)
        case .any: return L("含任一 %@", term)
        case .none: return L("不含 %@", term)
        }
    }

    private func clear(_ id: Pill) {
        var c = current
        switch id {
        case .location: c.folders = []
        case .type: c.kinds = []; c.contentTypes = []; c.extensions = ""
        case .time: c.modified = nil; c.modifiedFrom = nil; c.modifiedTo = nil
        case .size: c.sizeMin = nil; c.sizeMax = nil; c.sizeUnit = "mb"
        case .fileName: c.fileName = ""
        case .match: matchIndex = 0
        case .refine: refinements = []
        }
        current = c
        conditionsChanged()
    }

    @objc private func clearAllConditions() {
        popover?.close()
        current = SearchConditions()
        if mode == .content { matchIndex = 0 }
        refinements = []
        conditionsChanged()
    }

    private func conditionsChanged() {
        updatePills()
        runSearch()
    }

    @objc private func toggleQueryRow() {
        queryRow.isHidden = queryToggle.state != .on
        queryToggle.contentTintColor = queryToggle.state == .on ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func copyQuery() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(queryString, forType: .string)
    }

    // MARK: Popovers

    private func openPopover(_ id: Pill) {
        if let p = popover, p.isShown {
            p.close()
            if popoverPill == id { return }
        }
        popoverControls = [:]
        refineStepsColumn = nil
        let pop = NSPopover()
        pop.behavior = .transient
        popoverPill = id
        pop.contentViewController = popoverContent(id)
        popover = pop
        guard let pill = pills[id] else { return }
        pop.show(relativeTo: pill.bounds, of: pill, preferredEdge: .maxY)
        if id == .refine { pop.contentViewController?.view.window?.makeFirstResponder(popoverControls["refine.term"]) }
    }

    private func done() -> NSButton {
        let b = NSButton(title: L("完成"), target: self, action: #selector(closePopover))
        b.keyEquivalent = "\r"
        b.bezelStyle = .push
        return b
    }

    @objc private func closePopover() { popover?.close() }

    /// After the open popover's content grows or shrinks (steps added or undone, custom dates or
    /// sizes shown or hidden): a popover follows its content when it grows, never when it shrinks.
    /// In one step, not animated: the animation runs through several sizes, each one recomposing
    /// the translucent popover over the refreshing results, which flickers.
    private func fitPopover() {
        guard let pop = popover, pop.isShown, let view = pop.contentViewController?.view else { return }
        let size = view.fittingSize
        guard pop.contentSize != size else { return }
        let animates = pop.animates
        pop.animates = false
        pop.contentSize = size
        pop.animates = animates
    }

    @objc private func popoverClear(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = Pill(rawValue: raw) else { return }
        clear(id)
        popover?.close()
    }

    private func clearLink(_ id: Pill) -> NSButton {
        let b = ConditionForm.link(L("清除"), target: self, action: #selector(popoverClear(_:)))
        b.identifier = .init(id.rawValue)
        return b
    }

    private func check(_ title: String, key: String, on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(popoverChanged))
        b.state = on ? .on : .off
        b.lineBreakMode = .byTruncatingMiddle
        popoverControls[key] = b
        return b
    }

    private func radio(_ title: String, key: String, on: Bool) -> NSButton {
        let b = NSButton(radioButtonWithTitle: title, target: self, action: #selector(popoverChanged))
        b.state = on ? .on : .off
        popoverControls[key] = b
        return b
    }

    private func textField(_ placeholder: String, key: String, value: String, width: CGFloat) -> NSTextField {
        let f = ConditionForm.field(placeholder, width: width)
        f.stringValue = value
        f.delegate = self
        popoverControls[key] = f
        return f
    }

    private func popoverContent(_ id: Pill) -> NSViewController {
        let c = current
        switch id {
        case .location:
            let home = NSHomeDirectory()
            let roots = locationRoots + (extraFolders[mode] ?? []).filter { !locationRoots.contains($0) }
            let boxes = roots.map { check(PathUtil.abbreviate($0, home: home), key: "loc." + $0, on: c.folders.contains($0)) }
            let choose = ConditionForm.link(L("选择其他文件夹…"), target: self, action: #selector(chooseFolder))
            let content: [NSView] = [ConditionForm.title(mode == .content ? L("在这些内容索引位置中") : L("在这些位置中")),
                                     ConditionForm.column(boxes.isEmpty ? [ConditionForm.hint(L("（未设置）"), width: 260)] : boxes), choose,
                                     ConditionForm.hint(mode == .content ? L("不选表示全部内容索引范围。") : L("不选表示全部位置。"), width: 260)]
            return ConditionForm.controller(width: 300, content: content, left: clearLink(id), done: done())
        case .type:
            let items: [(String, String, Bool)] = mode == .content
                ? Self.contentTypes.map { ("type." + $0.0.rawValue, $0.1, c.contentTypes.contains($0.0)) }
                : Self.kinds.map { ("type." + $0.0.rawValue, $0.1, c.kinds.contains($0.0)) }
            let boxes = items.map { check($0.1, key: $0.0, on: $0.2) }
            // Two columns: a dozen types without a long list.
            let half = (boxes.count + 1) / 2
            let grid = ConditionForm.row([ConditionForm.column(Array(boxes[..<half])), ConditionForm.column(Array(boxes[half...]))], spacing: 24)
            grid.alignment = .top
            let content: [NSView] = [ConditionForm.title(L("文件类型")), grid, ConditionForm.title(L("其他扩展名")),
                                     textField(L("例如 key numbers"), key: "type.ext", value: c.extensions, width: 308),
                                     ConditionForm.hint(L("不选表示全部类型；可多选。"), width: 308)]
            return ConditionForm.controller(width: 340, content: content, left: clearLink(id), done: done())
        case .time:
            let custom = c.modified == nil && (c.modifiedFrom != nil || c.modifiedTo != nil)
            var radios = Self.times.enumerated().map { i, t in radio(t.0, key: "time.\(i)", on: !custom && c.modified == t.1) }
            radios.append(radio(L("自定义日期"), key: "time.custom", on: custom))
            let from = NSButton(checkboxWithTitle: L("从"), target: self, action: #selector(popoverChanged))
            let to = NSButton(checkboxWithTitle: L("到"), target: self, action: #selector(popoverChanged))
            from.state = c.modifiedFrom != nil ? .on : .off
            to.state = c.modifiedTo != nil ? .on : .off
            let fromPicker = NSDatePicker(), toPicker = NSDatePicker()
            for (p, d, key) in [(fromPicker, c.modifiedFrom, "time.fromDate"), (toPicker, c.modifiedTo, "time.toDate")] {
                p.datePickerStyle = .textFieldAndStepper
                p.datePickerElements = .yearMonthDay
                p.dateValue = d ?? Date()
                p.target = self
                p.action = #selector(popoverChanged)
                popoverControls[key] = p
            }
            popoverControls["time.from"] = from
            popoverControls["time.to"] = to
            let dates = ConditionForm.column([ConditionForm.row([from, fromPicker]), ConditionForm.row([to, toPicker])], spacing: 6)
            dates.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            dates.identifier = .init("time.dates")
            dates.isHidden = !custom
            timeDates = dates
            let content: [NSView] = [ConditionForm.title(L("修改时间")), ConditionForm.column(radios), dates]
            return ConditionForm.controller(width: 280, content: content, left: clearLink(id), done: done())
        case .size:
            let preset = c.sizeUnit == "mb" ? Self.sizes.firstIndex { $0.1 == c.sizeMin && $0.2 == c.sizeMax } : nil
            let custom = c.hasSize && preset == nil
            var radios = [radio(L("不限"), key: "size.none", on: !c.hasSize)]
            radios += Self.sizes.enumerated().map { i, s in radio(s.0, key: "size.\(i)", on: preset == i) }
            radios.append(radio(L("自定义"), key: "size.custom", on: custom))
            let num = { (v: Double?) in v.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" }
            let unit = NSPopUpButton()
            unit.addItems(withTitles: ["KB", "MB", "GB"])
            unit.selectItem(at: Self.units.firstIndex(of: c.sizeUnit) ?? 1)
            unit.target = self
            unit.action = #selector(popoverChanged)
            popoverControls["size.unit"] = unit
            let fields = ConditionForm.row([textField(L("最小"), key: "size.min", value: num(c.sizeMin), width: 64), NSTextField(labelWithString: L("至")),
                                            textField(L("最大"), key: "size.max", value: num(c.sizeMax), width: 64), unit], spacing: 6)
            fields.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            fields.isHidden = !custom
            sizeFields = fields
            let content: [NSView] = [ConditionForm.title(L("文件大小")), ConditionForm.column(radios), fields,
                                     ConditionForm.hint(L("不含上限本身，例如 1 – 100 MB 不含 100 MB。"), width: 248)]
            return ConditionForm.controller(width: 280, content: content, left: clearLink(id), done: done())
        case .fileName:
            let content: [NSView] = [ConditionForm.title(L("文件名包含")), textField(L("例如 验收;报告"), key: "name", value: c.fileName, width: 268),
                                     ConditionForm.hint(L("分号分隔，任一满足即可；支持 * 和 ?。"), width: 268)]
            return ConditionForm.controller(width: 300, content: content, left: clearLink(id), done: done())
        case .match:
            let radios = Self.matchModes.enumerated().map { i, m in radio(m, key: "match.\(i)", on: matchIndex == i) }
            let content: [NSView] = [ConditionForm.title(L("匹配方式")), ConditionForm.column(radios),
                                     ConditionForm.hint(L("宽松：忽略大小写、全半角和繁简差异。"), width: 228)]
            return ConditionForm.controller(width: 260, content: content, left: clearLink(id), done: done())
        case .refine:
            let term = textField(L("输入词语，空格分隔"), key: "refine.term", value: "", width: 260)
            let exact = NSButton(checkboxWithTitle: L("完全匹配"), target: nil, action: nil)
            exact.toolTip = L("整栏文字作为一个整体，须按原样连续出现（空格也算）")
            popoverControls["refine.exact"] = exact
            let operators = Preferences.shared.querySyntax.operators
            var buttons: [NSButton] = []
            for (title, kind, tip) in [(L("包含"), Refinement.Kind.all, L("须全部出现（↵）")), (L("包含任一"), .any, L("有一个即可")), (L("排除"), .none, L("含任一即去掉（⌥↵）"))] {
                let b = NSButton(title: title, target: self, action: #selector(addStep(_:)))
                b.bezelStyle = .push
                b.identifier = .init(kind.rawValue)
                b.toolTip = tip
                b.isEnabled = kind == .all || operators
                buttons.append(b)
            }
            let steps = ConditionForm.column([], spacing: 4)
            refineStepsColumn = steps
            let undo = ConditionForm.link(L("撤回上一步"), target: self, action: #selector(undoStep))
            refineUndoButton = undo
            var content: [NSView] = [ConditionForm.title(L("在当前结果中继续筛选")), ConditionForm.row([term, exact]), ConditionForm.row(buttons),
                                     ConditionForm.hint(L("包含：须全部出现；包含任一：有一个即可；排除：含任一即去掉。"), width: 368)]
            if !operators { content.append(ConditionForm.hint(L("“包含任一”和“排除”需要开启 设置 → 搜索语法 中的运算符。"), width: 368)) }
            content.append(steps)
            let close = done()
            close.keyEquivalent = ""
            let vc = ConditionForm.controller(width: 400, content: content, left: undo, done: close)
            updateRefineSteps()
            return vc
        }
    }

    private var timeDates: NSStackView?
    private var sizeFields: NSStackView?

    /// Folders the location popover offers: the content scope's roots, or the name scope's
    /// folders (a few common ones when the whole disk is indexed).
    private var locationRoots: [String] {
        let home = NSHomeDirectory()
        if mode == .content { return contentScope().roots(home: home) }
        let scope = nameScope()
        return scope.wholeDisk ? ["~/Desktop", "~/Documents", "~/Downloads"].map { home + $0.dropFirst() } : scope.folders.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
    }

    @objc private func chooseFolder() {
        guard let window else { return }
        popover?.close()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            let path = url.path
            if !self.locationRoots.contains(path) { self.extraFolders[self.mode, default: []].append(path) }
            var c = self.current
            if !c.folders.contains(path) { c.folders.append(path) }
            self.current = c
            self.conditionsChanged()
        }
    }

    /// Reads the open popover's controls back into the state.
    @objc private func popoverChanged(_ sender: Any?) {
        guard let id = popoverPill else { return }
        var c = current
        func on(_ key: String) -> Bool { (popoverControls[key] as? NSButton)?.state == .on }
        func text(_ key: String) -> String { popoverControls[key]?.stringValue ?? "" }
        switch id {
        case .location:
            let roots = locationRoots + (extraFolders[mode] ?? [])
            c.folders = roots.filter { on("loc." + $0) }
        case .type:
            if mode == .content { c.contentTypes = Set(ContentType.allCases.filter { on("type." + $0.rawValue) }) } else { c.kinds = Set(FileKind.allCases.filter { on("type." + $0.rawValue) }) }
            c.extensions = text("type.ext")
        case .time:
            let custom = on("time.custom")
            timeDates?.isHidden = !custom
            fitPopover()
            if custom {
                c.modified = nil
                c.modifiedFrom = on("time.from") ? (popoverControls["time.fromDate"] as? NSDatePicker)?.dateValue : nil
                c.modifiedTo = on("time.to") ? (popoverControls["time.toDate"] as? NSDatePicker)?.dateValue : nil
            } else {
                c.modifiedFrom = nil
                c.modifiedTo = nil
                c.modified = Self.times.indices.first { on("time.\($0)") }.flatMap { Self.times[$0].1 }
            }
        case .size:
            let custom = on("size.custom")
            sizeFields?.isHidden = !custom
            fitPopover()
            if custom {
                c.sizeMin = Double(text("size.min").trimmingCharacters(in: .whitespaces))
                c.sizeMax = Double(text("size.max").trimmingCharacters(in: .whitespaces))
                c.sizeUnit = Self.units[max(0, (popoverControls["size.unit"] as? NSPopUpButton)?.indexOfSelectedItem ?? 1)]
            } else if let i = Self.sizes.indices.first(where: { on("size.\($0)") }) {
                (c.sizeMin, c.sizeMax, c.sizeUnit) = (Self.sizes[i].1, Self.sizes[i].2, "mb")
            } else {
                (c.sizeMin, c.sizeMax, c.sizeUnit) = (nil, nil, "mb")
            }
        case .fileName: c.fileName = text("name")
        case .match: matchIndex = (0..<Self.matchModes.count).first { on("match.\($0)") } ?? 0
        case .refine: return
        }
        current = c
        conditionsChanged()
    }

    @objc private func addStep(_ sender: NSButton) {
        addStep(kind: Refinement.Kind(rawValue: sender.identifier?.rawValue ?? "") ?? .all)
    }

    private func addStep(kind: Refinement.Kind) {
        guard let field = popoverControls["refine.term"] as? NSTextField else { return }
        let step = Refinement(term: field.stringValue.trimmingCharacters(in: .whitespaces), kind: kind, exact: (popoverControls["refine.exact"] as? NSButton)?.state == .on)
        guard step.isUsable(Preferences.shared.querySyntax) else { NSSound.beep(); return }
        refinements.append(step)
        field.stringValue = ""
        (popoverControls["refine.exact"] as? NSButton)?.state = .off
        updateRefineSteps()
        conditionsChanged()
    }

    @objc private func undoStep() {
        guard !refinements.isEmpty else { return }
        refinements.removeLast()
        updateRefineSteps()
        conditionsChanged()
    }

    private func removeStep(at i: Int) {
        guard refinements.indices.contains(i) else { return }
        refinements.remove(at: i)
        updateRefineSteps()
        conditionsChanged()
    }

    /// The steps inside the “在结果中” popover: one removable tag per line, newest last.
    private func updateRefineSteps() {
        guard let column = refineStepsColumn else { return }
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        refineUndoButton?.isEnabled = !refinements.isEmpty
        defer { fitPopover() }
        guard !refinements.isEmpty else { return }
        column.addArrangedSubview(ConditionForm.title(L("已加的步骤（%@）· 点 ✕ 移除", "\(refinements.count)")))
        for (i, step) in refinements.enumerated() {
            let tag = StepTag(text: stepLabel(step), negative: step.kind == .none)
            tag.onRemove = { [weak self] in self?.removeStep(at: i) }
            column.addArrangedSubview(tag)
        }
    }

    // MARK: Window

    /// Closed: stop the query and any queued preview, and let the shown document go (the window
    /// itself stays for next time). `show` searches again and selects anew.
    func windowWillClose(_ notification: Notification) {
        content.cancel()
        popover?.close()
        previewToken += 1
        closeQuickLook()
        table.deselectAll(nil)
        previewToken += 1
        textPreview.clear()
    }

    // MARK: Query

    /// Opens with the launcher's input and mode (UI-SPEC §6.2: the query carries over). A query
    /// from the launcher is a new search: conditions and steps start empty.
    func show(text: String, mode: Preferences.Mode) {
        // The index instance can change (content rebuild): follow the launcher's searcher.
        content.indexSource = session.content
        matchIndex = ["loose", "caseSensitive", "strict"].firstIndex(of: Preferences.shared.matchMode) ?? 0
        field.stringValue = text
        conditions = [.name: .init(), .content: .init()]
        refinements = []
        self.mode = mode
        applyMode()
        showWindow(nil)
        bringToFront(window)
        window?.makeFirstResponder(field)
        runSearch()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as AnyObject? === field { runSearch(); return }
        // Popover text fields (extensions, file name, size); the refine term waits for a button.
        if let f = obj.object as? NSTextField, f !== popoverControls["refine.term"] { popoverChanged(f) }
    }

    @objc private func fieldAction() { runSearch() }

    /// ↓ takes the list: space previews there, ↑ on the first row comes back. In the refine
    /// popover ↵ adds a “包含” step and ⌥↵ an “排除” one.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === popoverControls["refine.term"] {
            guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                  !textView.hasMarkedText() else { return false }
            addStep(kind: NSEvent.modifierFlags.contains(.option) ? .none : .all)
            return true
        }
        guard control === field, selector == #selector(NSResponder.moveDown(_:)), !textView.hasMarkedText(), let first = firstSelectableRow else { return false }
        let next = table.selectedRow < first ? first : min(table.selectedRow + 1, rows.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
        window?.makeFirstResponder(table)
        return true
    }

    private var firstSelectableRow: Int? { rows.firstIndex { !$0.isGroup } }

    private func focusInput() {
        window?.makeFirstResponder(field)
        let end = (field.stringValue as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    /// The preview belongs to content results; names, the placeholder and no results get the
    /// whole width.
    private func updatePreviewVisibility() {
        let shown = mode == .content && !rows.isEmpty && placeholder.isHidden
        previewArea?.isHidden = !shown
        previewDivider.isHidden = !shown
        previewWidth.constant = shown ? 440 : 0
        previewDividerWidth.constant = shown ? 1 : 0
        if !shown {
            previewToken += 1
            textPreview.clear()
        }
        if mode == .content { closeQuickLook() }
    }

    @objc private func modeChanged() {
        mode = modeControl.selectedSegment == 1 ? .content : .name
        applyMode()
        runSearch()
    }

    /// The input, the condition bar and the steps, in the ordinary query syntax.
    private var queryString: String {
        SearchConditions.query(input: field.stringValue, conditions: current, steps: refinements, content: mode == .content, syntax: Preferences.shared.querySyntax)
    }

    @objc private func showAllClicked() { runSearch(all: true) }

    /// `all`: every name match instead of the best `nameCap`; any other search starts capped again.
    private func runSearch(all: Bool = false) {
        showAllNames = all
        let text = queryString
        queryText.stringValue = text
        if mode == .content {
            content.mode = [MatchMode.loose, .caseSensitive, .strict][matchIndex]
            content.search(text, home: NSHomeDirectory(), syntax: Preferences.shared.querySyntax) { [weak self] out in self?.applyContent(out) }
        } else {
            content.cancel()
            session.search(text, limit: all ? .max : Self.nameCap) { [weak self] out in self?.applyNames(out) }
        }
    }

    private func applyNames(_ out: SearchOutput) {
        guard mode == .name else { return }
        lastNames = out
        var list: [Row] = []
        var lastGroup: ResultItem.Group?
        for item in out.items where out.query.isEmpty || (item.group != .favorites && item.group != .recents) {
            // An empty input lists favorites and recents under their headings.
            if out.query.isEmpty, item.group != lastGroup {
                list.append(Row(name: L(item.group.rawValue, context: "group"), path: "", dir: "", size: 0, mtime: 0, kind: .other, isFolder: false, isGroup: true))
                lastGroup = item.group
            }
            list.append(Row(name: item.name, path: item.path, dir: (item.path as NSString).deletingLastPathComponent, size: item.size, mtime: item.mtime,
                            hits: nil, kind: item.kind, isFolder: item.kind == .folder, fileId: item.fileId, hit: nil, isRecent: item.group == .recents))
        }
        ranked = list
        let capped = !out.query.isEmpty && out.total > out.items.count
        // A new query while a column sort is on: sort every match, not the top ones.
        if capped, !showAllNames, !table.sortDescriptors.isEmpty, out.total <= Self.autoAllLimit {
            runSearch(all: true)
            return
        }
        resort(keepSelection: false)
        showPlaceholder()
        updateStatus()
    }

    private func applyContent(_ out: ContentOutput) {
        guard mode == .content else { return }
        lastContent = out
        expression = out.query.expression
        let new = out.hits.map { h in
            // A member's size is unknown here (the archive's would mislead): shown as "—".
            Row(name: h.displayName, path: h.path, dir: h.isMember ? h.displayLocation : h.dir, size: h.isMember ? -1 : h.size, mtime: h.mtime,
                hits: Int(h.hitCount), kind: FileKind.of(extension: NameKey.key((h.displayName as NSString).pathExtension), isDirectory: false, isApp: false),
                isFolder: false, fileId: Int64(h.fileId), hit: h)
        }
        ranked = out.append ? ranked + new : new
        resort(keepSelection: out.append)
        showPlaceholder()
        updateStatus()
        if openFirstInReader, let first = rows.first?.hit {
            openFirstInReader = false
            onRead?(first, expression, 0)
        }
    }

    // MARK: Placeholder and status

    /// Content search before typing: its scope and examples. Either mode with no results: why,
    /// and what to try.
    private func showPlaceholder() {
        let input = field.stringValue.trimmingCharacters(in: .whitespaces)
        var visible = false
        if mode == .content, let out = lastContent, out.query.isEmpty {
            visible = true
            let home = NSHomeDirectory()
            let roots = contentScope().roots(home: home).map { PathUtil.abbreviate($0, home: home) }
            let stats = session.contentStats?() ?? ContentStats()
            let scope = roots.isEmpty ? L("还没有设置内容索引范围。") : L("范围：%@，共 %@ 个已索引文档。", roots.joined(separator: L("、")), Theme.count(stats.indexed))
            let examples = [(L("支付条件"), L("含这个词")), (L("合同 -草稿"), L("含“合同”，不含“草稿”")), (L("\"年度 报告\""), L("按原样连续出现")), (L("验收 | 终验"), L("含其中任一"))]
                .map { ResultPlaceholderView.example($0.0, $0.1, target: self, action: #selector(useExample(_:))) }
            let exampleRow = ConditionForm.row(examples)
            let settings = ConditionForm.link(L("修改内容索引范围"), target: self, action: #selector(openScopeSettings))
            let note = NSTextField(labelWithString: L("按 ⌘/ 查看全部语法"))
            note.font = .systemFont(ofSize: 12)
            note.textColor = .tertiaryLabelColor
            placeholder.show(symbol: "text.magnifyingglass", title: L("在文档正文中搜索"), message: scope, extras: [settings, exampleRow, note])
        } else if rows.isEmpty, isFinished, !queryString.isEmpty {
            visible = true
            var reasons: [(String, NSButton?)] = []
            if activeCount > 0 {
                reasons.append((L("已设 %@ 个条件，可能把结果都排除了。", "\(activeCount)"), ConditionForm.link(L("清除全部条件"), target: self, action: #selector(clearAllConditions))))
            }
            if mode == .content {
                if let e = lastContent?.error { reasons.insert((Loc.display(e), nil), at: 0) }
                reasons.append((L("文件可能不在内容索引范围内。"), ConditionForm.link(L("修改内容索引范围"), target: self, action: #selector(openScopeSettings))))
                reasons.append((L("扫描件需要文字识别后才能搜到正文。"), nil))
            } else {
                reasons.append((L("名称搜索按字面字符匹配，不支持拼音。"), ConditionForm.link(L("改为搜索正文"), target: self, action: #selector(switchToContent))))
            }
            let what = input.isEmpty ? L("符合条件的文件") : mode == .content ? L("正文中含“%@”的文件", input) : L("名称中含“%@”的项目", input)
            placeholder.show(symbol: nil, title: L("没有找到%@", what), message: nil, extras: [ResultPlaceholderView.reasons(reasons)])
        }
        placeholder.isHidden = !visible
        tableScroll.isHidden = visible
        updatePreviewVisibility()
    }

    private var isFinished: Bool {
        mode == .content ? (lastContent?.done ?? false) : lastNames != nil
    }

    @objc private func useExample(_ sender: NSButton) {
        field.stringValue = sender.identifier?.rawValue ?? ""
        focusInput()
        runSearch()
    }

    @objc private func openScopeSettings() { onOpenScopeSettings?() }

    @objc private func switchToContent() {
        mode = .content
        applyMode()
        runSearch()
    }

    private func updateStatus() {
        var parts: [String] = []
        var capped = false
        if mode == .content {
            let stats = session.contentStats?() ?? ContentStats()
            if let out = lastContent, !out.query.isEmpty {
                if let e = out.error {
                    parts.append(Loc.display(e))
                } else {
                    parts.append(L("%@ 个文件", "\(Theme.count(ranked.count))") + (out.capped ? L("（前 %@ 个）", "\(Theme.count(ranked.count))") : ""))
                    if !out.done { parts.append(L("仍在搜索… 已核验 %@ / %@", "\(Theme.count(Int(out.verified)))", "\(Theme.count(Int(out.candidates)))")) }
                }
            } else {
                parts.append(L("内容索引 %@ 个文件", "\(Theme.count(stats.indexed))"))
                if stats.paused { parts.append(L("已暂停")) }
                if stats.pending > 0 { parts.append(L("待处理 %@", "\(Theme.count(stats.pending))")) }
            }
        } else if let out = lastNames, !out.query.isEmpty {
            capped = out.total > out.items.count
            let total = L("%@ 项", "\(Theme.count(out.total))")
            if !capped {
                parts.append(total)
            } else if table.sortDescriptors.isEmpty {
                parts.append(total + L("（显示前 %@ 项）", "\(Theme.count(out.items.count))"))
            } else {
                parts.append(total + L("（显示前 %@ 项，排序仅限这些）", "\(Theme.count(out.items.count))"))
            }
        } else {
            let st = session.names.status
            switch st.phase {
            case .starting: parts.append(L("正在打开文件名索引"))
            case .scanning: parts.append(L("正在建立文件名索引 · %@ 项", "\(Theme.count(st.count))"))
            case .ready: parts.append(L("名称索引 %@ 项", "\(Theme.count(st.count))"))
            case .failed: parts.append(L("文件名索引出错，详见设置"))
            }
        }
        statusText.stringValue = parts.joined(separator: " · ")
        showAllButton.isHidden = !capped
        let empty = mode == .content ? (lastContent?.query.isEmpty ?? true) : (lastNames?.query.isEmpty ?? true)
        let keys: [(String, String)] = empty ? [("⌘1", L("名称")), ("⌘2", L("内容")), ("⌘/", L("语法"))]
            : mode == .content ? [("↵", L("打开")), ("⌘↵", L("阅读窗口")), ("⌘G", L("下一处"))]
            : [("↵", L("打开")), ("⌘↵", L("在访达中显示")), (L("空格"), L("快速查看")), ("⌘D", L("收藏"))]
        keysText.attributedStringValue = LauncherController.hintString(keys)
    }

    @objc private func showSyntaxHelp() {
        let pop = NSPopover()
        pop.behavior = .transient
        let view = SyntaxHelpView(sections: LauncherController.syntaxHelp(mode: mode, syntax: Preferences.shared.querySyntax),
                                  footer: L("可在 设置 → 搜索语法 中开关各项语法。"))
        let vc = NSViewController()
        vc.view = view
        vc.preferredContentSize = view.frame.size
        pop.contentViewController = vc
        pop.contentSize = view.frame.size
        pop.show(relativeTo: field.bounds, of: field, preferredEdge: .maxY)
    }

    // MARK: Sorting

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        // Sorting the top 5000 would put the wrong rows first: fetch every match, then sort.
        if mode == .name, !tableView.sortDescriptors.isEmpty, !showAllNames, let out = lastNames, out.total > out.items.count, out.total <= Self.autoAllLimit {
            runSearch(all: true)
            return
        }
        resort(keepSelection: true)
        updateStatus()
    }

    /// Engine ranking unless a column header was clicked; a second click reverses. The headed
    /// favorites and recents lists keep their order.
    private func resort(keepSelection: Bool) {
        let selected = Set(table.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0].key })
        rows = ranked
        if let d = table.sortDescriptors.first, let key = d.key, !rows.contains(where: \.isGroup) {
            let asc = d.ascending
            func cmp(_ a: Row, _ b: Row) -> Bool {
                switch key {
                case "name": return a.name.localizedStandardCompare(b.name) == (asc ? .orderedAscending : .orderedDescending)
                case "dir": return a.dir.localizedStandardCompare(b.dir) == (asc ? .orderedAscending : .orderedDescending)
                case "kind": return kindLabel(a).localizedStandardCompare(kindLabel(b)) == (asc ? .orderedAscending : .orderedDescending)
                case "hits": return asc ? (a.hits ?? 0) < (b.hits ?? 0) : (a.hits ?? 0) > (b.hits ?? 0)
                case "size": return asc ? a.size < b.size : a.size > b.size
                default: return asc ? a.mtime < b.mtime : a.mtime > b.mtime
                }
            }
            rows.sort(by: cmp)
        }
        table.reloadData()
        updatePreviewVisibility()
        if keepSelection {
            table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].key) && !rows[$0].isGroup }), byExtendingSelection: false)
        } else if let first = firstSelectableRow {
            table.selectRowIndexes([first], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        } else {
            showPreview(nil)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].isGroup }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !rows[row].isGroup }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        if r.isGroup {
            let cell = tableView.makeView(withIdentifier: .init("full-group"), owner: nil) as? NSTableCellView ?? makeCell("group")
            cell.textField?.stringValue = r.name
            return cell
        }
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let cell = tableView.makeView(withIdentifier: .init("full-" + id), owner: nil) as? NSTableCellView ?? makeCell(id)
        cell.toolTip = r.hit?.snippet
        switch id {
        case "name":
            cell.textField?.stringValue = r.name
            cell.imageView?.image = r.hit?.icon ?? (r.kind == .app ? appIcon(atPath: r.path) : NSWorkspace.shared.icon(forFile: r.path))
        case "dir": cell.textField?.stringValue = PathUtil.abbreviate(r.dir, home: NSHomeDirectory())
        case "kind": cell.textField?.stringValue = kindLabel(r)
        case "hits": cell.textField?.stringValue = r.hits.map(String.init) ?? ""
        case "size": cell.textField?.stringValue = r.isFolder || r.size < 0 ? "—" : ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)
        default: cell.textField?.stringValue = r.mtime > 0 ? Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(r.mtime))) : ""
        }
        return cell
    }

    private func kindLabel(_ r: Row) -> String {
        if let label = Self.kinds.first(where: { $0.0 == r.kind })?.1 { return label }
        let ext = (r.name as NSString).pathExtension
        return ext.isEmpty ? L("文件") : ext.uppercased()
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
        text.font = id == "group" ? .systemFont(ofSize: 11.5, weight: .semibold) : .systemFont(ofSize: 13)
        text.lineBreakMode = id == "dir" ? .byTruncatingHead : .byTruncatingMiddle
        text.textColor = id == "name" ? .labelColor : id == "group" ? .tertiaryLabelColor : .secondaryLabelColor
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
            text.leadingAnchor.constraint(equalTo: leading, constant: id == "group" ? 10 : 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Multi-select drag out as file URLs.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        rows[row].isMember || rows[row].isGroup ? nil : URL(fileURLWithPath: rows[row].path) as NSURL
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let sel = table.selectedRowIndexes
        showPreview(sel.count == 1 ? rows[sel.first!] : nil)
        updateQuickLookItems()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    // MARK: Quick Look

    /// File names preview in the system's panel (space, as in Finder); content has its own pane.
    func toggleQuickLook() {
        guard mode == .name, !table.selectedRowIndexes.isEmpty else { return }
        updateQuickLookItems()
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            window?.makeFirstResponder(table)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func updateQuickLookItems() {
        quickLookURLs = table.selectedRowIndexes.filter { $0 < rows.count && !rows[$0].isGroup }.map { URL(fileURLWithPath: rows[$0].path) as NSURL }
    }

    private func closeQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
    }

    /// Quick Look calls its data source on the main thread; the selection is mirrored here for it.
    nonisolated(unsafe) private var quickLookURLs: [NSURL] = []

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        index < quickLookURLs.count ? quickLookURLs[index] : nil
    }

    /// Arrow keys keep moving through the list while the panel is up, as in Finder.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event != nil, event.type == .keyDown else { return false }
        nonisolated(unsafe) let event = event!  // Quick Look delivers synchronously on the main thread.
        return MainActor.assumeIsolated {
            if QuickLookKeyboard.closeIfRequested(event, panel: panel) { return true }
            guard [123, 124, 125, 126].contains(event.keyCode), table.selectedRowIndexes.count == 1 else { return false }
            table.keyDown(with: event)
            return true
        }
    }

    private func showPreview(_ row: Row?) {
        previewToken += 1
        guard let row, let hit = row.hit else {
            textPreview.clear()
            return
        }
        let token = previewToken
        content.preview(fileId: hit.fileId, expression: expression, member: hit.member, memberStart: hit.memberStart) { [weak self] data in
            guard let self, token == self.previewToken else { return }
            if let data { self.textPreview.show(data, path: row.path, location: hit.isMember ? hit.displayLocation : nil) } else { self.textPreview.clear() }
        }
    }

    // MARK: Actions

    private var selectedRows: [Row] { table.selectedRowIndexes.filter { $0 < rows.count && !rows[$0].isGroup }.map { rows[$0] } }

    @objc private func doubleClicked() {
        if table.clickedRow >= 0 { openSelected(reveal: false) }
    }

    private func openSelected(reveal: Bool) {
        let urls = selectedRows.map { URL(fileURLWithPath: $0.path) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        // Archive members are unpacked and opened one by one; ⌘↵ shows the archive.
        if !reveal && selectedRows.contains(where: \.isMember) {
            for r in selectedRows {
                if let h = r.hit, h.isMember { MemberOpener.open(h) } else { NSWorkspace.shared.openInBackground(URL(fileURLWithPath: r.path)) }
            }
            return
        }
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
        if reveal { NSWorkspace.shared.activateFileViewerSelecting(urls) } else { urls.forEach { NSWorkspace.shared.openInBackground($0) } }
    }

    private func openReader() {
        guard let r = selectedRows.first, let hit = r.hit else { return }
        onRead?(hit, expression, max(0, textPreview.currentHit))
    }

    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift] else { return false }
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", event.keyCode) {
        case ("1", _): mode = .name; applyMode(); runSearch(); return true
        case ("2", _): mode = .content; applyMode(); runSearch(); return true
        case ("/", _): showSyntaxHelp(); return true
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
        case ("f", _) where flags.contains(.shift): openPopover(.refine); return true
        case ("f", _): window?.makeFirstResponder(field); return true
        case (_, 51) where window?.firstResponder === table:
            trashSelected()
            return true
        default: return false
        }
    }

    // MARK: Context menu

    /// Right click (CONTEXT-MENU.md): the clicked row becomes the selection unless it is already
    /// part of it, and the menu acts on that row like the launcher's.
    private func contextMenu(row: Int) -> NSMenu? {
        guard rows.indices.contains(row), !rows[row].isGroup else { return nil }
        let wasSelected = table.selectedRowIndexes.contains(row)
        if !wasSelected { table.selectRowIndexes([row], byExtendingSelection: false) }
        let r = rows[row]
        let exists = FileManager.default.fileExists(atPath: r.path)
        let kind: ResultMenu.Target.Kind = !exists ? .missing : r.isMember ? .member : r.kind == .app ? .app : r.isFolder ? .folder : .file
        let target = ResultMenu.Target(kind: kind, path: r.path, name: r.hit?.name ?? r.name, isFavorite: usage?.isFavorite(path: r.path) ?? false,
                                       isRecent: r.isRecent, canRead: r.hit != nil, copyPathText: r.key)
        let actions = ResultMenu.Actions(
            open: { [weak self] in self?.openRow(r, reveal: false) },
            reveal: { [weak self] in self?.openRow(r, reveal: true) },
            read: r.hit.map { hit in { [weak self] in
                guard let self else { return }
                self.onRead?(hit, self.expression, wasSelected ? max(0, self.textPreview.currentHit) : 0)
            } },
            quickLook: mode == .name ? { [weak self] in DispatchQueue.main.async { self?.toggleQuickLook() } } : nil,
            toggleFavorite: { [weak self] in
                guard let self, let usage = self.usage else { return }
                usage.toggleFavorite(path: r.path, fileId: r.fileId)
                self.flash(usage.isFavorite(path: r.path) ? L("已加入收藏") : L("已取消收藏"))
            },
            trash: { [weak self] in self?.trashSelected() },
            removeRecent: { [weak self] in
                self?.usage?.remove(path: r.path)
                self?.runSearch()
            },
            toast: { [weak self] in self?.flash($0) },
            willLeave: { [weak self] in self?.usage?.recordOpen(path: r.path, fileId: r.fileId) })
        var withReindex = actions
        if let hit = r.hit, !hit.isMember, let reindex {
            withReindex.reindex = { [weak self] in
                reindex([Int64(hit.fileId)]) { n in self?.flash(n > 0 ? L("已加入重新索引队列") : L("这个文件不在内容索引范围内")) }
            }
        }
        let menu = NSMenu()
        ResultMenu.build(menu, for: target, actions: withReindex)
        return menu.items.isEmpty ? nil : menu
    }

    /// The menu's 打开 / 在访达中显示 for one row (the selection may hold more).
    private func openRow(_ r: Row, reveal: Bool) {
        if let h = r.hit, h.isMember, !reveal { MemberOpener.open(h); return }
        let url = URL(fileURLWithPath: r.path)
        guard FileManager.default.fileExists(atPath: r.path) else { flash(L("文件已不存在，索引会自动更新")); return }
        usage?.recordOpen(path: r.path, fileId: r.fileId)
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.openInBackground(url) }
    }

    /// A short confirmation in the status bar, then the count again.
    private func flash(_ message: String) {
        statusText.stringValue = message
        flashToken += 1
        let token = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, token == self.flashToken else { return }
            self.updateStatus()
        }
    }

    private var flashToken = 0

    private func toggleFavorites() {
        guard let usage else { return }
        for r in selectedRows where !r.isMember { usage.toggleFavorite(path: r.path, fileId: r.fileId) }
    }

    /// ⌘⌫ with the table focused (so ⌘⌫ in the search field still edits text); asks first.
    private func trashSelected() {
        let targets = selectedRows.filter { !$0.isMember }
        guard let window else { return }
        if targets.isEmpty {
            if !selectedRows.isEmpty {
                let a = NSAlert()
                a.messageText = MemberOpener.notAlone
                a.beginSheetModal(for: window)
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = targets.count == 1 ? L("将“%@”移到废纸篓？", "\(targets[0].name)") : L("将选中的 %@ 项移到废纸篓？", "\(targets.count)")
        alert.informativeText = L("可以在废纸篓中恢复。")
        alert.addButton(withTitle: L("移到废纸篓"))
        alert.addButton(withTitle: L("取消"))
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
                a.messageText = L("有 %@ 项没能移到废纸篓", "\(failed.count)")
                a.informativeText = failed.prefix(5).joined(separator: L("、"))
                a.beginSheetModal(for: window)
            }
        }
    }
}

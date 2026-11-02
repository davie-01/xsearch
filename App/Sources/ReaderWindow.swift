import AppKit
import ApplicationServices
import ContentEngine
import PDFKit
import XSearchCore

/// Reader window (⌘↵ in content mode, UI-SPEC §6.3): every hit listed on the left; PDFs show the
/// original pages with the hits drawn on them, other formats the stored text. Before drawing,
/// the file is checked against the indexed version; a changed file gets no highlights.
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct HitRow {
        var range: NSRange
        var page: Int?
        var location: String
        var context: String
    }

    private let searcher: ContentSearcher
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let banner = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let externalButton = NSButton(title: "在外部打开到第 1 页", target: nil, action: nil)
    private let openButton = NSButton(title: "用默认应用打开", target: nil, action: nil)
    private let revealButton = NSButton(title: "在访达中显示", target: nil, action: nil)
    private let table = NSTableView()
    private let pdfView = PDFView()
    private let textPane = PreviewPane()
    private var rows: [HitRow] = []
    private var path = ""
    private var pdfMarks: [[PDFAnnotation]] = []
    private var pdfSelections: [PDFSelection?] = []
    private var current = -1
    private var token = 0
    var onOpenFile: ((String, Int64?) -> Void)?

    init(searcher: ContentSearcher) {
        self.searcher = searcher
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 770),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("XSearchReader")
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        banner.font = .systemFont(ofSize: 12.5)
        banner.textColor = Theme.warnText
        banner.isHidden = true
        for (b, sel) in [(externalButton, #selector(openExternally)), (openButton, #selector(openDefault)), (revealButton, #selector(reveal))] {
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.target = self
            b.action = sel
        }
        let titles = NSStackView(views: [titleLabel, pathLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let buttons = NSStackView(views: [externalButton, openButton, revealButton])
        buttons.spacing = 8
        let header = NSStackView(views: [titles, NSView(), buttons])
        header.edgeInsets = NSEdgeInsets(top: 34, left: 20, bottom: 10, right: 16)
        header.setHuggingPriority(.defaultHigh, for: .vertical)
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Hit list (280).
        let column = NSTableColumn(identifier: .init("hit"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 54
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        let list = NSStackView(views: [countLabel, listScroll])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 0, right: 6)
        list.wantsLayer = true
        list.layer?.backgroundColor = Theme.sidebar.cgColor

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = NSColor.underPageBackgroundColor
        textPane.locate.isHidden = true
        let stage = NSView()
        for v in [pdfView, textPane] {
            v.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: stage.leadingAnchor), v.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                v.topAnchor.constraint(equalTo: stage.topAnchor), v.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            ])
        }
        let bannerRow = NSStackView(views: [banner])
        bannerRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 6, right: 20)

        for v in [header, bannerRow, list, stage, listScroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        for v in [header, bannerRow, list, stage] as [NSView] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bannerRow.topAnchor.constraint(equalTo: header.bottomAnchor),
            bannerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bannerRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            list.topAnchor.constraint(equalTo: bannerRow.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            list.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            list.widthAnchor.constraint(equalToConstant: 280),
            listScroll.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16),
            stage.topAnchor.constraint(equalTo: bannerRow.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: list.trailingAnchor),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    // MARK: Loading

    /// Shows `hit` and jumps to its `startAt`-th occurrence.
    /// `live`: a live scan's hit, which has no document in the index.
    func show(_ hit: ContentHit, expression: String, mode: MatchMode? = nil, live: Bool = false, startAt: Int = 0) {
        token += 1
        let token = self.token
        path = hit.path
        shownHit = hit
        window?.title = hit.displayName
        titleLabel.stringValue = hit.displayName
        pathLabel.stringValue = hit.displayLocation
        rows = []
        table.reloadData()
        countLabel.stringValue = "正在载入…"
        showWindow(nil)
        bringToFront(window)
        let deliver: @MainActor @Sendable (PreviewData?) -> Void = { [weak self] data in
            guard let self, token == self.token else { return }
            guard let data else {
                self.countLabel.stringValue = live ? "无法读取这个文件" : "索引中已没有这个文件"
                return
            }
            self.load(data, startAt: startAt)
        }
        if live {
            searcher.livePreview(path: hit.path, expression: expression, deliver: deliver)
        } else {
            searcher.preview(fileId: hit.fileId, expression: expression, mode: mode, member: hit.member, memberStart: hit.memberStart, deliver: deliver)
        }
    }

    private func load(_ data: PreviewData, startAt: Int) {
        let doc = data.document
        let stale = PreviewPane.isStale(doc, path: path)
        banner.stringValue = stale ? "文件在建立索引后已修改，命中位置暂不显示；索引会自动更新。" : ""
        banner.isHidden = !stale
        let text = doc.text as NSString
        let anchors = PreviewPane.utf16((try? JSONDecoder().decode([AnchorInfo].self, from: Data(doc.anchorsJson.utf8))) ?? [], in: doc.text)
        let ranges = stale ? [] : data.highlights.map { NSRange(location: Int($0.start), length: Int($0.end - $0.start)) }.filter { NSMaxRange($0) <= text.length }
        rows = ranges.map { r in
            let anchor = anchors.last { $0.utf16 <= r.location }
            return HitRow(range: r, page: anchor?.info.kind == "page" ? anchor?.info.page : nil, location: anchor?.info.location ?? "",
                          context: Self.context(text, r))
        }
        countLabel.stringValue = stale ? "命中暂不可用" : rows.isEmpty ? "没有可定位的命中" : data.totalHits > UInt64(rows.count) ? "前 \(Theme.count(rows.count)) 处（共 \(Theme.count(Int(data.totalHits))) 处）" : "共 \(rows.count) 处"
        let isPDF = (path as NSString).pathExtension.lowercased() == "pdf"
        pdfMarks = []
        pdfSelections = []
        current = -1
        if isPDF, let pdf = PDFDocument(url: URL(fileURLWithPath: path)) {
            pdfView.isHidden = false
            textPane.isHidden = true
            pdfView.document = pdf
            mapPDFHits(pdf, anchors: anchors, text: text)
            externalButton.isHidden = false
        } else {
            pdfView.document = nil
            pdfView.isHidden = true
            textPane.isHidden = false
            textPane.show(PreviewData(document: doc, highlights: stale ? [] : data.highlights, totalHits: data.totalHits), path: path,
                          location: shownHit.flatMap { $0.isMember ? $0.displayLocation : nil })
            externalButton.isHidden = true
        }
        table.reloadData()
        if !rows.isEmpty { select(min(startAt, rows.count - 1)) } else { updateExternalTitle() }
    }

    /// Stored PDF text is each page's `page.string` plus "\n", so a hit is a character range of
    /// one page's string: exact, no fuzzy search.
    private func mapPDFHits(_ pdf: PDFDocument, anchors: [(utf16: Int, info: AnchorInfo)], text: NSString) {
        for row in rows {
            guard let pageNo = row.page, let page = pdf.page(at: pageNo - 1),
                  let start = anchors.first(where: { $0.info.kind == "page" && $0.info.page == pageNo })?.utf16 else {
                pdfMarks.append([]); pdfSelections.append(nil); continue
            }
            let local = NSRange(location: row.range.location - start, length: row.range.length)
            guard local.location >= 0, NSMaxRange(local) <= (page.string as NSString?)?.length ?? 0, let sel = page.selection(for: local) else {
                pdfMarks.append([]); pdfSelections.append(nil); continue
            }
            var marks: [PDFAnnotation] = []
            for line in sel.selectionsByLine() {
                let a = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                a.color = HitColors.hit.usingColorSpace(.sRGB) ?? .yellow
                page.addAnnotation(a)
                marks.append(a)
            }
            pdfMarks.append(marks)
            pdfSelections.append(sel)
        }
    }

    static func context(_ text: NSString, _ r: NSRange) -> String {
        let start = max(0, r.location - 16)
        let end = min(text.length, NSMaxRange(r) + 30)
        let s = text.substring(with: NSRange(location: start, length: end - start))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return (start > 0 ? "…" : "") + s + (end < text.length ? "…" : "")
    }

    // MARK: Navigation

    private func select(_ i: Int) {
        guard !rows.isEmpty else { return }
        let i = (i % rows.count + rows.count) % rows.count
        if table.selectedRow != i {
            table.selectRowIndexes([i], byExtendingSelection: false)
            return  // selection change calls back into go(to:)
        }
        go(to: i)
    }

    private func go(to i: Int) {
        if current >= 0 && current < pdfMarks.count {
            pdfMarks[current].forEach { $0.color = HitColors.hit.usingColorSpace(.sRGB) ?? .yellow }
        }
        current = i
        table.scrollRowToVisible(i)
        if !pdfView.isHidden {
            pdfMarks[i].forEach { $0.color = HitColors.current.withAlphaComponent(0.55) }
            if let sel = pdfSelections[i] {
                pdfView.go(to: sel)
            } else if let p = rows[i].page, let page = pdfView.document?.page(at: p - 1) {
                pdfView.go(to: page)
            }
        } else {
            textPane.go(to: i)
        }
        updateExternalTitle()
    }

    private var currentPage: Int {
        if current >= 0, current < rows.count, let p = rows[current].page { return p }
        if let page = pdfView.currentPage, let doc = pdfView.document { return doc.index(for: page) + 1 }
        return 1
    }

    private func updateExternalTitle() { externalButton.title = "在外部打开到第 \(currentPage) 页" }

    @objc func goNext() { select(current + 1) }
    @objc func goPrev() { select(current - 1) }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "g" && flags.contains(.command) {
            flags.contains(.shift) ? goPrev() : goNext()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Actions

    private var shownHit: ContentHit?

    @objc private func openDefault() {
        if let hit = shownHit, hit.isMember {
            if let message = MemberOpener.open(hit), let window {
                let alert = NSAlert()
                alert.messageText = message
                alert.beginSheetModal(for: window)
            }
            return
        }
        onOpenFile?(path, nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    @objc private func openExternally() {
        if let message = ExternalPDF.open(path: path, page: currentPage) {
            let alert = NSAlert()
            alert.messageText = message.title
            alert.informativeText = message.detail
            alert.addButton(withTitle: "好")
            if message.offerSettings { alert.addButton(withTitle: "打开辅助功能设置") }
            if let window {
                alert.beginSheetModal(for: window) { resp in
                    if resp == .alertSecondButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("readerHit"), owner: nil) as? ReaderHitCell ?? ReaderHitCell()
        cell.identifier = .init("readerHit")
        let r = rows[row]
        cell.title.stringValue = "第 \(row + 1) 处" + (r.location.isEmpty ? "" : " · " + r.location)
        cell.context.stringValue = r.context
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let i = table.selectedRow
        if i >= 0 && i < rows.count && i != current { go(to: i) }
    }
}

final class ReaderHitCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let context = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        context.font = .systemFont(ofSize: 12.5)
        context.lineBreakMode = .byTruncatingTail
        context.maximumNumberOfLines = 2
        context.cell?.wraps = true
        let stack = NSStackView(views: [title, context])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// "在外部打开到第 N 页" (UI-SPEC §6.3): Skim jumps directly; Preview needs Accessibility to
/// type its "Go to Page" shortcut, otherwise it opens at page 1 and the user is told why.
@MainActor
enum ExternalPDF {
    struct Message { var title: String; var detail: String; var offerSettings: Bool }

    static let skimID = "net.sourceforge.skim-app.skim"

    /// nil when the jump was handed off; otherwise what to tell the user.
    static func open(path: String, page: Int) -> Message? {
        let url = URL(fileURLWithPath: path)
        let quoted = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        if let skim = NSWorkspace.shared.urlForApplication(withBundleIdentifier: skimID) {
            let script = """
                tell application id "\(skimID)"
                    activate
                    open POSIX file "\(quoted)"
                    tell front document to go to page \(page)
                end tell
                """
            if run(script) { return nil }
            NSWorkspace.shared.open([url], withApplicationAt: skim, configuration: NSWorkspace.OpenConfiguration())
            return Message(title: "已用 Skim 打开，但没能跳到第 \(page) 页", detail: "请在 系统设置 → 隐私与安全性 → 自动化 中允许 XSearch 控制 Skim。", offerSettings: false)
        }
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return nil
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        guard page > 1 else { return nil }
        guard AXIsProcessTrusted() else {
            return Message(title: "已在“预览”中打开第 1 页", detail: "跳到第 \(page) 页需要辅助功能权限：在 系统设置 → 隐私与安全性 → 辅助功能 中允许 XSearch。安装 Skim 后不需要这项权限。", offerSettings: true)
        }
        let script = """
            delay 0.8
            tell application "System Events" to tell process "Preview"
                set frontmost to true
                keystroke "g" using {option down, command down}
                delay 0.3
                keystroke "\(page)"
                keystroke return
            end tell
            """
        DispatchQueue.main.async { _ = run(script) }
        return nil
    }

    @discardableResult
    static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }
}

import AppKit
import ContentEngine
import XSearchCore

/// Hit colors (UI-SPEC §2.1, §2.3): fixed, not following the accent color.
@MainActor
enum HitColors {
    static var hit: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 0.35) : Theme.hex(0xFFE08A) }
    }
    static let current = Theme.hex(0xFF9F0A)
    static let mark = Theme.hex(0xE8B84A)
}

/// Anchor decoded from the index JSON (`xs_index::Anchor`).
struct AnchorInfo: Decodable {
    var start: Int
    var kind: String
    var page: Int?
    var index: Int?
    var table: Int?
    var cell: String?
    var name: String?
    var sheet: String?
    var slide: Int?
    var line: Int?

    /// Gutter label: p.14 / 段 13 / 表 2·B3 / 页眉.
    var gutter: String {
        switch kind {
        case "page": "p.\(page ?? 0)"
        case "paragraph": L("段 %@", "\(index ?? 0)")
        case "cell": L("表 %@·%@", "\(table ?? 0)", cell ?? "")
        case "part": Loc.display(name ?? "")
        case "line": L("行 %@", "\(line ?? index ?? 0)")
        case "sheet": "\(sheet ?? "")!\(cell ?? "")"
        case "slide": L("幻灯片 %@", "\(slide ?? 0)")
        case "member": ((name ?? "") as NSString).lastPathComponent
        default: ""
        }
    }

    /// Header location: "PDF 第 14 页" / "段 13" / "表 2·B3".
    var location: String {
        switch kind {
        case "page": L("第 %@ 页", "\(page ?? 0)")
        default: gutter
        }
    }
}

// MARK: - Result row

final class ContentHitCell: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    let snippet = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        for v in [icon, name, count, snippet, meta, badge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        count.font = .systemFont(ofSize: 11.5)
        count.textColor = .secondaryLabelColor
        snippet.font = .systemFont(ofSize: 12.5)
        snippet.lineBreakMode = .byTruncatingTail
        // One line: a wrapped snippet pushed the path line and badge out of the 74 pt row.
        snippet.maximumNumberOfLines = 1
        snippet.usesSingleLineMode = true
        snippet.cell?.wraps = false
        meta.font = .systemFont(ofSize: 11.5)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingMiddle
        badge.font = .systemFont(ofSize: 10.5, weight: .medium)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        icon.imageScaling = .scaleProportionallyUpOrDown
        for v in [name, snippet, meta] { v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            count.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            snippet.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            snippet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            snippet.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            meta.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            meta.topAnchor.constraint(equalTo: snippet.bottomAnchor, constant: 3),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            badge.centerYAnchor.constraint(equalTo: meta.centerYAnchor),
            meta.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ h: ContentHit, live: Bool = false) {
        icon.image = h.icon
        name.stringValue = h.displayName
        count.stringValue = L("%@ 处", "\(h.hitCount)")
        let s = NSMutableAttributedString(string: h.snippet, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor])
        for r in h.snippetHighlights where Int(r.end) <= (h.snippet as NSString).length {
            s.addAttributes([.backgroundColor: HitColors.hit, .foregroundColor: NSColor.labelColor], range: NSRange(location: Int(r.start), length: Int(r.end - r.start)))
        }
        snippet.attributedStringValue = s
        meta.stringValue = h.displayLocation + " · " + Theme.shortDate(h.mtime)
        // UI-SPEC §4.5 status badges.
        let stateBadge: (String, NSColor, NSColor) = switch h.state {
        case .waitingOcr: (L("等待 OCR"), Theme.warnBackground, Theme.warnText)
        case .partial: (L("部分索引"), Theme.warnBackground, Theme.warnText)
        case .failed: (L("提取失败"), Theme.warnBackground, Theme.warnText)
        case .complete: ("", .clear, .clear)
        }
        // Live-scan hits are read from the file, not the index.
        let (text, bg, fg) = live ? (L("实时"), Theme.hex(0xE6F0FF), Theme.hex(0x1F4FA8)) : stateBadge
        badge.stringValue = text.isEmpty ? "" : " \(text) "
        badge.isHidden = text.isEmpty
        badge.textColor = fg
        badge.layer?.backgroundColor = bg.cgColor
        setAccessibilityLabel(L("%@，%@ 处，%@", "\(h.displayName)", "\(h.hitCount)", "\(h.snippet)"))
    }
}

// MARK: - Preview

/// Left gutter with anchor labels (p.14 / 段 13 / 表 2·B3), right-aligned, 11 pt (UI-SPEC §4.4).
final class AnchorRuler: NSRulerView {
    var anchors: [(utf16: Int, label: String)] = []

    // Transparent on glass: draw only the labels, no ruler background or baseline.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }
    override var isOpaque: Bool { false }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer, !anchors.isEmpty else { return }
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // First anchor at or after the visible start (binary search).
        var lo = 0, hi = anchors.count
        while lo < hi { let m = (lo + hi) / 2; if anchors[m].utf16 < chars.location { lo = m + 1 } else { hi = m } }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
        var lastY = -CGFloat.infinity
        for a in anchors[lo...] where a.utf16 <= NSMaxRange(chars) {
            let g = lm.glyphIndexForCharacter(at: min(a.utf16, max(0, (tv.string as NSString).length - 1)))
            var line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            line.origin.y += tv.textContainerOrigin.y
            let y = convert(NSPoint(x: 0, y: line.minY), from: tv).y
            if y - lastY < 14 { continue }  // don't overlap labels of short paragraphs
            lastY = y
            let size = a.label.size(withAttributes: attrs)
            a.label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + 6), withAttributes: attrs)
        }
    }
}

/// 6 pt strip on the right edge: one 3 pt mark per hit, the current one in hit.current (§4.4).
final class HitMarks: NSView {
    var fractions: [CGFloat] = [] { didSet { needsDisplay = true } }
    var current = -1 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for (i, f) in fractions.enumerated() {
            (i == current ? HitColors.current : HitColors.mark).setFill()
            NSRect(x: 0, y: min(bounds.height - 3, f * bounds.height), width: bounds.width, height: 3).fill()
        }
    }
}

@MainActor
final class PreviewPane: NSView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let position = NSTextField(labelWithString: "")
    let prev = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: L("上一处"))!, target: nil, action: nil)
    let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("下一处"))!, target: nil, action: nil)
    let locate = NSButton(title: L("阅读窗口 ⌘↵"), target: nil, action: nil)
    let banner = NSTextField(labelWithString: "")
    let placeholder = NSTextField(labelWithString: L("选中左侧结果后在这里预览"))
    let textView = NSTextView()
    let scroll = NSScrollView()
    let marks = HitMarks()
    private let ruler: AnchorRuler
    private(set) var hits: [NSRange] = []
    private var anchors: [(utf16: Int, info: AnchorInfo)] = []
    private(set) var currentHit = -1
    private var stale = false
    var onLocate: (() -> Void)?

    override init(frame: NSRect) {
        ruler = AnchorRuler(scrollView: scroll, orientation: .verticalRuler)
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        position.font = .systemFont(ofSize: 12)
        position.textColor = .secondaryLabelColor
        for b in [prev, next] {
            b.bezelStyle = .accessoryBarAction
            b.target = self
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        prev.action = #selector(goPrev)
        next.action = #selector(goNext)
        locate.bezelStyle = .push
        locate.keyEquivalent = ""
        locate.target = self
        locate.action = #selector(doLocate)
        locate.bezelColor = .controlAccentColor
        banner.font = .systemFont(ofSize: 12)
        banner.textColor = Theme.warnText
        banner.drawsBackground = true
        banner.backgroundColor = Theme.warnBackground
        banner.isHidden = true
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 12)
        for v in [textView, scroll.contentView] as [NSView] {
            v.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(textViewFrameChanged), name: NSView.frameDidChangeNotification, object: v)
        }
        textView.isVerticallyResizable = true
        // Large documents (millions of characters) must not be laid out in full on the main
        // thread: only what is shown or asked for gets laid out.
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        ruler.ruleThickness = 58
        ruler.clientView = textView
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        let controls = NSStackView(views: [position, prev, next, locate])
        controls.spacing = 6
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let head = NSStackView(views: [titles, NSView(), controls])
        head.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 10, right: 14)
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The buttons keep their full titles (English ones are longer); the file name gives way.
        for v in [position, locate] as [NSView] { v.setContentCompressionResistancePriority(.required, for: .horizontal) }
        for v in [head, banner, scroll, marks, placeholder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: topAnchor),
            head.leadingAnchor.constraint(equalTo: leadingAnchor),
            head.trailingAnchor.constraint(equalTo: trailingAnchor),
            banner.topAnchor.constraint(equalTo: head.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: marks.leadingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            marks.topAnchor.constraint(equalTo: scroll.topAnchor),
            marks.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            marks.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            marks.widthAnchor.constraint(equalToConstant: 6),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        clear()
    }

    required init?(coder: NSCoder) { fatalError() }

    func clear() {
        title.stringValue = ""
        subtitle.stringValue = ""
        position.stringValue = ""
        textView.string = ""
        fullText = ""
        shownRange = NSRange(location: NSNotFound, length: 0)
        hits = []
        anchors = []
        marks.fractions = []
        ruler.anchors = []
        banner.isHidden = true
        placeholder.isHidden = false
        for v in [prev, next, locate] { v.isHidden = true }
    }

    /// Shows a stored document. When the file changed after indexing, no highlights are drawn
    /// (offsets would point at the wrong text) and a notice explains it (UI-SPEC §6.3, §7).
    /// `location` replaces the folder line (an archive member's "包.zip › 目录").
    func show(_ data: PreviewData, path: String, location: String? = nil) {
        let doc = data.document
        currentPath = path
        locationOverride = location
        placeholder.isHidden = true
        for v in [prev, next, locate] { v.isHidden = false }
        title.stringValue = doc.name
        stale = Self.isStale(doc, path: path)
        banner.stringValue = stale ? L("  文件在建立索引后已修改，高亮暂不显示；已排队重新索引。  ") : ""
        banner.isHidden = !stale

        // Anchors are scalar offsets; convert to UTF-16 once.
        fullText = doc.text as NSString
        let length = fullText.length
        totalHits = data.totalHits
        hits = stale ? [] : data.highlights.map { NSRange(location: Int($0.start), length: Int($0.end - $0.start)) }.filter { NSMaxRange($0) <= length }
        let decoded = (try? JSONDecoder().decode([AnchorInfo].self, from: Data(doc.anchorsJson.utf8))) ?? []
        anchors = Self.utf16(decoded, in: doc.text)
        marks.fractions = hits.map { CGFloat($0.location) / CGFloat(max(1, length)) }
        currentHit = -1
        shownRange = NSRange(location: NSNotFound, length: 0)
        if hits.isEmpty {
            render(for: NSRange(location: 0, length: 0))
            position.stringValue = stale ? "" : L("没有可定位的命中")
            subtitle.stringValue = locationOverride ?? PathUtil.abbreviate((path as NSString).deletingLastPathComponent, home: NSHomeDirectory())
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        } else {
            go(to: 0)
        }
        prev.isEnabled = hits.count > 1
        next.isEnabled = hits.count > 1
    }

    /// All hits in the document; `hits` holds the first ones when there are very many.
    private var totalHits: UInt64 = 0
    /// The whole stored text; the text view shows `shownRange` of it.
    private var fullText: NSString = ""
    private var shownRange = NSRange(location: NSNotFound, length: 0)
    /// Shows the part of the text for `hit` (all of it for ordinary documents), hits colored
    /// before the text reaches the layout system (coloring afterwards forces glyph generation
    /// up to each hit).
    private func render(for hit: NSRange) {
        let range = PreviewWindow.range(for: hit, in: fullText)
        shownRange = range
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.8
        let text = NSMutableAttributedString(string: fullText.substring(with: range),
                                             attributes: [.font: NSFont.systemFont(ofSize: 14.5), .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
        for r in hits {
            if let part = PreviewWindow.visible(r, in: range) { text.addAttribute(.backgroundColor, value: HitColors.hit, range: part) }
        }
        textView.textStorage?.setAttributedString(text)
        ruler.anchors = anchors.filter { NSLocationInRange($0.utf16, range) }.map { ($0.utf16 - range.location, $0.info.gutter) }
        ruler.needsDisplay = true
        let windowed = range.length < fullText.length
        banner.stringValue = stale ? L("  文件在建立索引后已修改，高亮暂不显示；已排队重新索引。  ")
            : windowed ? L("  文档较大，只显示当前命中附近约 20 万字；切换命中时会跟着移动。  ") : ""
        banner.isHidden = !stale && !windowed
    }

    func go(to i: Int) {
        guard !hits.isEmpty, let storage = textView.textStorage else { return }
        let previous = currentHit
        currentHit = (i % hits.count + hits.count) % hits.count
        let target = hits[currentHit]
        if PreviewWindow.needsMove(target, window: shownRange) {
            render(for: target)
        } else if previous >= 0 && previous < hits.count, let old = PreviewWindow.visible(hits[previous], in: shownRange) {
            // Only the previous and the new current hit change.
            storage.addAttributes([.backgroundColor: HitColors.hit, .foregroundColor: NSColor.labelColor], range: old)
        }
        guard let r = PreviewWindow.visible(target, in: shownRange) else { return }
        storage.addAttributes([.backgroundColor: HitColors.current, .foregroundColor: NSColor.black], range: r)
        centerCurrentHit()
        marks.current = currentHit
        // A hit longer than the window is shown from its start.
        position.stringValue = L("第 %@/%@ 处", "\(currentHit + 1)", "\(hits.count)") + (totalHits > UInt64(hits.count) ? L("（共 %@ 处）", "\(Theme.count(Int(totalHits)))") : "") + (r.length < target.length ? L("（命中过长，只显示开头）") : "")
        let loc = anchors.last { $0.utf16 <= target.location }?.info.location
        subtitle.stringValue = [locationOverride ?? PathUtil.abbreviate(subtitlePath, home: NSHomeDirectory()), loc].compactMap { $0 }.joined(separator: " · ")
        ruler.needsDisplay = true
    }

    /// Text width and visible height the current hit was last centered for.
    private var centeredFor = NSSize.zero
    private var viewSize: NSSize { NSSize(width: textView.frame.width, height: scroll.contentView.bounds.height) }

    /// Centers the current hit; non-contiguous layout lays out only around it.
    private func centerCurrentHit() {
        guard currentHit >= 0, currentHit < hits.count, let r = PreviewWindow.visible(hits[currentHit], in: shownRange),
              let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        centeredFor = viewSize
        lm.ensureLayout(forCharacterRange: r)
        let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
        let y = max(0, rect.midY - scroll.contentView.bounds.height / 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// A preview can arrive while the launcher is still expanding: the text then rewraps and
    /// the hit moves, so it is centered again for the final size.
    /// Dev log: is the current hit inside the visible part of the text?
    var currentHitVisible: Bool {
        guard currentHit >= 0, currentHit < hits.count, let r = PreviewWindow.visible(hits[currentHit], in: shownRange),
              let lm = textView.layoutManager, let tc = textView.textContainer else { return false }
        let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
        return scroll.contentView.bounds.intersects(rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
    }

    @objc private func textViewFrameChanged() {
        let size = viewSize
        if currentHit >= 0, abs(size.width - centeredFor.width) > 0.5 || abs(size.height - centeredFor.height) > 0.5 { centerCurrentHit() }
    }

    private var currentPath = ""
    private var subtitlePath: String { (currentPath as NSString).deletingLastPathComponent }
    private var locationOverride: String?

    /// 1-based line of the current hit in the stored text (editor "open at line").
    var currentLine: Int? {
        guard currentHit >= 0, currentHit < hits.count else { return nil }
        let prefix = fullText.substring(to: hits[currentHit].location)
        return prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// Page of the current hit (PDF "open at page").
    var currentPage: Int? {
        guard currentHit >= 0, currentHit < hits.count else { return nil }
        return anchors.last { $0.utf16 <= hits[currentHit].location && $0.info.kind == "page" }?.info.page
    }

    @objc func goNext() { go(to: currentHit + 1) }
    @objc func goPrev() { go(to: currentHit - 1) }
    @objc private func doLocate() { onLocate?() }

    static func isStale(_ doc: ContentDocument, path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return true }
        let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return UInt64(bitPattern: mtime) != doc.revision
    }

    static func utf16(_ anchors: [AnchorInfo], in text: String) -> [(utf16: Int, info: AnchorInfo)] {
        guard !anchors.isEmpty else { return [] }
        let sorted = anchors.sorted { $0.start < $1.start }
        var out: [(Int, AnchorInfo)] = []
        var k = 0, scalar = 0, u = 0
        for s in text.unicodeScalars {
            while k < sorted.count && sorted[k].start <= scalar { out.append((u, sorted[k])); k += 1 }
            scalar += 1
            u += s.utf16.count
        }
        while k < sorted.count { out.append((u, sorted[k])); k += 1 }
        return out
    }
}

// MARK: - Pane

/// Content mode body: result list (420) | preview (UI-SPEC §3, §4.3–4.4).
@MainActor
final class ContentPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = ResultTable()
    let listScroll = NSScrollView()
    let preview = PreviewPane()
    private(set) var hits: [ContentHit] = []
    private let searcher: ContentSearcher
    private var expression = ""
    private var previewToken = 0
    var onOpen: ((ContentHit, Bool) -> Void)?
    /// Open in the reader window at this occurrence.
    var onRead: ((ContentHit, Int) -> Void)?
    var expressionForReader: String { expression }

    init(searcher: ContentSearcher) {
        self.searcher = searcher
        super.init(frame: .zero)
        table.addTableColumn(NSTableColumn(identifier: .init("hit")))
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onReturn = { [weak self] flags in self?.openSelected(reveal: flags.contains(.command)) }
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        table.setAccessibilityLabel(L("内容搜索结果"))
        listScroll.documentView = table
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .overlay
        let divider = RuleView()
        preview.onLocate = { [weak self] in
            guard let self, let h = self.selected else { return }
            self.onRead?(h, max(0, self.preview.currentHit))
        }
        for v in [listScroll, divider, preview] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            listScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            listScroll.topAnchor.constraint(equalTo: topAnchor),
            listScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: 420),
            divider.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            divider.widthAnchor.constraint(equalToConstant: 1),
            preview.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var selected: ContentHit? {
        let r = table.selectedRow
        return r >= 0 && r < hits.count ? hits[r] : nil
    }

    /// Hits found by the live scan (preview reads the file, not the index).
    private(set) var liveIds = Set<UInt64>()

    func clearResults() {
        hits = []
        liveIds = []
        table.reloadData()
        invalidatePreview()
        preview.clear()
    }

    /// A preview still queued must not fill the pane any more.
    func invalidatePreview() { previewToken += 1 }

    func show(_ out: ContentOutput) {
        expression = out.query.expression
        if !out.append { liveIds = [] }
        if out.append {
            let start = hits.count
            // A live hit for a file the index already returned is dropped.
            let known = Set(hits.map(\.fileId))
            let new = out.live ? out.hits.filter { !known.contains($0.fileId) } : out.hits
            if out.live { liveIds.formUnion(new.map(\.fileId)) }
            hits += new
            table.insertRows(at: IndexSet(start..<hits.count), withAnimation: [])
            // First results of a live scan after an empty list: select and preview them.
            if start == 0 && !hits.isEmpty && table.selectedRow < 0 {
                table.selectRowIndexes([0], byExtendingSelection: false)
                table.scrollRowToVisible(0)
            }
        } else {
            hits = out.hits
            table.reloadData()
            if hits.isEmpty { invalidatePreview(); preview.clear() } else {
                table.selectRowIndexes([0], byExtendingSelection: false)
                table.scrollRowToVisible(0)
            }
        }
    }

    /// Drops a trashed file from the list and selects its neighbour.
    func remove(path: String) {
        guard let i = hits.firstIndex(where: { $0.path == path && !$0.isMember }) else { return }
        hits.remove(at: i)
        table.reloadData()
        if hits.isEmpty { invalidatePreview(); preview.clear() } else { table.selectRowIndexes([min(i, hits.count - 1)], byExtendingSelection: false) }
    }

    func moveSelection(_ delta: Int) {
        guard !hits.isEmpty else { return }
        let r = max(0, min(hits.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        previewToken += 1
        guard let h = selected else { preview.clear(); return }
        let token = previewToken
        let path = h.dir + "/" + h.name
        let show: @MainActor @Sendable (PreviewData?) -> Void = { [weak self] data in
            guard let self, token == self.previewToken else { return }
            if let data { self.preview.show(data, path: path, location: h.isMember ? h.displayLocation : nil) } else { self.preview.clear() }
        }
        // Debounced: while the user types, each keystroke replaces the results; loading (and
        // laying out) a large document for every intermediate result would block typing.
        let live = liveIds.contains(h.fileId), expression = self.expression
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, token == self.previewToken else { return }
            if live {
                self.searcher.livePreview(path: path, expression: expression, deliver: show)
            } else {
                self.searcher.preview(fileId: h.fileId, expression: expression, member: h.member, memberStart: h.memberStart, deliver: show)
            }
        }
    }

    private func openSelected(reveal: Bool) {
        if let h = selected { onOpen?(h, reveal) }
    }

    @objc private func doubleClicked() {
        if table.clickedRow >= 0 { openSelected(reveal: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 74 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let v = tableView.makeView(withIdentifier: .init("hit"), owner: nil) as? ContentHitCell ?? ContentHitCell()
        v.identifier = .init("hit")
        v.configure(hits[row], live: liveIds.contains(hits[row].fileId))
        return v
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        URL(fileURLWithPath: hits[row].dir + "/" + hits[row].name) as NSURL
    }
}

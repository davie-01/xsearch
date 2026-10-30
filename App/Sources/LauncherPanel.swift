import AppKit
import Catalog
import ContentEngine
import Quartz
import XSearchCore

/// Non-activating panel: it takes keyboard focus without activating XSearch, so closing it
/// leaves the previously active app in front (§13).
final class LauncherPanel: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // Glass draws its own edge and depth; a window shadow would trace stale shapes as the
        // bar and buttons change size inside this fixed transparent window.
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

/// Text field that reports IME composition so searches and key handling can wait (§5.3).
final class LauncherField: NSTextField {
    var isComposing: Bool { (currentEditor() as? NSTextView)?.hasMarkedText() ?? false }
}

final class ResultTable: NSTableView {
    var onSpace: (() -> Void)?
    var onReturn: ((NSEvent.ModifierFlags) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onSpace?()                                      // space: Quick Look (list focused only)
        case 36, 76: onReturn?(event.modifierFlags)              // return / enter
        default: super.keyDown(with: event)
        }
    }

    // Quick Look panel control lives on the focused table.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = delegate as? QLPreviewPanelDataSource }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }
}

@MainActor
final class LauncherController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource {
    let panel = LauncherPanel()
    private let session: SearchSession
    private let usage: UsageStore?
    var openSettings: (() -> Void)?
    var openDiagnostics: (() -> Void)?

    private let field = LauncherField()
    // Spotlight shell: one glass bar, plus round glass mode buttons that split out of it.
    private let container = NSGlassEffectContainerView()
    private let mainGlass = NSGlassEffectView()
    private let header = FlippedView()
    private let body = FlippedView()
    private var modeButtons: [GlassCircleButton] = []
    private var buttonsShown = false
    private var mouseMonitors: [Any] = []
    private var mouseTravel: CGFloat = 0
    private var lastMouse: NSPoint?
    private var driver: FrameDriver?
    /// What is on screen (may lag `buttonsShown` while animating).
    private var buttonsVisible = false
    private let contentChip = NSButton(title: "内容  ×", target: nil, action: nil)
    private let chips = NSStackView()
    private let table = ResultTable()
    private let scroll = NSScrollView()
    private let notice = NSStackView()
    private let hints = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var listHeight: NSLayoutConstraint!
    private let rootStack = NSStackView()
    private var bodyHeight: CGFloat = 0
    private var contentPane: ContentPane!
    private var contentHeight: NSLayoutConstraint!
    private var contentOutput: ContentOutput?
    private var contentShown = 0
    private var chipsHeight: NSLayoutConstraint!

    private enum Row { case group(String), item(ResultItem) }
    private var rows: [Row] = []
    private var output: SearchOutput?
    private var mode: Preferences.Mode = .name
    private var toastUntil = Date.distantPast

    init(session: SearchSession, usage: UsageStore?) {
        self.session = session
        self.usage = usage
        super.init()
        build()
        panel.onKeyEquivalent = { [weak self] in self?.keyEquivalent($0) ?? false }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Clicking elsewhere dismisses the launcher; Quick Look and drags keep it.
            MainActor.assumeIsolated {
                guard let self, !(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible) else { return }
                self.hide()
            }
        }
    }

    // MARK: Layout

    private func build() {
        // Fixed transparent window; only the glass frames move inside it (no window jumps).
        // Transparent margin on every side: springs overshoot (bigger drops, wider bounce) and
        // must never be clipped by the window edge.
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: Shell.contentWidth + 2 * Shell.inset, height: Shell.maxHeight + 2 * Shell.inset))
        container.spacing = Shell.mergeDistance
        container.contentView = root
        panel.contentView = container
        panel.setContentSize(root.frame.size)

        mainGlass.style = .regular
        let mainContent = FlippedView()
        mainGlass.contentView = mainContent
        root.addSubview(mainGlass)
        mainContent.addSubview(header)
        mainContent.addSubview(body)

        let modes: [(String, String, String)] = [
            ("doc.on.doc", "名称", "按文件名搜索（⌘1）"),
            ("text.magnifyingglass", "内容", "在文件内容中搜索（⌘2）"),
        ]
        for (i, m) in modes.enumerated() {
            let b = GlassCircleButton(symbol: m.0, label: m.1, tip: m.2)
            b.onPress = { [weak self] in self?.switchMode(Preferences.Mode(rawValue: i) ?? .name) }
            b.isHidden = true
            root.addSubview(b)
            modeButtons.append(b)
        }

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索")!)
        icon.symbolConfiguration = .init(pointSize: 22, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.inputFont
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("搜索")

        contentChip.bezelStyle = .inline
        contentChip.isBordered = false
        contentChip.wantsLayer = true
        contentChip.layer?.cornerRadius = 9
        contentChip.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        contentChip.contentTintColor = .controlAccentColor
        contentChip.font = .systemFont(ofSize: 14, weight: .medium)
        contentChip.title = "  内容  ×  "
        contentChip.target = self
        contentChip.action = #selector(removeContentPrefix)
        contentChip.setAccessibilityLabel("移除内容前缀")
        contentChip.isHidden = true

        let headerRow = NSStackView(views: [icon, contentChip, field])
        headerRow.orientation = .horizontal
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRow)
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            headerRow.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Thin rule under the input, inset from both edges (Spotlight).
        let rule = RuleView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let ruleRow = NSStackView(views: [rule])
        ruleRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)

        chips.orientation = .horizontal
        chips.spacing = 8
        chips.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 4, right: 20)
        chips.alignment = .centerY

        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onSpace = { [weak self] in self?.toggleQuickLook() }
        table.onReturn = { [weak self] flags in self?.activate(flags.contains(.command) ? .reveal : .open) }
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        table.setAccessibilityLabel("搜索结果")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        notice.orientation = .vertical
        notice.alignment = .leading
        notice.spacing = 6
        notice.edgeInsets = NSEdgeInsets(top: 10, left: 22, bottom: 14, right: 22)
        notice.isHidden = true

        hints.font = Theme.hintFont
        hints.textColor = .tertiaryLabelColor
        status.font = Theme.hintFont
        status.textColor = .tertiaryLabelColor
        status.alignment = .right
        status.lineBreakMode = .byTruncatingHead
        let footer = NSStackView(views: [hints, NSView(), status])
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 22, bottom: 10, right: 22)
        hints.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentPane = ContentPane(searcher: session.content)
        contentPane.onOpen = { [weak self] hit, reveal in self?.openContent(hit, reveal: reveal) }
        contentPane.isHidden = true
        let stack = rootStack
        for v in [ruleRow, chips, scroll, contentPane!, notice, footer] { stack.addArrangedSubview(v) }
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stack)
        for v in [ruleRow, chips, scroll, contentPane!, notice, footer] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        contentHeight = contentPane.heightAnchor.constraint(equalToConstant: 0)
        contentHeight.isActive = true
        chipsHeight = chips.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            stack.topAnchor.constraint(equalTo: body.topAnchor),
            listHeight, chipsHeight,
        ])
        updateHints()
        layoutShell(animated: false)
    }

    // MARK: Spotlight shell

    private var shellWidth: CGFloat { mode == .content ? Shell.contentWidth : Shell.width }
    /// Left edge of the shell on the stage: the shell stays centred when it widens.
    private var originX: CGFloat { (Shell.contentWidth - shellWidth) / 2 }

    private var mainWidth: CGFloat {
        buttonsShown ? shellWidth - Shell.barGap - CGFloat(modeButtons.count) * Shell.button - CGFloat(modeButtons.count - 1) * Shell.gap : shellWidth
    }

    /// Places the bar, the result body and the mode buttons, matching Spotlight's choreography
    /// (measured frame by frame from a screen recording):
    /// - reveal: the bar narrows at once with a visible bounce; ~50 ms later each button buds out
    ///   of the bar's current right end at 30% size, staggered 25 ms, growing while it springs to
    ///   place; icons fade in only after the drops have separated;
    /// - hide: buttons shrink back into the bar's end, then the bar widens;
    /// - results collapse: content fades out first, a short pause, then the height springs down;
    ///   expand: height grows at once, content fades in.
    /// Every part has its own spring; one display-link driver steps them all on real geometry.
    private func layoutShell(animated: Bool) {
        let targetW = mainWidth
        let targetH = Shell.bar + bodyHeight
        let targetMain = NSRect(x: originX, y: 0, width: targetW, height: targetH)
        let shownFrames = modeButtons.indices.map { i in
            NSRect(x: originX + targetW + Shell.barGap + CGFloat(i) * (Shell.button + Shell.gap), y: 0, width: Shell.button, height: Shell.button)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        driver?.stop()
        guard animated && !reduceMotion && panel.isVisible else {
            mainGlass.cornerRadius = bodyHeight > 0 ? Shell.bodyRadius : Shell.bar / 2
            setMainFrame(targetMain)
            body.isHidden = bodyHeight == 0
            body.alphaValue = 1
            for (b, f) in zip(modeButtons, shownFrames) {
                place(b, buttonsShown ? f : tucked(barEnd: originX + targetW))
                b.iconAlpha = buttonsShown ? 1 : 0
                b.isHidden = !buttonsShown
            }
            buttonsVisible = buttonsShown
            return
        }

        let from = mainGlass.frame.offsetBy(dx: -Shell.inset, dy: -Shell.inset)
        let fromButtons = modeButtons.map { $0.frame.offsetBy(dx: -Shell.inset, dy: -Shell.inset) }
        let fromIcons = modeButtons.map(\.iconAlpha)
        let fromBodyAlpha = body.alphaValue
        let revealing = buttonsShown && !buttonsVisible
        let hiding = !buttonsShown && buttonsVisible
        let collapsing = targetH < from.height - 0.5
        let expanding = targetH > from.height + 0.5
        buttonsVisible = buttonsShown

        let widthCurve: SpringCurve = revealing ? .init(response: 0.36, damping: 0.5)
            : hiding ? .init(response: 0.34, damping: 0.8, delay: 0.04) : .init(response: 0.3, damping: 0.86)
        // Spotlight: content gone in ~25 ms, a ~0.1 s hold, then a quick height snap (~0.1 s).
        let heightCurve: SpringCurve = collapsing ? .init(response: 0.2, damping: 0.95, delay: 0.1) : .init(response: 0.28, damping: 0.82)
        let n = modeButtons.count
        let buttonCurves: [SpringCurve] = (0..<n).map { i in
            revealing ? .init(response: 0.34, damping: 0.38, delay: 0.02 + 0.018 * Double(i))
                : .init(response: 0.28, damping: 0.92, delay: 0.015 * Double(n - 1 - i))
        }
        // Position wobbles left–right (low damping, ~27% overshoot then ~8% back) while the size
        // settles more firmly, so the drops swing into place without ballooning.
        let sizeCurves: [SpringCurve] = buttonCurves.map { c in
            revealing ? .init(response: 0.3, damping: 0.62, delay: c.delay) : c
        }
        if revealing { modeButtons.forEach { $0.isHidden = false } }
        if expanding { body.isHidden = false }
        // Round ends while the body is (nearly) gone; rounded rectangle once it has height.
        let endRadius = targetH > Shell.bar + 0.5 ? Shell.bodyRadius : Shell.bar / 2

        var duration = max(widthCurve.settle, heightCurve.settle)
        for c in buttonCurves + sizeCurves { duration = max(duration, c.settle) }
        if collapsing { duration = max(duration, 0.2) }
        driver = FrameDriver(view: mainGlass, duration: duration) { [weak self] t in
            guard let self else { return }
            let w = from.width + (targetW - from.width) * CGFloat(widthCurve.value(t))
            let x = from.minX + (targetMain.minX - from.minX) * CGFloat(widthCurve.value(t))
            let h = from.height + (targetH - from.height) * CGFloat(heightCurve.value(t))
            self.mainGlass.cornerRadius = h > Shell.bar + 10 ? Shell.bodyRadius : min(Shell.bodyRadius + (Shell.bar / 2 - Shell.bodyRadius) * (1 - (h - Shell.bar) / 10), Shell.bar / 2)
            self.setMainFrame(NSRect(x: x, y: 0, width: w, height: max(Shell.bar, h)))
            // Body content: fade out quickly before collapsing, fade in while expanding.
            if collapsing {
                self.body.alphaValue = fromBodyAlpha * CGFloat(max(0, 1 - t / 0.04))
            } else if expanding || fromBodyAlpha < 1 {
                self.body.alphaValue = fromBodyAlpha + (1 - fromBodyAlpha) * CGFloat(min(1, max(0, (t - 0.04) / 0.12)))
            }
            for (i, b) in self.modeButtons.enumerated() {
                let c = buttonCurves[i]
                if revealing {
                    // Bud out of the bar's end as it is at the moment this button starts.
                    let v = CGFloat(widthCurve.value(c.delay))
                    let endAtStart = from.minX + (targetMain.minX - from.minX) * v + from.width + (targetW - from.width) * v
                    self.place(b, circleLerp(self.tucked(barEnd: endAtStart), shownFrames[i], c.value(t), size: sizeCurves[i].value(t)))
                    let fade = (t - 0.16 - 0.02 * Double(i)) / 0.1
                    b.iconAlpha = CGFloat(min(1, max(0, fade)))
                } else if hiding {
                    self.place(b, circleLerp(fromButtons[i], self.tucked(barEnd: x + w), c.value(t)))
                    b.iconAlpha = fromIcons[i] * CGFloat(max(0, 1 - t / 0.06))
                } else if self.buttonsShown {
                    self.place(b, circleLerp(fromButtons[i], shownFrames[i], widthCurve.value(t)))
                }
            }
        } completion: { [weak self] in
            guard let self else { return }
            self.mainGlass.cornerRadius = endRadius
            self.setMainFrame(targetMain)
            if self.bodyHeight == 0 { self.body.isHidden = true }
            self.body.alphaValue = 1
            if !self.buttonsShown { self.modeButtons.forEach { $0.isHidden = true } }
        }
        driver?.start()
    }

    private func place(_ b: GlassCircleButton, _ r: NSRect) {
        b.frame = r.offsetBy(dx: Shell.inset, dy: Shell.inset)
    }

    /// A button tucked into the bar's right end: a small drop, fully inside the bar.
    private func tucked(barEnd: CGFloat) -> NSRect {
        let size = Shell.button * 0.3
        return NSRect(x: barEnd - Shell.button * 0.35 - size / 2, y: (Shell.button - size) / 2, width: size, height: size)
    }

    /// The bar's inner header and body track the glass size exactly (no autoresizing drift).
    private func setMainFrame(_ frame: NSRect) {
        mainGlass.frame = frame.offsetBy(dx: Shell.inset, dy: Shell.inset)
        header.frame = NSRect(x: 0, y: 0, width: frame.width, height: Shell.bar)
        body.frame = NSRect(x: 0, y: Shell.bar, width: frame.width, height: max(0, frame.height - Shell.bar))
    }

    private func setButtonsShown(_ shown: Bool, animated: Bool) {
        guard shown != buttonsShown else { return }
        buttonsShown = shown
        layoutShell(animated: animated)
    }

    /// Moving the mouse (not typing) reveals the mode buttons, as in Spotlight.
    private func startMouseWatch() {
        stopMouseWatch()
        mouseTravel = 0
        lastMouse = NSEvent.mouseLocation
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { handler($0); return $0 }) { mouseMonitors.append(l) }
    }

    private func stopMouseWatch() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
    }

    private func mouseMoved() {
        guard panel.isVisible, !buttonsShown else { return }
        let now = NSEvent.mouseLocation
        if let last = lastMouse { mouseTravel += hypot(now.x - last.x, now.y - last.y) }
        lastMouse = now
        // Ignore sub-pixel jitter right after the panel appears.
        if mouseTravel > 6 { setButtonsShown(true, animated: true) }
    }

    // MARK: Show / hide

    var isVisible: Bool { panel.isVisible }

    func toggle() { panel.isVisible ? hide() : show() }

    func show(mode requested: Preferences.Mode? = nil, text: String? = nil) {
        if let text { field.stringValue = text }
        session.refreshApps()
        let prefs = Preferences.shared
        setMode(requested ?? (prefs.summonMode == .rememberLast ? prefs.lastMode : .name))
        // Every summon starts as the single search bar.
        buttonsShown = false
        driver?.stop()
        runSearch()
        resize(animated: false)
        position()
        panel.makeKeyAndOrderFront(nil)
        startMouseWatch()
        if let delay = ProcessInfo.processInfo.environment["XS_CLEAR_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.field.stringValue = ""
                    self?.runSearch()
                }
            }
        }
        if let delay = ProcessInfo.processInfo.environment["XS_REVEAL_BUTTONS"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.setButtonsShown(true, animated: true) }
            }
        }
        panel.makeFirstResponder(field)
        // Select the previous input so typing replaces it (§6.1).
        field.currentEditor()?.selectAll(nil)
    }

    func hide() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        stopMouseWatch()
        panel.orderOut(nil)
    }

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let top = frame.maxY - frame.height / 6
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - size.width / 2, y: top + Shell.inset))
    }

    /// Body height from its content; zero (a plain search bar) when there is nothing to show.
    private func resize(animated: Bool = true) {
        let content = rows.reduce(CGFloat(0)) { h, r in
            if case .group = r { return h + Theme.groupHeight }
            return h + Theme.rowHeight
        }
        let contentMode = mode == .content
        listHeight.constant = contentMode ? 0 : min(Theme.maxListHeight, content + (content > 0 ? 8 : 0))
        contentHeight.constant = contentMode && !contentPane.hits.isEmpty ? Shell.contentBody : 0
        contentPane.isHidden = contentHeight.constant == 0
        scroll.isHidden = contentMode
        chipsHeight.constant = chips.arrangedSubviews.isEmpty ? 0 : 40
        let hasResults = contentMode ? !contentPane.hits.isEmpty : !rows.isEmpty
        let empty = !hasResults && notice.isHidden && chips.arrangedSubviews.isEmpty
        body.frame.size.width = mainWidth
        body.layoutSubtreeIfNeeded()
        let next = empty ? 0 : min(Shell.maxHeight - Shell.bar, rootStack.fittingSize.height)
        guard next != bodyHeight || !animated else { return }
        bodyHeight = next
        layoutShell(animated: animated)
    }

    // MARK: Mode

    private func setMode(_ m: Preferences.Mode) {
        mode = m
        Preferences.shared.lastMode = m
        for (i, b) in modeButtons.enumerated() { b.isOn = i == m.rawValue }
        field.placeholderString = m == .name ? "搜索应用和文件" : "在文件内容中查找"
        updateHints()
    }

    /// Input and filters are kept; switching to name mode drops the `in ` prefix (§5.2).
    private func switchMode(_ m: Preferences.Mode) {
        let changed = m != mode
        setMode(m)
        runSearch()
        if changed { layoutShell(animated: panel.isVisible) }
    }

    @objc private func removeContentPrefix() { switchMode(.name) }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        // While the input method composes, results stay as they were (§5.3).
        guard !field.isComposing else { return }
        runSearch()
    }

    private func runSearch() {
        // Typing `in ` turns into the “内容” token: the prefix leaves the input (§4.1).
        if field.stringValue.hasPrefix("in ") {
            field.stringValue = String(field.stringValue.dropFirst(3))
            if mode != .content { setMode(.content) }
        }
        let text = field.stringValue
        contentChip.isHidden = mode != .content
        if mode == .content {
            session.content.search(text, home: NSHomeDirectory()) { [weak self] out in self?.applyContent(out) }
            return
        }
        session.content.cancel()
        session.search(text) { [weak self] out in self?.apply(out) }
    }

    /// The app list loads asynchronously; refresh visible results when it arrives.
    func appsDidLoad() {
        if panel.isVisible && mode == .name { runSearch() }
    }

    private func apply(_ out: SearchOutput) {
        output = out
        rows = []
        var lastGroup: ResultItem.Group?
        for item in out.items {
            if item.group != lastGroup { rows.append(.group(item.group.rawValue)); lastGroup = item.group }
            rows.append(.item(item))
        }
        setChips(out.query.chips)
        table.reloadData()
        // Start at the top so the first group header stays visible.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
        if let first = rows.firstIndex(where: { if case .item = $0 { return true }; return false }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
        }
        setNotice(for: out)
        updateStatus()
        resize()
    }

    private func setChips(_ list: [NameQuery.Chip]) {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for chip in list {
            chips.addArrangedSubview(CapsuleLabel(chip.valid ? chip.label : chip.label + "（无法识别）", warning: !chip.valid))
        }
    }

    private func clearNotice() {
        notice.arrangedSubviews.forEach { $0.removeFromSuperview() }
        notice.isHidden = true
    }

    private func addNotice(_ text: String, color: NSColor = .secondaryLabelColor, size: CGFloat = 13) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.preferredMaxLayoutWidth = Theme.panelWidth - 44
        notice.addArrangedSubview(label)
        notice.isHidden = false
    }

    private func addLink(_ title: String, action: Selector) {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .controlAccentColor
        b.font = .systemFont(ofSize: 12.5)
        notice.addArrangedSubview(b)
        notice.isHidden = false
    }

    /// Never a bare "no results": say why and what to do (UI-SPEC §1.4, §7).
    private func setNotice(for out: SearchOutput) {
        clearNotice()
        guard out.items.isEmpty else { return }
        if out.query.isEmpty { return }  // empty input: just the search bar
        let phase = session.names.status.phase
        if phase == .scanning || phase == .starting {
            addNotice("文件名索引仍在建立，已处理的部分可以搜索。", color: Theme.warnText, size: 12.5)
        }
        for dir in out.unresolvedDirs {
            addNotice("目录 \(PathUtil.abbreviate(dir, home: NSHomeDirectory())) 不在文件名索引中（不存在、被排除或不在范围内）。", size: 12.5)
        }
        let text = out.query.terms.joined(separator: " ")
        addNotice("文件名索引中没有匹配“\(text.isEmpty ? out.text : text)”的项目")
        addLink("查看可能的原因（范围、排除规则、权限）", action: #selector(showScopeSettings))
    }

    private func applyContent(_ out: ContentOutput) {
        contentOutput = out
        contentShown = out.append ? contentShown + out.hits.count : out.hits.count
        if !out.append {
            setChips(out.query.chips)
            setContentNotice(out)
        } else if out.done && contentShown == 0 {
            setContentNotice(out)
        }
        contentPane.show(out)
        updateStatus()
        resize()
    }

    /// Cost hints and "no results" reasons for content queries (UI-SPEC §7).
    private func setContentNotice(_ out: ContentOutput) {
        clearNotice()
        if out.query.isEmpty { return }
        if let error = out.error {
            addNotice(error, color: Theme.warnText, size: 12.5)
            return
        }
        switch out.recall {
        case .pair?: addNotice("两个字节的查询用前缀区间召回，结果完整。", color: Theme.warnText, size: 12.5)
        case .scan?: addNotice("单字符或只含排除条件的查询会扫描全部已索引正文；加上 dir: 或 ext: 可以更快。", color: Theme.warnText, size: 12.5)
        case .longTermsThenVerify?: addNotice("先用长词找候选，再核验短词。", color: .tertiaryLabelColor, size: 12.5)
        default: break
        }
        guard out.done && contentShown == 0 else { return }
        addNotice("已索引的内容中没有找到“\(out.query.expression)”。")
        let stats = session.contentStats?() ?? ContentStats()
        var parts = ["内容索引 \(Theme.count(stats.indexed)) 个文件"]
        if stats.pending > 0 { parts.append("\(stats.pending) 个文件等待处理") }
        if stats.failed > 0 { parts.append("\(stats.failed) 个文件提取失败") }
        addNotice(parts.joined(separator: " · "), color: .tertiaryLabelColor, size: 12.5)
        addLink("为什么可能搜不到？", action: #selector(showDiagnostics))
    }

    @objc private func showDiagnostics() {
        hide()
        openDiagnostics?()
    }

    private func openContent(_ hit: ContentHit, reveal: Bool) {
        let path = hit.dir + "/" + hit.name
        guard FileManager.default.fileExists(atPath: path) else {
            toast("文件已不存在，索引会自动更新")
            return
        }
        usage?.recordOpen(path: path, fileId: Int64(hit.fileId))
        hide()
        let url = URL(fileURLWithPath: path)
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
    }

    @objc private func showScopeSettings() {
        hide()
        openSettings?()
    }

    // MARK: Footer

    private func updateHints() {
        hints.attributedStringValue = Self.hintString(mode == .name
            ? [("↵", "打开"), ("⌘↵", "在访达中显示"), ("⇧⌘C", "复制路径")]
            : [("↵", "打开"), ("⌘↵", "定位到原文件"), ("⌘G", "下一处"), ("⇧⌘G", "上一处"), ("⌘1", "名称模式")])
    }

    static func hintString(_ pairs: [(String, String)]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (i, (k, v)) in pairs.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "   ")) }
            s.append(NSAttributedString(string: k, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]))
            s.append(NSAttributedString(string: " " + v, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return s
    }

    func updateStatus() {
        guard Date() >= toastUntil else { return }
        let st = session.names.status
        var parts: [String] = []
        switch st.phase {
        case .starting: parts.append("正在打开文件名索引")
        case .scanning: parts.append("正在建立文件名索引 · \(Theme.count(st.count)) 项")
        case .ready: parts.append("名称索引 \(Theme.count(st.count)) 项")
        case .failed: parts.append("文件名索引出错，详见设置")
        }
        if mode == .content {
            let stats = session.contentStats?() ?? ContentStats()
            parts = ["内容索引 \(Theme.count(stats.indexed)) 个文件"]
            if stats.pending > 0 { parts.append("待处理 \(Theme.count(stats.pending))") }
            if let out = contentOutput, !out.query.isEmpty, out.error == nil {
                parts.append(out.done ? "\(Theme.count(contentShown)) 个结果" : "仍在搜索… 已核验 \(Theme.count(Int(out.verified))) / \(Theme.count(Int(out.candidates)))")
            }
        } else if let out = output, !out.query.isEmpty {
            parts.append("\(Theme.count(out.total)) 个结果")
            parts.append(String(format: "%.1f ms", out.elapsedMs))
        }
        status.stringValue = parts.joined(separator: " · ")
    }

    private func toast(_ text: String) {
        status.stringValue = text
        toastUntil = Date().addingTimeInterval(1.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in self?.updateStatus() }
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Keys belong to the input method while it composes (§5.3).
        if textView.hasMarkedText() { return false }
        if mode == .content {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): contentPane.moveSelection(1); return true
            case #selector(NSResponder.moveUp(_:)): contentPane.moveSelection(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                if let h = contentPane.selected { openContent(h, reveal: false) }
                return true
            case #selector(NSResponder.insertTab(_:)):
                if !contentPane.hits.isEmpty { panel.makeFirstResponder(contentPane.table) }
                return true
            default: break
            }
        }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activate(.open); return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        case #selector(NSResponder.insertTab(_:)):
            if !rows.isEmpty { panel.makeFirstResponder(table) }
            return true
        default: return false
        }
    }

    private func keyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if field.isComposing { return false }
        let key = event.charactersIgnoringModifiers ?? ""
        switch (flags, key, event.keyCode) {
        case (.command, "1", _): switchMode(.name); return true
        case (.command, "2", _): switchMode(.content); return true
        case (.command, _, 36), (.command, _, 76):
            if mode == .content {
                if let h = contentPane.selected { openContent(h, reveal: false) }
            } else {
                activate(.reveal)
            }
            return true
        case (.command, "g", _) where mode == .content: contentPane.preview.goNext(); return true
        case ([.command, .shift], "g", _) where mode == .content, ([.command, .shift], "G", _) where mode == .content:
            contentPane.preview.goPrev(); return true
        case ([.command, .shift], "c", _), ([.command, .shift], "C", _):
            if mode == .content, let h = contentPane.selected {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(h.dir + "/" + h.name, forType: .string)
                toast("已复制路径")
            } else {
                activate(.copyPath)
            }
            return true
        case (.command, ",", _): hide(); openSettings?(); return true
        case (.command, "/", _): showSyntaxHelp(); return true
        default: return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var i = table.selectedRow
        repeat {
            i += delta
            if i < 0 || i >= rows.count { return }
        } while isGroup(i)
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    private func isGroup(_ i: Int) -> Bool {
        if case .group = rows[i] { return true }
        return false
    }

    private var selectedItem: ResultItem? {
        guard table.selectedRow >= 0, table.selectedRow < rows.count, case .item(let item) = rows[table.selectedRow] else { return nil }
        return item
    }

    private enum Action { case open, reveal, copyPath }

    private func activate(_ action: Action) {
        guard let item = selectedItem else { return }
        let url = URL(fileURLWithPath: item.path)
        switch action {
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
            toast("已复制路径")
            return
        case .open, .reveal:
            guard FileManager.default.fileExists(atPath: item.path) else {
                toast("文件已不存在，索引会自动更新")
                return
            }
            usage?.recordOpen(path: item.path, fileId: item.fileId)
            hide()
            if action == .open { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    @objc private func doubleClicked() {
        if table.clickedRow >= 0 { activate(.open) }
    }

    private func showSyntaxHelp() {
        let pop = NSPopover()
        pop.behavior = .transient
        let label = NSTextField(wrappingLabelWithString: """
            名称模式语法
            空格：同时包含多个词（如 报告 2024）
            "a b"：把空格当作文字
            dir:路径  限定目录，可写多个，支持 ~/
            dir:合同/2024  按目录名片段限定
            ext:pdf;docx  按扩展名过滤
            kind:文件夹 / 应用 / pdf / doc / 图片 …

            运算符（| -）、通配符、正则在后续版本提供，目前按普通字符搜索。
            """)
        label.font = .systemFont(ofSize: 12.5)
        label.preferredMaxLayoutWidth = 320
        let vc = NSViewController()
        let box = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
        ])
        vc.view = box
        pop.contentViewController = vc
        pop.show(relativeTo: field.bounds, of: field, preferredEdge: .maxY)
    }

    // MARK: Quick Look

    private func toggleQuickLook() {
        guard selectedItem != nil else { return }
        let ql = QLPreviewPanel.shared()!
        if ql.isVisible { ql.orderOut(nil) } else { ql.makeKeyAndOrderFront(nil) }
    }

    /// Quick Look calls its data source on the main thread; the URL is mirrored here for it.
    nonisolated(unsafe) private var previewURL: NSURL?

    func tableViewSelectionDidChange(_ notification: Notification) {
        previewURL = selectedItem.map { URL(fileURLWithPath: $0.path) as NSURL }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return Theme.groupHeight }
        return Theme.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = ResultRowView()
        if case .group = rows[row] { v.isGroup = true }
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title):
            let v = tableView.makeView(withIdentifier: .init("group"), owner: nil) as? GroupHeaderView ?? GroupHeaderView()
            v.identifier = .init("group")
            v.label.stringValue = title
            return v
        case .item(let item):
            let v = tableView.makeView(withIdentifier: .init("item"), owner: nil) as? ResultCellView ?? ResultCellView()
            v.identifier = .init("item")
            v.configure(item, terms: output?.query.terms ?? [])
            return v
        }
    }

    /// Drag results out as file URLs (§M1: 拖拽).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard case .item(let item) = rows[row] else { return nil }
        return URL(fileURLWithPath: item.path) as NSURL
    }
}

/// Filter chip in Spotlight's capsule style: translucent fill, rounded, secondary text.
final class CapsuleLabel: NSView {
    private let label: NSTextField
    private let warning: Bool

    init(_ text: String, warning: Bool) {
        label = NSTextField(labelWithString: text)
        self.warning = warning
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("过滤条件 " + text)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func restyle() {
        label.textColor = warning ? Theme.warnText : .secondaryLabelColor
        layer?.backgroundColor = (warning ? Theme.warnBackground : Theme.capsuleFill).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// 1 pt hairline under the search field; drawn with a dynamic color so it follows dark mode.
final class RuleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        bounds.fill()
    }
}

/// Geometry of the Spotlight-style shell.
enum Shell {
    static let width: CGFloat = 720
    static let bar: CGFloat = 58
    static let button: CGFloat = 58
    /// Bar → first button, and between buttons. Both exceed `mergeDistance`, so they end apart.
    static let barGap: CGFloat = 20
    static let gap: CGFloat = 14
    /// Glass shapes closer than this melt together (the liquid "neck" while splitting).
    static let mergeDistance: CGFloat = 12
    static let bodyRadius: CGFloat = 26
    static let maxHeight: CGFloat = 760
    /// Content mode widens to two columns (UI-SPEC §3): list 420 + preview.
    static let contentWidth: CGFloat = 1120
    static let contentBody: CGFloat = 500
    /// Transparent margin around the shell inside the window (room for spring overshoot).
    static let inset: CGFloat = 40
    /// Development: XS_ANIM_SCALE slows animations down for frame-by-frame checks.
    static let animationScale: Double = ProcessInfo.processInfo.environment["XS_ANIM_SCALE"].flatMap(Double.init) ?? 1
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Round glass button (Spotlight's category buttons). Selected = accent-tinted glass.
@MainActor
final class GlassCircleButton: NSGlassEffectView {
    var onPress: (() -> Void)?
    private let button: NSButton

    var isOn = false { didSet { restyle() } }
    /// The selection tint fades with the icon, so a drop budding out of the bar is neutral glass.
    var iconAlpha: CGFloat {
        get { button.alphaValue }
        set {
            button.alphaValue = newValue
            tintColor = isOn ? NSColor.controlAccentColor.withAlphaComponent(0.22 * newValue) : nil
        }
    }

    init(symbol: String, label: String, tip: String) {
        button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        super.init(frame: .zero)
        style = .regular
        cornerRadius = Shell.button / 2
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 21, weight: .medium)
        button.toolTip = tip
        button.setAccessibilityLabel(label + "模式")
        button.target = self
        button.action = #selector(pressed)
        let content = NSView()
        button.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            button.topAnchor.constraint(equalTo: content.topAnchor),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        contentView = content
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    /// Always a circle: the radius follows the diameter while the drop grows or overshoots.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cornerRadius = min(newSize.width, newSize.height) / 2
    }

    func animateIcon(visible: Bool, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = visible ? 0.22 : 0.12
                    self.button.animator().alphaValue = visible ? 1 : 0
                }
            }
        }
    }

    private func restyle() {
        tintColor = isOn ? NSColor.controlAccentColor.withAlphaComponent(0.22 * button.alphaValue) : nil
        button.contentTintColor = isOn ? .controlAccentColor : .labelColor
        button.setAccessibilityValue(isOn ? "已选中" : "")
    }
}

/// Interpolates a circle by center and diameter, keeping it centered on the bar's midline, so
/// an overshooting spring grows it evenly on all sides instead of pushing past one edge.
func circleLerp(_ a: NSRect, _ b: NSRect, _ t: Double, size: Double? = nil) -> NSRect {
    let s = CGFloat(size ?? t)
    let t = CGFloat(t)
    let d = max(0, a.width + (b.width - a.width) * s)
    let cx = a.midX + (b.midX - a.midX) * t
    let cy = a.midY + (b.midY - a.midY) * t
    return NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
}

func lerp(_ a: NSRect, _ b: NSRect, _ t: Double) -> NSRect {
    let t = CGFloat(t)
    return NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                  width: max(0, a.width + (b.width - a.width) * t), height: max(0, a.height + (b.height - a.height) * t))
}

/// Damped spring step response with a start delay; `response` is the period in seconds.
struct SpringCurve {
    var response: Double
    var damping: Double
    var delay: Double = 0

    /// Seconds until settled within ~0.1%.
    var settle: Double { delay + 7 / (damping * 2 * .pi / response) }

    /// 0 before `delay`, then 1 - e^(-ζωt)(cos ωd t + ζω/ωd sin ωd t); overshoots when ζ < 1.
    func value(_ time: Double) -> Double {
        let t = time - delay
        guard t > 0 else { return 0 }
        guard time < settle else { return 1 }
        let w = 2 * .pi / response, z = min(damping, 0.999)
        let wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }
}

/// Calls `step(elapsed)` on every display refresh for `duration` seconds (scaled by
/// XS_ANIM_SCALE), then `step(duration)` and `completion`.
@MainActor
final class FrameDriver: NSObject {
    private let step: (Double) -> Void
    private let completion: () -> Void
    private let duration: Double
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private weak var view: NSView?

    init(view: NSView, duration: Double, step: @escaping (Double) -> Void, completion: @escaping () -> Void) {
        self.view = view
        self.duration = duration
        self.step = step
        self.completion = completion
    }

    func start() {
        guard let view else { return }
        startTime = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        step(0)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let t = (CACurrentMediaTime() - startTime) / Shell.animationScale
        if t >= duration {
            stop()
            step(duration)
            completion()
            return
        }
        step(t)
    }
}

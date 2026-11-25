import AppKit
import Catalog
import ContentEngine
import Quartz
import UniformTypeIdentifiers
import XSearchCore

/// Non-activating panel: it takes keyboard focus without activating XSearch, so closing it
/// leaves the previously active app in front (§13).
final class LauncherPanel: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    /// Esc anywhere in the panel: the controller's hide (it also hands the front back).
    var onCancel: (() -> Void)?

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

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { orderOut(nil) }
    }
}

/// Text field that reports IME composition so searches and key handling can wait (§5.3).
final class LauncherField: NSTextField {
    var isComposing: Bool { (currentEditor() as? NSTextView)?.hasMarkedText() ?? false }
}

final class ResultTable: NSTableView {
    var onSpace: (() -> Void)?
    var onReturn: ((NSEvent.ModifierFlags) -> Void)?
    /// Replaces the default arrow handling (lists with rows that cannot be selected).
    var onMove: ((Int) -> Void)?
    /// ↑ on the first row leaves the list for the input.
    var isAtTop: (() -> Bool)?
    var onLeave: (() -> Void)?
    /// A character typed in the list: it belongs to the input.
    var onTyping: ((NSEvent) -> Void)?

    private func isTyping(_ event: NSEvent) -> Bool {
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { return false }
        if event.keyCode == 51 { return true }  // delete
        guard let c = event.characters?.unicodeScalars.first else { return false }
        return c.value >= 32 && c.value != 127 && !(0xF700...0xF8FF).contains(c.value)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onSpace?()                                      // space: Quick Look (list focused only)
        case 36, 76: onReturn?(event.modifierFlags)              // return / enter
        case 126 where isAtTop?() == true: onLeave?()
        case 125 where onMove != nil: onMove?(1)
        case 126 where onMove != nil: onMove?(-1)
        default:
            if let onTyping, isTyping(event) { onTyping(event) } else { super.keyDown(with: event) }
        }
    }

    // Quick Look panel control lives on the focused table.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    /// The context menu for a row. Asked here rather than through `menu` so that the table does
    /// not draw its square outline around the row: the clicked row becomes the selection.
    var contextMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? contextMenu?(row) : nil
    }

    /// Who feeds Quick Look for this table, when not its delegate (the content list's).
    weak var previewController: AnyObject?
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            let owner = previewController ?? delegate
            panel.dataSource = owner as? QLPreviewPanelDataSource
            panel.delegate = owner as? QLPreviewPanelDelegate
        }
    }
    /// Quick Look closed: the launcher takes the keyboard back.
    var onPreviewEnded: (() -> Void)?
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            onPreviewEnded?()
        }
    }
}

@MainActor
final class LauncherController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let panel = LauncherPanel()
    private let session: SearchSession
    private let usage: UsageStore?
    var openSettings: (() -> Void)?
    var openDiagnostics: (() -> Void)?

    private let field = LauncherField()
    // Spotlight shell: one glass bar, plus round glass mode buttons that split out of it.
    private let container = NSGlassEffectContainerView()
    private let mainGlass = NSGlassEffectView()
    /// The ⌘/ cheat sheet while it is shown: Esc closes it before the launcher.
    private var syntaxPopover: NSPopover?
    /// The window's content: the full transparent canvas while the shell animates, just the glass at rest.
    private let shellRoot = FlippedView()
    private static let canvasSize = NSSize(width: Shell.contentWidth + 2 * Shell.inset, height: Shell.maxHeight + 2 * Shell.inset)
    private let header = FlippedView()
    private let body = FlippedView()
    private var driver: FrameDriver?
    private let contentChip = NSButton(title: L("内容  ×"), target: nil, action: nil)
    /// Spotlight-style scope: Tab on an app (its documents) or a folder (its contents).
    private let scopeChip = NSButton(title: "", target: nil, action: nil)
    private var scopeChipWidth: NSLayoutConstraint!
    /// Tokens in the input, measured from Spotlight: 30 pt high, nearly the input's own text size.
    private static let tokenFont = NSFont.systemFont(ofSize: 24)
    private enum Scope { case app(DocumentTypes), folder(String), kind(FileKind) }
    private var scope: Scope?
    private let chips = NSStackView()
    /// Quick filters from the results (Spotlight): a click puts one in the input as a token.
    private let filters = NSStackView()
    private var filterActions: [() -> Void] = []
    private var defaultApps: [String: URL?] = [:]
    private let table = ResultTable()
    private let scroll = NSScrollView()
    /// Spotlight's scroll edge: a hairline under the pills, shown only while rows are scrolled
    /// up out of sight (they pass under it into the list's top inset).
    private let scrollEdge = RuleView()
    private var scrollEdgeShown = false
    /// The gap above the list. A gap, not a content inset: rows must be clipped at the list's top
    /// edge (where the scroll edge sits), as in Spotlight, not slide on into the inset.
    private let listGap = NSView()
    private var listGapHeight: NSLayoutConstraint!
    private static let listGapSize: CGFloat = 4
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
        panel.onCancel = { [weak self] in self?.cancel() }
        QuickLookKeyboard.install()
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Clicking elsewhere dismisses the launcher; Quick Look and drags keep it.
            MainActor.assumeIsolated {
                guard let self, !(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible) else { return }
                // Decided a moment later, once a screenshot tool's overlay is up (see below).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard self.panel.isVisible, !self.panel.isKeyWindow else { return }
                    if self.screenOverlayInFront() { if self.overlayWait == nil { self.waitForOverlay() } } else { self.hide() }
                }
            }
        }
    }

    private var resignObserver: NSObjectProtocol?

    /// Replaced by a new launcher (the name index was rebuilt): nothing of this one may keep
    /// listening or waiting.
    func dispose() {
        hide()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let quickLookMonitor { NSEvent.removeMonitor(quickLookMonitor) }
        quickLookMonitor = nil
    }

    /// A screenshot tool (Snipaste) freezes the screen, then puts a full-screen overlay of its
    /// own in front and takes the keyboard. Hiding then took the launcher out of the window list
    /// the tool frames windows from, though it was in the frozen picture (Spotlight stays).
    private func screenOverlayInFront() -> Bool {
        guard let screen = panel.screen?.frame,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]] else { return false }
        // The app that took the keyboard: the Dock's full-screen window is always there too.
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front != ProcessInfo.processInfo.processIdentifier else { return false }
        // Window bounds count from the top left of the main display, downwards.
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.maxY
        let center = CGPoint(x: screen.midX, y: mainHeight - screen.midY)
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == front, (w[kCGWindowLayer as String] as? Int ?? 0) > 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            // Covering the launcher's own display, not just as large as it.
            return r.width >= screen.width * 0.9 && r.height >= screen.height * 0.9 && r.contains(center)
        }
    }

    /// The launcher stays while the overlay is up and takes the keyboard back after it. One
    /// wait at a time, looking less often the longer it stays (0.25 s doubling to 1 s); after a
    /// minute (another app's full-screen window taken for an overlay) the launcher hides.
    private func waitForOverlay(after delay: TimeInterval = 0.25, until deadline: Date = Date().addingTimeInterval(60)) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.overlayWait = nil
                guard self.panel.isVisible, !self.panel.isKeyWindow else { return }
                if !self.screenOverlayInFront() {
                    self.panel.makeKeyAndOrderFront(nil)
                } else if Date() >= deadline {
                    self.hide()
                } else {
                    self.waitForOverlay(after: min(delay * 2, 1), until: deadline)
                }
            }
        }
        overlayWait = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var overlayWait: DispatchWorkItem?

    // MARK: Layout

    private func build() {
        // Fixed transparent window; only the glass frames move inside it (no window jumps).
        // Transparent margin on every side: springs overshoot (bigger drops, wider bounce) and
        // must never be clipped by the window edge.
        let root = shellRoot
        root.frame = NSRect(origin: .zero, size: Self.canvasSize)
        container.spacing = Shell.mergeDistance
        container.contentView = root
        panel.contentView = container
        panel.setContentSize(root.frame.size)

        mainGlass.style = .regular
        mainGlass.cornerRadius = Shell.cornerRadius
        // Plain glass lets bright windows behind it wash out the text; a tint keeps the depth.
        mainGlass.tintColor = Theme.panelTint
        let mainContent = FlippedView()
        mainGlass.contentView = mainContent
        root.addSubview(mainGlass)
        mainContent.addSubview(header)
        mainContent.addSubview(body)

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L("搜索"))!)
        icon.symbolConfiguration = .init(pointSize: 24, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.font = Theme.inputFont
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(L("搜索"))

        contentChip.bezelStyle = .inline
        contentChip.isBordered = false
        contentChip.wantsLayer = true
        contentChip.layer?.cornerRadius = 8
        // Same look as the Tab scope token, without an icon.
        contentChip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
        contentChip.contentTintColor = .labelColor
        contentChip.font = Self.tokenFont
        contentChip.title = L("内容")
        contentChip.widthAnchor.constraint(equalToConstant: ceil((L("内容") as NSString).size(withAttributes: [.font: Self.tokenFont]).width) + 24).isActive = true
        contentChip.heightAnchor.constraint(equalToConstant: 30).isActive = true
        contentChip.target = self
        contentChip.action = #selector(removeContentPrefix)
        contentChip.setAccessibilityLabel(L("移除内容前缀"))
        contentChip.isHidden = true

        scopeChip.bezelStyle = .inline
        scopeChip.isBordered = false
        scopeChip.wantsLayer = true
        scopeChip.layer?.cornerRadius = 8
        scopeChip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
        scopeChip.contentTintColor = .labelColor
        scopeChip.font = Self.tokenFont
        scopeChip.heightAnchor.constraint(equalToConstant: 30).isActive = true
        scopeChipWidth = scopeChip.widthAnchor.constraint(equalToConstant: 0)
        scopeChipWidth.isActive = true
        scopeChip.imagePosition = .imageLeading
        scopeChip.imageHugsTitle = true
        scopeChip.target = self
        scopeChip.action = #selector(removeScope)
        scopeChip.isHidden = true

        let headerRow = NSStackView(views: [icon, contentChip, scopeChip, field])
        headerRow.orientation = .horizontal
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRow)
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22),
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

        filters.orientation = .horizontal
        // Measured from Spotlight on macOS 26: 26 pt pills, 15 pt text, 8 pt padding, 8 pt apart,
        // 11 pt below the rule. Top alignment: centred, the stack split the insets evenly and the
        // pills sat 6 pt under the rule whatever the top inset said.
        filters.spacing = 8
        filters.edgeInsets = NSEdgeInsets(top: 11, left: 20, bottom: 6, right: 20)
        filters.alignment = .top
        filters.isHidden = true
        chips.orientation = .horizontal
        chips.spacing = 8
        chips.edgeInsets = NSEdgeInsets(top: 11, left: 20, bottom: 6, right: 20)
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
        table.onMove = { [weak self] in self?.moveSelection($0) }
        table.isAtTop = { [weak self] in self?.selectionIsFirst ?? false }
        table.onLeave = { [weak self] in self?.focusInput() }
        table.onTyping = { [weak self] in self?.typeInInput($0) }
        table.onReturn = { [weak self] flags in self?.activate(flags.contains(.command) ? .reveal : .open) }
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        table.setAccessibilityLabel(L("搜索结果"))
        table.contextMenu = { [weak self] row in self?.contextMenu(content: false, row: row) }
        table.onPreviewEnded = { [weak self] in self?.previewEnded() }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        notice.orientation = .vertical
        notice.alignment = .leading
        notice.spacing = 6
        notice.edgeInsets = NSEdgeInsets(top: 10, left: 22, bottom: 14, right: 22)
        notice.isHidden = true

        hints.font = Theme.hintFont
        hints.textColor = .secondaryLabelColor
        status.font = Theme.hintFont
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        status.lineBreakMode = .byTruncatingHead
        let footer = NSStackView(views: [hints, NSView(), status])
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 7, left: 22, bottom: 11, right: 22)
        hints.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentPane = ContentPane(searcher: session.content)
        contentPane.table.isAtTop = { [weak self] in (self?.contentPane.table.selectedRow ?? 0) <= 0 }
        contentPane.table.onLeave = { [weak self] in self?.focusInput() }
        contentPane.table.onTyping = { [weak self] in self?.typeInInput($0) }
        contentPane.table.contextMenu = { [weak self] row in self?.contextMenu(content: true, row: row) }
        contentPane.table.previewController = self
        contentPane.table.onPreviewEnded = { [weak self] in self?.previewEnded() }
        contentPane.onOpen = { [weak self] hit, reveal in self?.openContent(hit, reveal: reveal) }
        contentPane.onRead = { [weak self] hit, n in self?.openReader(hit, at: n) }
        contentPane.isHidden = true
        let stack = rootStack
        for v in [ruleRow, filters, chips, listGap, scroll, contentPane!, notice, footer] { stack.addArrangedSubview(v) }
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stack)
        for v in [ruleRow, filters, chips, listGap, scroll, contentPane!, notice, footer] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        listGapHeight = listGap.heightAnchor.constraint(equalToConstant: 0)
        listGapHeight.isActive = true
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        // Over the list, not inside it: a scroll view lays out its own subviews and ignores constraints.
        scrollEdge.translatesAutoresizingMaskIntoConstraints = false
        scrollEdge.alphaValue = 0
        body.addSubview(scrollEdge, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            scrollEdge.topAnchor.constraint(equalTo: scroll.topAnchor),
            scrollEdge.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20),
            scrollEdge.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            scrollEdge.heightAnchor.constraint(equalToConstant: 1),
        ])
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

    /// Shows the scroll edge once the first row starts to slide under the list's top inset.
    @objc private func listScrolled() {
        let scrolled = scroll.contentView.bounds.minY > 0.5
        guard scrolled != scrollEdgeShown else { return }
        scrollEdgeShown = scrolled
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            scrollEdge.animator().alphaValue = scrolled ? 1 : 0
        }
    }

    // MARK: Spotlight shell

    private var shellWidth: CGFloat { mode == .content ? Shell.contentWidth : Shell.width }
    /// Left edge of the shell on the stage: the shell stays centred when it widens.
    private var originX: CGFloat { (Shell.contentWidth - shellWidth) / 2 }

    private var mainWidth: CGFloat { shellWidth }

    /// Places the bar and the result body, matching Spotlight's choreography (measured frame by
    /// frame from a screen recording): to collapse, content fades out first, a short pause, then
    /// the height springs down; to expand, height grows at once and content fades in.
    private func layoutShell(animated: Bool) {
        let targetW = mainWidth
        let targetH = Shell.bar + bodyHeight
        let targetMain = NSRect(x: originX, y: 0, width: targetW, height: targetH)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        driver?.stop()
        shellAnimating = false
        openCanvas()
        guard animated && !reduceMotion && panel.isVisible else {
            setMainFrame(targetMain)
            body.isHidden = bodyHeight == 0
            body.alphaValue = 1
            fitToGlass()
            return
        }

        let from = mainGlass.frame.offsetBy(dx: -Shell.inset, dy: -Shell.inset)
        let fromBodyAlpha = body.alphaValue
        // Only collapsing to the bare bar fades the content out first; a body that merely gets
        // shorter (a notice line gone) keeps its content and simply resizes.
        let collapsing = targetH < from.height - 0.5 && bodyHeight == 0
        let expanding = targetH > from.height + 0.5
        let widthCurve = SpringCurve(response: 0.3, damping: 0.86)
        // Spotlight: content gone in ~25 ms, a ~0.1 s hold, then a quick height snap (~0.1 s).
        let heightCurve: SpringCurve = collapsing ? .init(response: 0.2, damping: 0.95, delay: 0.1) : .init(response: 0.28, damping: 0.82)
        if expanding { body.isHidden = false }

        var duration = max(widthCurve.settle, heightCurve.settle)
        if collapsing { duration = max(duration, 0.2) }
        driver = FrameDriver(view: mainGlass, duration: duration) { [weak self] t in
            guard let self else { return }
            let w = from.width + (targetW - from.width) * CGFloat(widthCurve.value(t))
            let x = from.minX + (targetMain.minX - from.minX) * CGFloat(widthCurve.value(t))
            let h = from.height + (targetH - from.height) * CGFloat(heightCurve.value(t))
            self.setMainFrame(NSRect(x: x, y: 0, width: w, height: max(Shell.bar, h)))
            // Body content: fade out quickly before collapsing, fade in while expanding.
            if collapsing {
                self.body.alphaValue = fromBodyAlpha * CGFloat(max(0, 1 - t / 0.04))
            } else if expanding || fromBodyAlpha < 1 {
                self.body.alphaValue = fromBodyAlpha + (1 - fromBodyAlpha) * CGFloat(min(1, max(0, (t - 0.04) / 0.12)))
            }
        } completion: { [weak self] in
            guard let self else { return }
            self.setMainFrame(targetMain)
            if self.bodyHeight == 0 { self.body.isHidden = true }
            self.body.alphaValue = 1
            self.shellAnimating = false
            self.fitToGlass()
        }
        shellAnimating = true
        driver?.start()
    }

    /// Where the canvas origin sits in the window: zero on the full canvas; at rest the window is
    /// just the glass, so the canvas starts that far up and left of it (flipped).
    private var canvasOffset = NSPoint.zero
    private var shellAnimating = false
    private var mainFrame = NSRect.zero

    /// At rest the window is just the glass, as Spotlight's is, so screenshot tools frame the
    /// panel and not the transparent canvas. The glass keeps its place on screen. The glass view
    /// itself moves to the window origin (shifting the container's bounds instead left the glass
    /// behind when the window had just been ordered in: f1a61cf, reverted in fd0ba71).
    private func fitToGlass() {
        guard canvasOffset == .zero else { return }
        let g = mainGlass.frame
        let f = panel.frame
        canvasOffset = g.origin
        panel.setFrame(NSRect(x: f.minX + g.minX, y: f.maxY - g.maxY, width: g.width, height: g.height), display: false)
        shellRoot.frame = NSRect(origin: .zero, size: g.size)
        setMainFrame(mainFrame)
    }

    /// Back to the full canvas, for animating and placing; the glass stays where it is on screen.
    private func openCanvas() {
        guard canvasOffset != .zero else { return }
        let f = panel.frame, o = canvasOffset
        canvasOffset = .zero
        panel.setFrame(NSRect(x: f.minX - o.x, y: f.maxY + o.y - Self.canvasSize.height, width: Self.canvasSize.width, height: Self.canvasSize.height), display: false)
        shellRoot.frame = NSRect(origin: .zero, size: Self.canvasSize)
        setMainFrame(mainFrame)
    }

    /// The bar's inner header and body track the glass size exactly (no autoresizing drift).
    /// `frame` is in canvas coordinates.
    private func setMainFrame(_ frame: NSRect) {
        mainFrame = frame
        mainGlass.frame = frame.offsetBy(dx: Shell.inset - canvasOffset.x, dy: Shell.inset - canvasOffset.y)
        header.frame = NSRect(x: 0, y: 0, width: frame.width, height: Shell.bar)
        body.frame = NSRect(x: 0, y: Shell.bar, width: frame.width, height: max(0, frame.height - Shell.bar))
    }

    // MARK: Show / hide

    var isVisible: Bool { panel.isVisible }

    func toggle() { panel.isVisible ? hide() : show() }

    func show(mode requested: Preferences.Mode? = nil, text: String? = nil) {
        let previous = field.stringValue
        if let text {
            field.stringValue = text
        } else if !Preferences.shared.keepLastQuery {
            field.stringValue = ""
            scope = nil
            scopeChip.isHidden = true
            updatePlaceholder()
        }
        // The search below answers asynchronously: results of another query must not decide the
        // height the panel appears with, or it opens large and collapses a moment later.
        if field.stringValue != previous { forgetResults() }
        session.refreshApps()
        let prefs = Preferences.shared
        setMode(requested ?? (prefs.summonMode == .rememberLast ? prefs.lastMode : .name))
        driver?.stop()
        runSearch()
        resize(animated: false)
        position()
        panel.makeKeyAndOrderFront(nil)
        onVisibilityChange?()
        if let delay = ProcessInfo.processInfo.environment["XS_CLEAR_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.field.stringValue = ""
                    self?.runSearch()
                }
            }
        }
        panel.makeFirstResponder(field)
        // Select the previous input so typing replaces it (§6.1).
        field.currentEditor()?.selectAll(nil)
    }

    func hide() {
        overlayWait?.cancel()
        overlayWait = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        panel.orderOut(nil)
        // Nobody is looking: stop the queries and release the preview. `show` searches again.
        session.cancel(nameRequest)
        session.content.cancel()
        contentPane.releasePreview()
        onVisibilityChange?()
    }

    /// The launcher's latest name search, cancelled when it hides.
    private var nameRequest = 0

    private func forgetResults() {
        output = nil
        contentOutput = nil
        contentShown = 0
        rows = []
        table.reloadData()
        contentPane.clearResults()
        setChips([])
        filters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        filters.isHidden = true
        clearNotice()
    }

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        openCanvas()
        let size = panel.frame.size
        let top = frame.maxY - frame.height / 6
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - size.width / 2, y: top + Shell.inset))
        if !shellAnimating { fitToGlass() }
    }

    /// Body height from its content; zero (a plain search bar) when there is nothing to show.
    private func resize(animated: Bool = true) {
        // Whole rows only: the list stops above the first row that would be cut by the cap.
        let insets = scroll.contentInsets.top + scroll.contentInsets.bottom
        var content: CGFloat = 0
        for r in rows {
            let h: CGFloat = if case .group = r { Theme.groupHeight } else { Theme.rowHeight }
            if content + h + insets + Self.listGapSize > Theme.maxListHeight { break }
            content += h
        }
        let contentMode = mode == .content
        listHeight.constant = contentMode ? 0 : content + (content > 0 ? insets : 0)
        listGapHeight.constant = listHeight.constant > 0 ? Self.listGapSize : 0
        contentHeight.constant = contentMode && !contentPane.hits.isEmpty ? Shell.contentBody : 0
        contentPane.isHidden = contentHeight.constant == 0
        scroll.isHidden = contentMode
        chipsHeight.constant = chips.arrangedSubviews.isEmpty ? 0 : 40
        if mode == .content { filters.isHidden = true }
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
        // The Tab scope belongs to name search only; content search never carries it.
        if m == .content && scope != nil {
            scope = nil
            scopeChip.isHidden = true
        }
        Preferences.shared.lastMode = m
        updatePlaceholder()
        updateHints()
    }

    private func updatePlaceholder() {
        switch scope {
        case .app(let t)?: field.placeholderString = L("在“%@”可打开的文档中搜索", "\(t.appName)")
        case .folder(let p)?: field.placeholderString = L("在“%@”中搜索", "\(FileManager.default.displayName(atPath: p))")
        case .kind?: field.placeholderString = L("搜索应用和文件")
        case nil: field.placeholderString = mode == .name ? L("搜索应用和文件") : L("在文件内容中查找")
        }
    }

    /// Tab on the selected app or folder narrows the search to it (Spotlight, macOS 26: apps
    /// narrow to the documents they can open, locations to their files). Returns false when
    /// the selection is neither (Tab then moves the focus as before).
    private func scopeToSelection() -> Bool {
        guard mode == .name, let item = selectedItem else { return false }
        switch item.kind {
        case .app:
            var types = DocumentTypes(appPath: item.path)
            if types.isEmpty { toast(L("“%@”没有声明可打开的文档类型", "\(item.name)")); return true }
            // The name as Finder shows it (localized: “预览”, not “Preview”).
            types.appName = (FileManager.default.displayName(atPath: item.path) as NSString).deletingPathExtension
            setScope(.app(types), icon: appIcon(atPath: item.path), title: types.appName)
        case .folder:
            setScope(.folder(item.path), icon: NSWorkspace.shared.icon(forFile: item.path), title: FileManager.default.displayName(atPath: item.path))
        default:
            return false
        }
        return true
    }

    private func setScope(_ s: Scope?, icon: NSImage? = nil, title: String = "", keepText: Bool = false) {
        scope = s
        if s != nil {
            icon?.size = NSSize(width: 24, height: 24)
            scopeChip.image = icon
            scopeChip.title = title
            // Icon and text sit together, centred, with about Spotlight's padding around them.
            let textWidth = ceil((title as NSString).size(withAttributes: [.font: Self.tokenFont]).width)
            scopeChipWidth.constant = textWidth + (icon == nil ? 24 : 46)
            scopeChip.setAccessibilityLabel(L("移除范围 %@", "\(title)"))
            if !keepText { field.stringValue = "" }
        }
        scopeChip.isHidden = s == nil
        updatePlaceholder()
        runSearch()
    }

    @objc private func removeScope() { setScope(nil) }

    /// The scope as query text the parsers already understand (folder) and the app's types.
    private var scopeFolderClause: String {
        if case .folder(let p)? = scope { return " dir:\"\(p)\"" }
        if case .kind(let k)? = scope { return " kind:" + k.rawValue }
        return ""
    }

    /// Chips for the filters the scope added (shown once, as the scope token).
    private func isScopeChip(_ label: String) -> Bool {
        switch scope {
        case .folder(let p)?: return label == "dir:" + p || label == "dir:\"\(p)\""
        case .kind(let k)?: return label == "kind:" + k.rawValue
        case .app?: return false
        case nil: return false
        }
    }

    private var scopeTypes: DocumentTypes? {
        if case .app(let t)? = scope { return t }
        return nil
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
        pendingTrash = nil
        // While the input method composes, results stay as they were (§5.3).
        guard !field.isComposing else { return }
        runSearch()
    }

    private func runSearch() {
        // Typing `in ` turns into the “内容” token: the prefix leaves the input (§4.1).
        if field.stringValue.hasPrefix("in ") {
            field.stringValue = String(field.stringValue.dropFirst(3))
            if mode != .content {
                setMode(.content)
                layoutShell(animated: panel.isVisible)
            }
        }
        let text = field.stringValue
        contentChip.isHidden = mode != .content
        if mode == .content {
            session.content.mode = Preferences.shared.contentMatchMode
            session.content.search(text, home: NSHomeDirectory(), syntax: Preferences.shared.querySyntax) { [weak self] out in self?.applyContent(out) }
            return
        }
        session.content.cancel()
        nameRequest = session.search(text + scopeFolderClause, documentTypes: scopeTypes) { [weak self] out in self?.apply(out) }
    }

    /// The app list loads asynchronously; refresh visible results when it arrives.
    func appsDidLoad() {
        if panel.isVisible && mode == .name { runSearch() }
    }

    private func apply(_ out: SearchOutput) {
        // The same query again (the app list finished loading…): stay where the user is.
        let keep = output?.text == out.text ? selectedItem?.path : nil
        output = out
        rows = []
        var lastGroup: ResultItem.Group?
        for item in out.items {
            // Search results need no heading (Spotlight; apps still come first and say "应用" on
            // the right); the favorites and recents of an empty query keep theirs.
            if item.group != lastGroup {
                if item.group == .favorites || item.group == .recents { rows.append(.group(L(item.group.rawValue, context: "group"))) }
                lastGroup = item.group
            }
            rows.append(.item(item))
        }
        setChips(out.query.chips)
        setFilters(for: out)
        table.reloadData()
        // The clip view moves an empty list up inside the 8 pt empty body (4 pt insets), further
        // with each empty result; the rows that followed kept the offset and the first was cut.
        table.setFrameOrigin(.zero)
        // Start at the top so the first group header stays visible.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
        let kept = keep.flatMap { path in rows.firstIndex { if case .item(let i) = $0 { return i.path == path }; return false } }
        if let row = kept ?? rows.firstIndex(where: { if case .item = $0 { return true }; return false }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            if kept != nil { table.scrollRowToVisible(row) }
        }
        setNotice(for: out)
        updateStatus()
        resize()
    }

    private static let kindLabels: [(FileKind, String)] = [
        (.folder, L("文件夹")), (.app, L("应用")), (.pdf, "PDF"), (.word, L("文档")), (.sheet, L("表格")), (.slide, L("演示")), (.ofd, "OFD"),
        (.text, L("文本")), (.image, L("图片")), (.video, L("视频")), (.audio, L("音频")), (.archive, L("压缩包")),
    ]

    /// The kinds among the results, most frequent first, then the apps that open them, as many
    /// as fit in one row. Offered only while nothing narrows the search yet.
    private func setFilters(for out: SearchOutput) {
        filters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        filterActions = []
        defer { filters.isHidden = filters.arrangedSubviews.isEmpty }
        let found = out.items.filter { $0.group == .apps || $0.group == .files }
        guard mode == .name, scope == nil, !out.query.isEmpty, !found.isEmpty else { return }
        var kinds: [FileKind: Int] = [:]
        var exts: [String: Int] = [:]
        for item in found {
            kinds[item.kind, default: 0] += 1
            if item.kind != .folder, item.kind != .app, !item.ext.isEmpty { exts[item.ext, default: 0] += 1 }
        }
        var offers: [(String, () -> Void)] = []
        for (kind, label) in Self.kindLabels.sorted(by: { (kinds[$0.0] ?? 0) > (kinds[$1.0] ?? 0) }) where kinds[kind] != nil {
            offers.append((label, { [weak self] in self?.applyFilter(.kind(kind), title: label, icon: Self.icon(for: kind)) }))
        }
        var seen = Set<String>()
        for ext in exts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(4).map(\.key) {
            guard let app = defaultApp(for: ext), seen.insert(app.path).inserted else { continue }
            let name = (FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension
            offers.append((name, { [weak self] in self?.applyAppFilter(app, name: name) }))
        }
        var room = mainWidth - filters.edgeInsets.left - filters.edgeInsets.right
        for (title, action) in offers {
            let chip = NSButton(title: title, target: self, action: #selector(filterClicked(_:)))
            chip.isBordered = false
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 13
            chip.layer?.backgroundColor = Theme.pillFill.cgColor
            let text = NSAttributedString(string: title, attributes: [.font: Theme.pillFont, .foregroundColor: Theme.pillText])
            chip.attributedTitle = text
            let chipWidth = ceil(text.size().width) + 16
            chip.widthAnchor.constraint(equalToConstant: chipWidth).isActive = true
            chip.heightAnchor.constraint(equalToConstant: 26).isActive = true
            let width = chipWidth + filters.spacing
            if width > room { continue }
            room -= width
            chip.tag = filterActions.count
            chip.setAccessibilityLabel(L("筛选 %@", "\(title)"))
            filters.addArrangedSubview(chip)
            filterActions.append(action)
        }
    }

    private static func icon(for kind: FileKind) -> NSImage? {
        let type: UTType? = switch kind {
        case .folder: .folder
        case .app: .application
        case .pdf: .pdf
        case .word: UTType(filenameExtension: "docx")
        case .sheet: UTType(filenameExtension: "xlsx")
        case .slide: UTType(filenameExtension: "pptx")
        case .text: .plainText
        case .image: .png
        case .video: .movie
        case .audio: .audio
        case .archive: .zip
        case .ofd, .other: nil
        }
        return NSWorkspace.shared.icon(for: type ?? .data)
    }

    private func defaultApp(for ext: String) -> URL? {
        if let known = defaultApps[ext] { return known }
        let app = UTType(filenameExtension: ext).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        defaultApps[ext] = app
        return app
    }

    @objc private func filterClicked(_ sender: NSButton) {
        if filterActions.indices.contains(sender.tag) { filterActions[sender.tag]() }
    }

    private func applyFilter(_ s: Scope, title: String, icon: NSImage? = nil) {
        setScope(s, icon: icon, title: title, keepText: true)
        focusInput()
    }

    private func applyAppFilter(_ app: URL, name: String) {
        var types = DocumentTypes(appPath: app.path)
        if types.isEmpty { toast(L("“%@”没有声明可打开的文档类型", "\(name)")); return }
        types.appName = name
        applyFilter(.app(types), title: name, icon: appIcon(atPath: app.path))
    }

    private var selectionIsFirst: Bool {
        guard let first = rows.firstIndex(where: { if case .item = $0 { return true }; return false }) else { return true }
        return table.selectedRow <= first
    }

    /// Back to the input with the caret at the end, ready to go on typing.
    private func focusInput() {
        panel.makeFirstResponder(field)
        let end = (field.stringValue as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    private func typeInInput(_ event: NSEvent) {
        focusInput()
        field.currentEditor()?.keyDown(with: event)
    }

    private func setChips(_ list: [NameQuery.Chip]) {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for chip in list where !isScopeChip(chip.label) {
            chips.addArrangedSubview(CapsuleLabel(chip.valid ? Loc.display(chip.label) : Loc.display(chip.label) + L("（无法识别）"), warning: !chip.valid))
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
        if out.regexAborted > 0 {
            addNotice(L("正则表达式过于复杂，%@ 个名称未能在时限内匹配，已跳过。", "\(out.regexAborted)"), color: Theme.warnText, size: 12.5)
        }
        guard out.items.isEmpty else { return }
        if out.query.isEmpty { return }  // empty input: just the search bar
        let phase = session.names.status.phase
        if phase == .scanning || phase == .starting {
            addNotice(L("文件名索引仍在建立，已处理的部分可以搜索。"), color: Theme.warnText, size: 12.5)
        }
        for dir in out.unresolvedDirs {
            addNotice(L("目录 %@ 不在文件名索引中（不存在、被排除或不在范围内）。", "\(PathUtil.abbreviate(dir, home: NSHomeDirectory()))"), size: 12.5)
        }
        let text = out.query.terms.joined(separator: " ")
        addNotice(L("文件名索引中没有匹配“%@”的项目", "\(text.isEmpty ? out.text : text)"))
        addLink(L("查看可能的原因（范围、排除规则、权限）"), action: #selector(showScopeSettings))
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
        // Dev: XS_OPEN_FIRST=1 opens the first content result once, as ↵ would.
        if ProcessInfo.processInfo.environment["XS_OPEN_FIRST"] == "1", !autoOpened, let h = contentPane.selected {
            autoOpened = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openContent(h, reveal: false) }
        }
        updateStatus()
        resize()
    }

    /// Cost hints and "no results" reasons for content queries (UI-SPEC §7).
    private func setContentNotice(_ out: ContentOutput) {
        clearNotice()
        if out.query.isEmpty { return }
        if let error = out.error {
            addNotice(Loc.display(error), color: Theme.warnText, size: 12.5)
            return
        }
        switch out.recall {
        case .pair?: addNotice(L("两个字节的查询用前缀区间召回，结果完整。"), color: Theme.warnText, size: 12.5)
        case .scan?: addNotice(L("单字符或只含排除条件的查询会扫描全部已索引正文；加上 dir: 或 ext: 可以更快。"), color: Theme.warnText, size: 12.5)
        case .longTermsThenVerify?: addNotice(L("先用长词找候选，再核验短词。"), color: .tertiaryLabelColor, size: 12.5)
        default: break
        }
        // §8.7: a dir: outside the content scope can be scanned live, on request only.
        let uncovered = uncoveredDirs(out.query)
        if !uncovered.isEmpty && !out.live {
            let names = uncovered.map { PathUtil.abbreviate($0, home: NSHomeDirectory()) }.joined(separator: L("、"))
            addNotice(L("%@ 没有建立内容索引，结果只包含已索引的文件。", "\(names)"), color: Theme.warnText, size: 12.5)
            addLink(L("实时扫描其中的文本文件"), action: #selector(startLiveScan))
            // Dev: XS_LIVE_SCAN=1 starts the scan without the click.
            if ProcessInfo.processInfo.environment["XS_LIVE_SCAN"] == "1" && out.done && !autoScanned {
                autoScanned = true
                DispatchQueue.main.async { [weak self] in self?.startLiveScan() }
            }
        }
        guard out.done && contentShown == 0 && uncovered.isEmpty else { return }
        addNotice(L("已索引的内容中没有找到“%@”。", "\(out.query.expression)"))
        let stats = session.contentStats?() ?? ContentStats()
        var parts = [L("内容索引 %@ 个文件", "\(Theme.count(stats.indexed))")]
        if stats.paused { parts.append(L("已暂停")) }
        if stats.pending > 0 { parts.append(L("%@ 个文件等待处理", "\(stats.pending)")) }
        if stats.failed > 0 { parts.append(L("%@ 个文件提取失败", "\(stats.failed)")) }
        addNotice(parts.joined(separator: " · "), color: .tertiaryLabelColor, size: 12.5)
        addLink(L("为什么可能搜不到？"), action: #selector(showDiagnostics))
    }

    private var autoScanned = false
    private var autoOpened = false

    private func uncoveredDirs(_ q: ContentQuery) -> [String] {
        let roots = Preferences.shared.contentScope.roots(home: NSHomeDirectory())
        return q.dirs.filter { d in !roots.contains { PathUtil.isWithin(d, $0) } }
    }

    @objc private func startLiveScan() {
        guard let out = contentOutput, !out.query.isEmpty else { return }
        session.liveFiles(dirs: uncoveredDirs(out.query), extensions: out.query.liveExtensions) { [weak self] files, unresolved, truncated in
            // Still the same query, still on screen.
            guard let self, self.panel.isVisible, self.contentOutput?.text == out.text else { return }
            self.beginLiveScan(out, files: files, unresolved: unresolved, truncated: truncated)
        }
    }

    private func beginLiveScan(_ out: ContentOutput, files: [LiveFile], unresolved: [String], truncated: Bool) {
        clearNotice()
        for d in unresolved {
            addNotice(L("%@ 不在文件名索引中，无法扫描。", "\(PathUtil.abbreviate(d, home: NSHomeDirectory()))"), color: Theme.warnText, size: 12.5)
        }
        addNotice(truncated ? L("实时扫描只读取文本类文件（前 %@ 个），不会写入索引。", Theme.count(files.count))
                            : L("实时扫描只读取文本类文件（%@ 个），不会写入索引。", Theme.count(files.count)), color: .tertiaryLabelColor, size: 12.5)
        resize()
        session.content.liveScan(out.query, text: out.text, files: files) { [weak self] batch in self?.applyContent(batch) }
    }

    @objc private func showDiagnostics() {
        hide()
        openDiagnostics?()
    }

    private func openContent(_ hit: ContentHit, reveal: Bool) {
        let path = hit.dir + "/" + hit.name
        guard FileManager.default.fileExists(atPath: path) else {
            toast(L("文件已不存在，索引会自动更新"))
            return
        }
        usage?.recordOpen(path: path, fileId: Int64(hit.fileId))
        // Line / page of the occurrence shown in the preview (打开方式).
        let isShown = contentPane.selected?.fileId == hit.fileId
        let line = isShown ? contentPane.preview.currentLine : nil, page = isShown ? contentPane.preview.currentPage : nil
        hide()
        let url = URL(fileURLWithPath: path)
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if hit.isMember {
            MemberOpener.open(hit) { message in if let message { Self.inform(message) } }
        } else if let message = Opener.open(path: path, line: line, page: page) {
            Self.inform(message)
        }
    }

    /// After the panel is gone: a plain alert in front.
    static func inform(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    @objc private func showScopeSettings() {
        hide()
        openSettings?()
    }

    // MARK: Footer

    private func updateHints() {
        hints.attributedStringValue = Self.hintString(mode == .name
            ? [("↵", L("打开")), ("⌘↵", L("在访达中显示", context: "hint")), ("⌘D", L("收藏")), ("⌘E", L("完整窗口", context: "hint"))]
            : [("↵", L("打开")), ("⌘↵", L("阅读窗口")), ("⌘G", L("下一处")), ("⇧⌘G", L("上一处")), ("⌘E", L("完整窗口", context: "hint"))])
    }

    static func hintString(_ pairs: [(String, String)]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (i, (k, v)) in pairs.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "   ")) }
            s.append(NSAttributedString(string: k, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]))
            s.append(NSAttributedString(string: " " + v, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return s
    }

    func updateStatus() {
        guard Date() >= toastUntil else { return }
        let st = session.names.status
        var parts: [String] = []
        switch st.phase {
        case .starting: parts.append(L("正在打开文件名索引"))
        case .scanning: parts.append(L("正在建立文件名索引 · %@ 项", "\(Theme.count(st.count))"))
        case .ready: parts.append(L("名称索引 %@ 项", "\(Theme.count(st.count))"))
        case .failed: parts.append(L("文件名索引出错，详见设置"))
        }
        if mode == .content {
            let stats = session.contentStats?() ?? ContentStats()
            parts = [L("内容索引 %@ 个文件", "\(Theme.count(stats.indexed))")]
            if stats.paused { parts.append(L("已暂停")) }
            if stats.pending > 0 { parts.append(L("待处理 %@", "\(Theme.count(stats.pending))")) }
            if let out = contentOutput, !out.query.isEmpty, out.error == nil {
                if out.live {
                    parts.append(out.done ? L("实时扫描完成 · %@ 个结果", "\(Theme.count(contentShown))")
                                          : L("实时扫描… %@ / %@ 个文件", "\(Theme.count(out.scanned))", "\(Theme.count(out.scanTotal))"))
                } else {
                    parts.append(out.capped ? L("前 %@ 个结果", "\(Theme.count(contentShown))") : out.done ? L("%@ 个结果", "\(Theme.count(contentShown))") : L("仍在搜索… 已核验 %@ / %@", "\(Theme.count(Int(out.verified)))", "\(Theme.count(Int(out.candidates)))"))
                }
            }
        } else if let out = output, !out.query.isEmpty {
            parts.append(L("%@ 个结果", "\(Theme.count(out.total))"))
            parts.append(String(format: "%.1f ms", out.elapsedMs))
        }
        status.stringValue = parts.joined(separator: " · ")
    }

    // MARK: Favorites, trash, full window

    /// Extract these catalog files again; replies how many were queued (set by the app delegate).
    var reindex: (([Int64], @escaping @MainActor @Sendable (Int) -> Void) -> Void)?

    /// Opens the full window with this query (set by the app delegate).
    var onExpand: ((String, Preferences.Mode) -> Void)?
    private var pendingTrash: String?

    /// Reader window at the current occurrence (set by the app delegate).
    var onRead: ((ContentHit, String, Int, Bool) -> Void)?
    var onVisibilityChange: (() -> Void)?

    private func openReader(_ hit: ContentHit, at n: Int) {
        let expression = contentPane.expressionForReader
        let live = contentPane.liveIds.contains(hit.fileId)
        hide()
        onRead?(hit, expression, n, live)
    }

    private func expandToFullWindow() {
        let text = field.stringValue, mode = self.mode
        hide()
        onExpand?(text, mode)
    }

    /// Path and file id of the selected result in either mode.
    private func currentTarget() -> (path: String, fileId: Int64?)? {
        if mode == .content {
            guard let h = contentPane.selected else { return nil }
            return (h.dir + "/" + h.name, Int64(h.fileId))
        }
        guard let item = selectedItem else { return nil }
        return (item.path, item.fileId)
    }

    /// A selected archive member: the file on disk is the whole archive.
    private var memberSelected: Bool { mode == .content && contentPane.selected?.isMember == true }

    private func toggleFavorite() {
        if memberSelected { toast(MemberOpener.notAlone); return }
        guard let t = currentTarget(), let usage else { return }
        let on = usage.toggleFavorite(path: t.path, fileId: t.fileId)
        toast(on ? L("已加入收藏") : L("已取消收藏"))
        if field.stringValue.isEmpty { runSearch() }
    }

    /// Asks first (UI-SPEC §5.2): the confirmation sits in the notice area, so the panel keeps
    /// focus; ⌘⌫ again or the button confirms, anything else cancels.
    private func trashSelected() {
        if memberSelected { toast(MemberOpener.notAlone); return }
        guard let t = currentTarget() else { return }
        if pendingTrash == t.path {
            confirmTrash()
            return
        }
        pendingTrash = t.path
        clearNotice()
        addNotice(L("将“%@”移到废纸篓？再按一次 ⌘⌫ 确认。", "\((t.path as NSString).lastPathComponent)"), color: Theme.warnText, size: 12.5)
        addLink(L("移到废纸篓"), action: #selector(confirmTrash))
        resize()
    }

    @objc private func confirmTrash() {
        guard let path = pendingTrash else { return }
        pendingTrash = nil
        clearNotice()
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            usage?.remove(path: path)
            toast(L("已移到废纸篓"))
            if mode == .content {
                contentPane.remove(path: path)
            } else {
                rows.removeAll { if case .item(let i) = $0 { return i.path == path }; return false }
                table.reloadData()
                if let first = rows.firstIndex(where: { if case .item = $0 { return true }; return false }) {
                    table.selectRowIndexes([first], byExtendingSelection: false)
                }
            }
        } catch {
            toast(L("无法移到废纸篓：%@", "\(error.localizedDescription)"))
        }
        resize()
    }

    /// Dev (XS_TYPE): feeds keystrokes through the same path as typing ("⇥" Tab, "⌫" delete).
    func typeForTesting(_ script: String) {
        show()
        var delay = 0.3
        for chunk in script.split(separator: "|", omittingEmptySubsequences: false) {
            delay += 0.15
            for ch in chunk {
                // Long enough for what a key starts (Quick Look opening) to finish.
                delay += "↓↑␣⌨◉◌☰⌁⌘ⒺⒼ⏎◇".contains(ch) ? 1 : 0.15
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    if ch == "⇥" { _ = self.scopeToSelection(); return }
                    // "↓" "↑" "␣" "⌨" (the letter x) "⌁" (Esc) "⌘" (⌘W) "Ⓔ" (⌘E) "Ⓖ" (⌘G) "⏎" (Return) are key events through the
                    // key window; "◉" clicks the first quick filter; "◇" sends XSearch to the
                    // background, as when summoned over another app. XS_TYPE_LOG records the state after each.
                    if ch == "◇" {
                        NSApp.deactivate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.panel.makeKeyAndOrderFront(nil); self.logTestState("◇") }
                        return
                    }
                    let codes: [Character: (UInt16, String, NSEvent.ModifierFlags)] = ["↓": (125, "\u{F701}", []), "↑": (126, "\u{F700}", []), "␣": (49, " ", []),
                                                                                       "⌨": (7, "x", []), "⌁": (53, "\u{1B}", []), "⌘": (13, "w", .command), "Ⓔ": (14, "e", .command), "Ⓖ": (5, "g", .command), "⏎": (36, "\r", [])]
                    if let (code, text, flags) = codes[ch] {
                        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: self.panel.windowNumber,
                                                    context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) {
                            // Shortcuts go the application's way (key equivalents first).
                            if flags.isEmpty { (NSApp.keyWindow ?? self.panel).sendEvent(e) } else { NSApp.sendEvent(e) }
                        }
                        self.logTestState(String(ch))
                        return
                    }
                    // "⎋": Esc, then the hotkey at once. Logs the height the panel appears with.
                    if ch == "⎋" {
                        self.hide()
                        self.show()
                        self.logShownHeight()
                        return
                    }
                    if ch == "◌" { self.logTestState("◌"); return }  // log only
                    // "☰": the context menu of the selected row, logged item by item.
                    if ch == "☰" { self.logMenu(); return }
                    if ch == "◉" {
                        (self.filters.arrangedSubviews.first as? NSButton)?.performClick(nil)
                        self.logTestState("◉")
                        return
                    }
                    if ch == "⌫" && self.field.stringValue.isEmpty {
                        if self.scope != nil { self.setScope(nil) } else if self.mode == .content { self.switchMode(.name) }
                        return
                    }
                    if ch == "⌫" { self.field.stringValue = String(self.field.stringValue.dropLast()) } else { self.field.stringValue.append(ch) }
                    self.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: self.field))
                }
            }
        }
    }

    private func logMenu() {
        guard let path = ProcessInfo.processInfo.environment["XS_TYPE_LOG"] else { return }
        let content = mode == .content
        let menu = NSMenu()
        fillMenu(menu, content: content, row: (content ? contentPane.table : table).selectedRow)
        let kind = content ? (contentPane.selected?.isMember == true ? "member" : "hit") : (selectedItem.map { "\($0.kind)" } ?? "-")
        let items = menu.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.submenu.map { "▸\($0.items.filter { !$0.isSeparatorItem }.count)" } ?? "") }
        let line = "☰ \(kind) ext=\(content ? ((contentPane.selected?.displayName ?? "") as NSString).pathExtension : selectedItem?.ext ?? "") : \(items.joined(separator: " | "))\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
        // XS_MENU_DO: runs the item with this title (prefix), then logs the state.
        if let title = ProcessInfo.processInfo.environment["XS_MENU_DO"], let item = menu.items.first(where: { $0.title.hasPrefix(title) }) {
            menu.performActionForItem(at: menu.index(of: item))
            logTestState("☰ did \(title)")
        }
        // Where the selected row is on screen (top-left origin), for a real right click.
        let list = content ? contentPane.table : table
        let r = list.rect(ofRow: list.selectedRow)
        if let w = list.window, list.selectedRow >= 0, let top = NSScreen.screens.first?.frame.maxY {
            let p = w.convertPoint(toScreen: list.convert(NSPoint(x: r.midX, y: r.midY), to: nil))
            let point = "rowpoint \(Int(p.x)) \(Int(top - p.y))\n"
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(point.utf8)); try? h.close() }
        }
    }

    private func logShownHeight() {
        guard let path = ProcessInfo.processInfo.environment["XS_TYPE_LOG"] else { return }
        let line = "⎋ shown body=\(bodyHeight) text=\(field.stringValue) rows=\(rows.count)\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
        logTestState("⎋ settled")
    }

    private func logTestState(_ step: String) {
        guard let path = ProcessInfo.processInfo.environment["XS_TYPE_LOG"] else { return }
        // After the search started by this step has delivered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            let focus = panel.firstResponder === table ? "list" : panel.firstResponder is NSTextView ? "input" : "other"
            let ql = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
            let preview = mode == .content ? " selected=\(contentPane.selected?.name ?? "-") preview=\(contentPane.preview.title.stringValue)|\(contentPane.preview.position.stringValue) hitVisible=\(contentPane.preview.currentHitVisible) clipX=\(contentPane.preview.clipOriginX) positioning=\(contentPane.preview.isPositioning)" : ""
            let line = "\(step)\(preview) body=\(bodyHeight) focus=\(focus) row=\(table.selectedRow) text=\(field.stringValue) scope=\(scopeChip.isHidden ? "-" : scopeChip.title) quicklook=\(ql) active=\(NSApp.isActive) panelKey=\(panel.isKeyWindow) qlKey=\(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isKeyWindow) filters=\(filters.arrangedSubviews.count) rows=\(rows.count)\n"
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
        }
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
        // ⌫ in an empty field removes the “内容” token (back to name mode), like deleting a
        // Spotlight filter token.
        if selector == #selector(NSResponder.deleteBackward(_:)) && field.stringValue.isEmpty {
            if scope != nil { setScope(nil); return true }
            if mode == .content { switchMode(.name); return true }
        }
        if mode == .content {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                contentPane.moveSelection(1)
                if !contentPane.hits.isEmpty { panel.makeFirstResponder(contentPane.table) }
                return true
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
        case #selector(NSResponder.moveDown(_:)):
            // The list takes the keys from here on: space previews, ↑ on the first row comes back.
            moveSelection(1)
            if !rows.isEmpty { panel.makeFirstResponder(table) }
            return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activate(.open); return true
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        case #selector(NSResponder.insertTab(_:)):
            if scopeToSelection() { return true }
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
        case (.command, "w", _) where quickLookVisible: QLPreviewPanel.shared().orderOut(nil); return true
        case (.command, "1", _): switchMode(.name); return true
        case (.command, "2", _): switchMode(.content); return true
        case (.command, _, 36), (.command, _, 76):
            if mode == .content {
                if let h = contentPane.selected { openReader(h, at: max(0, contentPane.preview.currentHit)) }
            } else {
                activate(.reveal)
            }
            return true
        case (.command, "g", _) where mode == .content: contentPane.preview.goNext(); return true
        case ([.command, .shift], "g", _) where mode == .content, ([.command, .shift], "G", _) where mode == .content:
            contentPane.preview.goPrev(); return true
        case (.command, ",", _): hide(); openSettings?(); return true
        case (.command, "/", _): showSyntaxHelp(); return true
        case (.command, "d", _), (.command, "D", _): toggleFavorite(); return true
        case (.command, _, 51):
            // ⌘⌫ trashes the selected result; with nothing selected it edits the input as usual.
            guard currentTarget() != nil else { return false }
            trashSelected()
            return true
        case (.command, "e", _), (.command, "E", _): expandToFullWindow(); return true
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

    private enum Action { case open, reveal }

    private func activate(_ action: Action) {
        guard let item = selectedItem else { return }
        let url = URL(fileURLWithPath: item.path)
        guard FileManager.default.fileExists(atPath: item.path) else {
            toast(L("文件已不存在，索引会自动更新"))
            return
        }
        usage?.recordOpen(path: item.path, fileId: item.fileId)
        hide()
        if action == .open { NSWorkspace.shared.openInBackground(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: Context menu

    /// Right click: the clicked row becomes the selection (the actions work on it), then the
    /// menu for that kind of result is built.
    private func contextMenu(content: Bool, row: Int) -> NSMenu? {
        let menu = NSMenu()
        fillMenu(menu, content: content, row: row)
        menu.delegate = menuCloser
        return menu.items.isEmpty ? nil : menu
    }

    /// Takes the keyboard back for the launcher when a context menu closes and the panel stays.
    private lazy var menuCloser = MenuCloser { [weak self] in
        DispatchQueue.main.async {
            guard let self, self.panel.isVisible, !(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible) else { return }
            self.panel.makeKey()
        }
    }

    private func fillMenu(_ menu: NSMenu, content: Bool, row: Int) {
        menu.removeAllItems()
        let list = content ? contentPane.table : table
        guard row >= 0 else { return }
        if !content && isGroup(row) { return }
        let wasSelected = list.selectedRow == row
        if !wasSelected { list.selectRowIndexes([row], byExtendingSelection: false) }
        panel.makeFirstResponder(list)
        guard let target = content ? contentTarget() : nameTarget() else { return }
        var actions = ResultMenu.Actions(
            open: { [weak self] in
                guard let self else { return }
                if content { if let h = contentPane.selected { openContent(h, reveal: false) } } else { activate(.open) }
            },
            reveal: { [weak self] in
                guard let self else { return }
                if content { if let h = contentPane.selected { openContent(h, reveal: true) } } else { activate(.reveal) }
            },
            read: nil,
            quickLook: { [weak self] in
                // Wait for the context menu to close.
                DispatchQueue.main.async { self?.quickLookFromKeyEvent() }
            },
            toggleFavorite: { [weak self] in self?.toggleFavorite() },
            trash: { [weak self] in self?.trashSelected() },
            removeRecent: { [weak self] in
                guard let self else { return }
                usage?.remove(path: target.path)
                toast(L("已从最近打开中移除"))
                runSearch()
            },
            toast: { [weak self] in self?.toast($0) },
            willLeave: { [weak self] in
                guard let self else { return }
                usage?.recordOpen(path: target.path, fileId: currentTarget()?.fileId)
                hide()
            })
        if content, let reindex, let h = contentPane.selected, !h.isMember {
            actions.reindex = { [weak self] in
                reindex([Int64(h.fileId)]) { n in self?.toast(n > 0 ? L("已加入重新索引队列") : L("这个文件不在内容索引范围内")) }
            }
        }
        if content {
            // The occurrence shown in the preview, when the preview is already of this row.
            actions.read = { [weak self] in
                guard let self, let h = contentPane.selected else { return }
                openReader(h, at: wasSelected ? max(0, contentPane.preview.currentHit) : 0)
            }
        }
        ResultMenu.build(menu, for: target, actions: actions)
    }

    private func nameTarget() -> ResultMenu.Target? {
        guard let item = selectedItem else { return nil }
        let exists = FileManager.default.fileExists(atPath: item.path)
        let kind: ResultMenu.Target.Kind = !exists ? .missing : item.kind == .app ? .app : item.kind == .folder ? .folder : .file
        let name = (item.path as NSString).lastPathComponent
        return ResultMenu.Target(kind: kind, path: item.path, name: name, isFavorite: usage?.isFavorite(path: item.path) ?? false,
                                 isRecent: item.group == .recents, copyPathText: item.path)
    }

    private func contentTarget() -> ResultMenu.Target? {
        guard let h = contentPane.selected else { return nil }
        let exists = FileManager.default.fileExists(atPath: h.path)
        let kind: ResultMenu.Target.Kind = !exists ? .missing : h.isMember ? .member : .file
        return ResultMenu.Target(kind: kind, path: h.path, name: h.name, isFavorite: usage?.isFavorite(path: h.path) ?? false,
                                 canRead: true, copyPathText: h.key)
    }

    @objc private func doubleClicked() {
        if table.clickedRow >= 0 { activate(.open) }
    }

    private func showSyntaxHelp() {
        let pop = NSPopover()
        pop.behavior = .transient
        let view = SyntaxHelpView(sections: Self.syntaxHelp(mode: mode, syntax: Preferences.shared.querySyntax),
                                  footer: L("可在 设置 → 搜索语法 中开关各项语法。"))
        // Same tinted glass as the launcher, so the sheet reads like the result list in both
        // appearances (the popover's own material came out a pale grey under dim text).
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: view.frame.size))
        glass.style = .regular
        glass.tintColor = Theme.panelTint
        glass.contentView = view
        let vc = NSViewController()
        vc.view = glass
        vc.preferredContentSize = view.frame.size
        pop.contentViewController = vc
        pop.contentSize = view.frame.size
        pop.show(relativeTo: field.bounds, of: field, preferredEdge: .maxY)
        syntaxPopover = pop
    }

    /// ⌘/ cheat sheet; switched-off syntax is marked (ARCHITECTURE §12).
    static func syntaxHelp(mode: Preferences.Mode, syntax: QuerySyntax) -> [SyntaxHelpView.Section] {
        typealias Row = SyntaxHelpView.Row
        var query: [Row] = [
            Row(example: L("报告 2024"), text: mode == .name ? L("文件名同时含“报告”和“2024”，顺序不限") : L("正文同时含“报告”和“2024”，顺序不限")),
            Row(example: L("\"年度 报告\""), text: L("引号内整体当作一个词，空格也算")),
            Row(example: L("合同 | 协议"), text: L("含其中任一个"), enabled: syntax.operators),
            Row(example: L("合同 -草稿"), text: L("排除含“草稿”的"), enabled: syntax.operators),
            Row(example: L("(合同 | 协议) 2026"), text: L("括号分组：先算括号里的"), enabled: syntax.operators),
        ]
        if mode == .name {
            query += [
                Row(example: L("*.pdf  报告?.docx"), text: L("通配符：* 任意多个字符（不跨目录），? 恰好一个字符"), enabled: syntax.wildcards),
                Row(example: L("**/合同/*.pdf"), text: L("含 / 时匹配完整路径，** 可跨目录"), enabled: syntax.wildcards),
                Row(example: "regex:^\\d+\\.txt$", text: L("正则匹配文件名（含 / 时匹配路径）"), enabled: syntax.regex),
            ]
        } else {
            query += [
                Row(example: L("\"合同 金额\"~10"), text: L("两个词相距不超过 10 个字，顺序不限"), enabled: syntax.proximity),
                Row(example: "regex:HT-\\d{4}", text: L("正则匹配正文；需含 3 字节以上的固定文字，或加 dir: / ext:"), enabled: syntax.regex),
            ]
        }
        var filters = [Row(example: L("dir:~/文稿"), text: mode == .name ? L("只在这个目录里找，可写多个；也可只写目录名 dir:合同/2024") : L("只在这个目录里找（完整路径），可写多个")),
                       Row(example: "ext:pdf;docx", text: L("只看这些扩展名"))]
        if mode == .name { filters.append(Row(example: L("kind:文件夹"), text: L("按类别：文件夹 / 应用 / pdf / doc / 图片 …"))) }
        if mode == .content { filters.append(Row(example: L("name:验收;报告"), text: L("文件名含其中任一；多个 name: 须同时满足"))) }
        filters += [Row(example: "size:>10mb", text: L("按大小：> >= < <=、1m..10m、empty")),
                    Row(example: "dm:today", text: L("按修改时间：today / 本周 / 7d / 2024-05 / >=2025"))]
        return [SyntaxHelpView.Section(title: mode == .name ? L("名称模式语法") : L("内容模式语法"), rows: query),
                SyntaxHelpView.Section(title: L("过滤条件"), rows: filters)]
    }

    // MARK: Quick Look

    private func previewEnded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            // As when summoned: the panel takes the keyboard without activating anything.
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.mode == .content ? self.contentPane.table : self.table)
        }
    }

    /// Quick Look waits for the preview before it shows only when a key press opens it (the
    /// event being handled is a key down); opened from a menu click it waited out its timeout
    /// and faded in an empty panel first. The menu opens it from a key event of its own.
    private func quickLookFromKeyEvent() {
        let code: UInt16 = 0xFFFF  // no real key
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                       isARepeat: false, keyCode: code) else { toggleQuickLook(); return }
        if quickLookMonitor == nil {
            quickLookMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == code else { return event }
                MainActor.assumeIsolated { self?.toggleQuickLook() }
                return nil
            }
        }
        NSApp.postEvent(e, atStart: false)
    }

    private var quickLookMonitor: Any?

    private var quickLookVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Esc: closes Quick Look first, then the launcher.
    private func cancel() {
        // One layer per Esc: cheat sheet, Quick Look, the typed query, then the launcher.
        // `isShown` stays true while the popover animates out, so the reference is dropped at
        // once: otherwise a quick second Esc only closed the closing popover again.
        if let pop = syntaxPopover {
            syntaxPopover = nil
            if pop.isShown { pop.close(); return }
        }
        if quickLookVisible { QLPreviewPanel.shared().orderOut(nil); return }
        if !field.stringValue.isEmpty {
            field.stringValue = ""
            panel.makeFirstResponder(field)
            runSearch()
            return
        }
        hide()
    }

    /// The launcher never activates XSearch, so the app in front stays in front. Quick Look's own
    /// panel activates its app, and in an app that is not in front ordering it in handed the
    /// keyboard back to that other app: space, Esc and ⌘W went there. Non-activating like the
    /// launcher, the preview takes the keyboard itself (QuickLookKeyboard closes it) and the
    /// launcher takes it back when it closes.
    private func toggleQuickLook() {
        let ql = QLPreviewPanel.shared()!
        if ql.isVisible { ql.orderOut(nil); return }
        refreshPreviewURL()
        guard previewURL != nil else { return }
        panel.makeKey()
        panel.makeFirstResponder(mode == .content ? contentPane.table : table)
        ql.styleMask.insert(.nonactivatingPanel)
        ql.updateController()
        ql.orderFront(nil)
    }

    /// Quick Look calls its data source on the main thread; the URL is mirrored here for it.
    nonisolated(unsafe) private var previewURL: NSURL?

    func tableViewSelectionDidChange(_ notification: Notification) { refreshPreviewURL() }

    /// The selected result of the current list (an archive member has no file of its own).
    private func refreshPreviewURL() {
        if mode == .content {
            previewURL = contentPane.selected.flatMap { $0.isMember ? nil : URL(fileURLWithPath: $0.path) as NSURL }
        } else {
            previewURL = selectedItem.map { URL(fileURLWithPath: $0.path) as NSURL }
        }
    }

    /// ↑ ↓ keep moving through the list while the panel is up.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event != nil, event.type == .keyDown else { return false }
        nonisolated(unsafe) let event = event!  // Quick Look delivers synchronously on the main thread.
        return MainActor.assumeIsolated {
            if QuickLookKeyboard.closeIfRequested(event, panel: panel) { return true }
            let code = event.keyCode
            guard code == 125 || code == 126 else { return false }
            if mode == .content {
                contentPane.moveSelection(code == 125 ? 1 : -1)
                refreshPreviewURL()
                panel.reloadData()
            } else {
                moveSelection(code == 125 ? 1 : -1)
            }
            return true
        }
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
        setAccessibilityLabel(L("过滤条件 ") + text)
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
        Theme.rule.setFill()
        bounds.fill()
    }
}

/// Geometry of the Spotlight-style shell.
enum Shell {
    /// Default and name search; content mode widens to `contentWidth`.
    static let width: CGFloat = 640
    static let bar: CGFloat = 56
    /// Glass shapes closer than this melt together.
    static let mergeDistance: CGFloat = 12
    /// One radius for the bar and the expanded panel, as in Spotlight: the corners never change
    /// shape while the height animates.
    static let cornerRadius: CGFloat = 26
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

/// NSMenuDelegate that only reports the menu closing.
final class MenuCloser: NSObject, NSMenuDelegate {
    private let closed: () -> Void
    init(_ closed: @escaping () -> Void) { self.closed = closed }
    func menuDidClose(_ menu: NSMenu) { closed() }
}

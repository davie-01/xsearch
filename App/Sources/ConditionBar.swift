import AppKit
import XSearchCore

/// One button of the full window's condition bar: “位置 全部 ⌄”. Its width is fixed, so a chosen
/// value fills the same box (truncated, the whole value in the tooltip) and the ✕ that clears it
/// takes the chevron's slot: setting a condition never moves its neighbours.
@MainActor
final class ConditionPill: NSView {
    let label: String
    private let width: CGFloat
    var value = "" { didSet { update() } }
    /// Set: drawn in the accent colour, with ✕ to clear.
    var isOn = false { didSet { update() } }
    var onOpen: (() -> Void)?
    var onClear: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var hoveringClear = false { didSet { needsDisplay = true } }

    init(label: String, width: CGFloat) {
        self.label = label
        self.width = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: 26) }

    private func update() {
        toolTip = label + L("：") + value
        setAccessibilityLabel(label + " " + value)
        needsDisplay = true
    }

    private var endRect: NSRect { NSRect(x: bounds.maxX - 23, y: (bounds.height - 15) / 2, width: 15, height: 15) }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12.5, yRadius: 12.5)
        let accent = NSColor.controlAccentColor
        if isOn {
            accent.withAlphaComponent(hovering ? 0.24 : 0.17).setFill()
            shape.fill()
        } else {
            if hovering {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                shape.fill()
            }
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        let font = NSFont.systemFont(ofSize: 12.5)
        let labelText = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: isOn ? accent : NSColor.labelColor])
        let labelWidth = ceil(labelText.size().width)
        let y = (bounds.height - ceil(labelText.size().height)) / 2
        labelText.draw(at: NSPoint(x: 10, y: y))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let valueText = NSAttributedString(string: value, attributes: [
            .font: isOn ? NSFont.systemFont(ofSize: 12.5, weight: .medium) : font,
            .foregroundColor: isOn ? accent : NSColor.secondaryLabelColor, .paragraphStyle: style,
        ])
        let valueX = 10 + labelWidth + 5
        valueText.draw(with: NSRect(x: valueX, y: y, width: max(0, endRect.minX - 4 - valueX), height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let end = endRect
        if isOn, onClear != nil {
            if hoveringClear {
                accent.withAlphaComponent(0.22).setFill()
                NSBezierPath(ovalIn: end).fill()
            }
            symbol("xmark", size: 8, color: accent).draw(in: centered(NSSize(width: 8, height: 8), in: end))
        } else {
            symbol("chevron.down", size: 8, color: isOn ? accent : .tertiaryLabelColor).draw(in: centered(NSSize(width: 9, height: 6), in: end))
        }
    }

    private func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }

    private func centered(_ size: NSSize, in r: NSRect) -> NSRect {
        NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; hoveringClear = false }
    override func mouseMoved(with event: NSEvent) {
        hoveringClear = isOn && endRect.insetBy(dx: -3, dy: -3).contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if isOn, let onClear, endRect.insetBy(dx: -3, dy: -3).contains(p) { onClear() } else { onOpen?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}

/// Building blocks of the condition popovers: a titled column with a 清除 / 完成 footer.
@MainActor
enum ConditionForm {
    static func title(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 12, weight: .semibold)
        t.textColor = .secondaryLabelColor
        return t
    }

    static func hint(_ s: String, width: CGFloat) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 11.5)
        t.textColor = .tertiaryLabelColor
        t.preferredMaxLayoutWidth = width
        return t
    }

    /// A borderless button in the accent colour, for secondary actions (清除, 选择其他文件夹…).
    static func link(_ s: String, target: AnyObject?, action: Selector?) -> NSButton {
        let b = NSButton(title: s, target: target, action: action)
        b.isBordered = false
        b.contentTintColor = .controlAccentColor
        b.font = .systemFont(ofSize: 12.5)
        return b
    }

    static func field(_ placeholder: String, width: CGFloat) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.font = .systemFont(ofSize: 13)
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = spacing
        s.alignment = .centerY
        return s
    }

    static func column(_ views: [NSView], spacing: CGFloat = 4) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    /// The popover's view controller: content above a separator, `left` and 完成 below it.
    static func controller(width: CGFloat, content: [NSView], left: NSView, done: NSButton) -> NSViewController {
        let line = NSBox()
        line.boxType = .separator
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = row([left, spacer, done])
        let stack = column(content + [line, footer], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
            line.widthAnchor.constraint(equalToConstant: width - 32), footer.widthAnchor.constraint(equalToConstant: width - 32),
        ])
        let vc = NSViewController()
        vc.view = root
        return vc
    }
}

/// What the result area shows when there is nothing to list: content search before typing (its
/// scope and examples to click) and “no results” (the likely reasons, each with a next step).
@MainActor
final class ResultPlaceholderView: NSView {
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `symbol` above `title` and `message`, then any extra views (examples, reasons).
    func show(symbol: String?, title: String, message: String?, extras: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.symbolConfiguration = .init(pointSize: 34, weight: .light)
            icon.contentTintColor = .tertiaryLabelColor
            stack.addArrangedSubview(icon)
        }
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 17, weight: .semibold)
        t.alignment = .center
        t.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(t)
        if let message {
            let m = NSTextField(wrappingLabelWithString: message)
            m.font = .systemFont(ofSize: 13)
            m.textColor = .secondaryLabelColor
            m.alignment = .center
            m.preferredMaxLayoutWidth = 460
            stack.addArrangedSubview(m)
        }
        for (i, v) in extras.enumerated() {
            if i == 0 { stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!) }
            stack.addArrangedSubview(v)
        }
    }

    /// A clickable example: the query in monospace over what it means.
    static func example(_ query: String, _ meaning: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: target, action: action)
        b.bezelStyle = .push
        b.setButtonType(.momentaryPushIn)
        let text = NSMutableAttributedString(string: query, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "  " + meaning, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
        b.attributedTitle = text
        b.identifier = .init(query)
        b.setAccessibilityLabel(query + " " + meaning)
        return b
    }

    /// A grey box of reasons, each a sentence with an optional action button after it.
    static func reasons(_ items: [(String, NSButton?)]) -> NSView {
        // A custom box: its fill follows the appearance (a layer colour would not).
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 10
        box.fillColor = NSColor.labelColor.withAlphaComponent(0.05)
        box.contentViewMargins = .zero
        let col = ConditionForm.column(items.map { text, button in
            let t = NSTextField(wrappingLabelWithString: text)
            t.font = .systemFont(ofSize: 13)
            t.preferredMaxLayoutWidth = 420
            return button.map { ConditionForm.row([t, $0], spacing: 4) } ?? t
        }, spacing: 6)
        col.translatesAutoresizingMaskIntoConstraints = false
        let content = box.contentView!
        content.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), col.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            col.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), col.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        return box
    }
}

/// A “在结果中” step in its popover: “不含 草稿 ⓧ”. Only the ✕ removes it, so a stray click on
/// the text keeps the step; hovering the ✕ gives it a round backdrop in the tag's own colour.
@MainActor
final class StepTag: NSView {
    private let text: String
    private let negative: Bool
    var onRemove: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var hoveringClose = false { didSet { needsDisplay = true } }

    init(text: String, negative: Bool) {
        self.text = text
        self.negative = negative
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("移除 %@", text))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private var tint: NSColor { negative ? .systemRed : .labelColor }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: tint])
    }

    override var intrinsicContentSize: NSSize { NSSize(width: min(360, ceil(attributed.size().width) + 38), height: 24) }

    private var closeRect: NSRect { NSRect(x: bounds.maxX - 22, y: (bounds.height - 16) / 2, width: 16, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(hovering ? 0.13 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let s = NSMutableAttributedString(attributedString: attributed)
        s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
        let h = ceil(s.size().height)
        s.draw(with: NSRect(x: 10, y: (bounds.height - h) / 2, width: bounds.width - 38, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let circle = closeRect
        if hoveringClose {
            tint.withAlphaComponent(0.2).setFill()
            NSBezierPath(ovalIn: circle).fill()
        }
        // The ✕ in the text's colour: secondary at rest, full strength when it can be clicked.
        let color = hoveringClose ? tint : tint.withAlphaComponent(0.55)
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(.init(paletteColors: [color]))
        let x = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        x.draw(in: NSRect(x: circle.midX - 4, y: circle.midY - 4, width: 8, height: 8))
    }

    private func overClose(_ event: NSEvent) -> Bool {
        closeRect.insetBy(dx: -3, dy: -3).contains(convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() { addCursorRect(closeRect.insetBy(dx: -3, dy: -3), cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; hoveringClose = false }
    override func mouseMoved(with event: NSEvent) {
        hoveringClose = overClose(event)
        toolTip = hoveringClose ? L("移除这一步") : nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if overClose(event) { onRemove?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onRemove?()
        return true
    }
}

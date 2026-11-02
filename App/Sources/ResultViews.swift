import AppKit
import XSearchCore

/// Spotlight-style selection: a soft translucent rounded rect; text keeps its normal colors.
final class ResultRowView: NSTableRowView {
    var isGroup = false

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isGroup, selectionHighlightStyle != .none else { return }
        Theme.selectionFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 10, yRadius: 10).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

final class GroupHeaderView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = Theme.groupFont
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class ResultCellView: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let path = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        for v in [icon, name, path, meta] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.lineBreakMode = .byTruncatingMiddle
        path.lineBreakMode = .byTruncatingMiddle
        // One line each: a long name wrapped and pushed the path line out of the row.
        for f in [name, path] {
            f.maximumNumberOfLines = 1
            f.usesSingleLineMode = true
            f.cell?.wraps = false
        }
        path.font = Theme.pathFont
        path.textColor = .secondaryLabelColor
        meta.font = Theme.metaFont
        meta.textColor = .secondaryLabelColor
        meta.alignment = .right
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)
        meta.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: meta.leadingAnchor, constant: -12),
            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            path.trailingAnchor.constraint(lessThanOrEqualTo: meta.leadingAnchor, constant: -12),
            meta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            meta.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: ResultItem, terms: [String]) {
        // System file icons (apps show their own icon), as in Spotlight. NSWorkspace caches them.
        icon.image = NSWorkspace.shared.icon(forFile: item.path)
        path.stringValue = PathUtil.abbreviate((item.path as NSString).deletingLastPathComponent, home: NSHomeDirectory())
        meta.stringValue = item.meta
        name.attributedStringValue = Self.highlight(item.name, terms: terms)
        setAccessibilityLabel("\(item.name)，\(path.stringValue)，\(item.meta)")
    }

    /// Matched parts semibold in the accent color (§4.2).
    static func highlight(_ text: String, terms: [String]) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: [.font: Theme.nameFont, .foregroundColor: NSColor.labelColor])
        let ns = text as NSString
        for term in terms where !term.isEmpty {
            // Display-only approximation of the folded-key match; the index decides membership.
            let r = ns.range(of: term, options: [.caseInsensitive, .widthInsensitive])
            guard r.location != NSNotFound else { continue }
            s.addAttributes([.font: Theme.nameMatchFont, .foregroundColor: NSColor.controlAccentColor], range: r)
        }
        return s
    }
}

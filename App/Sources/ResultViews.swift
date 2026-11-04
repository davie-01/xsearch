import AppKit
import XSearchCore

/// Spotlight-style selection: a soft translucent rounded rect; text keeps its normal colors.
final class ResultRowView: NSTableRowView {
    var isGroup = false

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isGroup, selectionHighlightStyle != .none else { return }
        Theme.selectionFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 14, yRadius: 14).fill()
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
    /// “2026/10/13 10:06 · 2.6 MB · ” before the folder, as in Spotlight; it stays whole while
    /// the folder is shortened in the middle.
    let details = NSTextField(labelWithString: "")
    let path = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        for v in [icon, name, details, path, meta] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.lineBreakMode = .byTruncatingTail
        path.lineBreakMode = .byTruncatingMiddle
        // One line each: a long name wrapped and pushed the path line out of the row.
        for f in [name, path] {
            f.maximumNumberOfLines = 1
            f.usesSingleLineMode = true
            f.cell?.wraps = false
        }
        path.font = Theme.pathFont
        path.textColor = .secondaryLabelColor
        details.font = Theme.pathFont
        details.textColor = .secondaryLabelColor
        details.setContentCompressionResistancePriority(.required, for: .horizontal)
        details.setContentHuggingPriority(.required, for: .horizontal)
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
            details.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            details.firstBaselineAnchor.constraint(equalTo: path.firstBaselineAnchor),
            path.leadingAnchor.constraint(equalTo: details.trailingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            path.trailingAnchor.constraint(lessThanOrEqualTo: meta.leadingAnchor, constant: -12),
            meta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            meta.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Modification date and size (files); apps and missing files show only where they are.
    static func details(_ item: ResultItem) -> String {
        guard item.kind != .app, item.mtime > 0 else { return "" }
        var parts = [Theme.fullDate(item.mtime)]
        if item.kind != .folder { parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) }
        return parts.joined(separator: " · ") + " · "
    }

    func configure(_ item: ResultItem, terms: [String]) {
        // System file icons (apps show their own icon), as in Spotlight. NSWorkspace caches them.
        icon.image = item.kind == .app ? appIcon(atPath: item.path) : NSWorkspace.shared.icon(forFile: item.path)
        path.stringValue = PathUtil.abbreviate((item.path as NSString).deletingLastPathComponent, home: NSHomeDirectory())
        details.stringValue = Self.details(item)
        meta.stringValue = item.meta
        name.attributedStringValue = Self.highlight(item.name, terms: terms)
        setAccessibilityLabel(L("%@，%@%@，%@", "\(item.name)", "\(details.stringValue)", "\(path.stringValue)", "\(item.meta)"))
    }

    /// Matched parts semibold in the accent color (§4.2).
    static func highlight(_ text: String, terms: [String]) -> NSAttributedString {
        // An attributed string brings its own line breaking: a long name ends in "…".
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let s = NSMutableAttributedString(string: text, attributes: [.font: Theme.nameFont, .paragraphStyle: style, .foregroundColor: NSColor.labelColor])
        let ns = text as NSString
        for term in terms where !term.isEmpty {
            // Display-only approximation of the folded-key match; the index decides membership.
            let r = ns.range(of: term, options: [.caseInsensitive, .widthInsensitive])
            guard r.location != NSNotFound else { continue }
            s.addAttributes([.font: Theme.nameMatchFont, .foregroundColor: Theme.matchText], range: r)
        }
        return s
    }
}

import AppKit
import XSearchCore

/// The ⌘/ cheat sheet: grouped cards like a Settings list, each row an example (code chip) and
/// its meaning, rows divided by hairlines only. Laid out by hand for a fixed width: as a wrapping
/// label left to Auto Layout, the popover over the glass panel came out a narrow empty strip.
final class SyntaxHelpView: NSView {
    struct Row {
        var example: String
        var text: String
        var enabled = true
    }

    struct Section {
        var title: String
        var rows: [Row]
    }

    private struct Placed {
        var chip: NSRect
        var example: NSAttributedString
        var text: NSAttributedString
        var textRect: NSRect
    }

    private static let width: CGFloat = 470
    private static let margin: CGFloat = 16
    private static let exampleColumn: CGFloat = 156
    private static let rowInset = NSSize(width: 10, height: 8)

    private var titles: [(NSAttributedString, NSRect)] = []
    private var cards: [NSRect] = []
    private var rows: [Placed] = []
    /// Hairlines between rows: y and the card they belong to.
    private var separators: [(y: CGFloat, card: NSRect)] = []
    private var footer: (NSAttributedString, NSRect)?

    override var isFlipped: Bool { true }

    init(sections: [Section], footer note: String) {
        super.init(frame: .zero)
        let cardWidth = Self.width - 2 * Self.margin
        let textX = Self.margin + Self.rowInset.width + Self.exampleColumn
        let textWidth = Self.width - Self.margin - Self.rowInset.width - textX
        var y: CGFloat = 14
        for section in sections {
            let title = NSAttributedString(string: section.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let titleHeight = ceil(title.size().height)
            titles.append((title, NSRect(x: Self.margin + 4, y: y, width: cardWidth, height: titleHeight)))
            y += titleHeight + 6
            let cardTop = y
            for (i, row) in section.rows.enumerated() {
                if i > 0 { separators.append((y, .zero)) }
                let example = NSAttributedString(string: row.example, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: row.enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                ])
                let text = NSMutableAttributedString(string: row.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: row.enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                ])
                if !row.enabled {
                    text.append(NSAttributedString(string: L("（已关闭，按普通字符搜索）"), attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.systemOrange,
                    ]))
                }
                let exampleSize = example.size()
                let chip = NSSize(width: ceil(exampleSize.width) + 10, height: ceil(exampleSize.height) + 4)
                let textHeight = ceil(text.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
                let height = max(chip.height, textHeight) + 2 * Self.rowInset.height
                // Chip and text are both centred in the row, so a wrapped description keeps its
                // example level with the middle of the text instead of its first line.
                rows.append(Placed(chip: NSRect(x: Self.margin + Self.rowInset.width - 3, y: y + (height - chip.height) / 2, width: chip.width, height: chip.height),
                                   example: example, text: text,
                                   textRect: NSRect(x: textX, y: y + (height - textHeight) / 2, width: textWidth, height: textHeight)))
                y += height
            }
            let card = NSRect(x: Self.margin, y: cardTop, width: cardWidth, height: y - cardTop)
            cards.append(card)
            for i in separators.indices where separators[i].card == .zero { separators[i].card = card }
            y += 14
        }
        let note = NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor])
        let noteHeight = ceil(note.size().height)
        footer = (note, NSRect(x: Self.margin + 4, y: y - 4, width: cardWidth, height: noteHeight))
        setFrameSize(NSSize(width: Self.width, height: y - 4 + noteHeight + 14))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        // Resolved at draw time, so light and dark appearances both follow the system.
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        for card in cards { NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill() }
        let hairline = 1 / max(1, window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setFill()
        for s in separators {
            NSRect(x: s.card.minX + Self.rowInset.width, y: s.y - hairline / 2, width: s.card.width - Self.rowInset.width, height: hairline).fill()
        }
        for row in rows {
            // Drawing text can change the current color: set it for each chip.
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: row.chip, xRadius: 4, yRadius: 4).fill()
            row.example.draw(at: NSPoint(x: row.chip.minX + 5, y: row.chip.minY + 2))
            row.text.draw(with: row.textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        for (title, rect) in titles { title.draw(in: rect) }
        if let (note, rect) = footer { note.draw(in: rect) }
    }
}

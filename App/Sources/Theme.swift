import AppKit
import XSearchCore

/// Values from docs/design/UI-SPEC.md §2. System semantic colors where the spec allows them,
/// so dark appearance follows automatically (§2.3).
@MainActor
enum Theme {
    static let panelWidth: CGFloat = 720
    static let maxListHeight: CGFloat = 470
    static let rowHeight: CGFloat = 52
    static let groupHeight: CGFloat = 26
    static let panelRadius: CGFloat = 26

    static let inputFont = NSFont.systemFont(ofSize: 26)
    static let nameFont = NSFont.systemFont(ofSize: 15)
    static let nameMatchFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let pathFont = NSFont.systemFont(ofSize: 12)
    static let metaFont = NSFont.systemFont(ofSize: 11.5)
    static let groupFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let hintFont = NSFont.systemFont(ofSize: 11.5)
    static let badgeFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)

    static var accent: NSColor { .controlAccentColor }
    static let secondary = NSColor.secondaryLabelColor
    static let tertiary = NSColor.tertiaryLabelColor

    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Result type block colors (§2.1).
    static func blockColor(_ kind: FileKind) -> NSColor {
        switch kind {
        case .pdf: hex(0xC2332B)
        case .word: hex(0x2B5BB8)
        case .sheet: hex(0x1E7A45)
        case .ofd: hex(0x8A4FB3)
        case .folder: hex(0x3D7FD6)
        case .app: hex(0x1D1D1F)
        default: hex(0x4A4A4F)
        }
    }

    static let warnBackground = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? hex(0xFFF4DB).withAlphaComponent(0.2) : hex(0xFFF4DB) }
    /// `surface.sidebar` (UI-SPEC §2): settings, full window and reader sidebars.
    static let sidebar = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0x232326) : hex(0xF4F4F6) }
    static let warnText = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? hex(0xFFD98A) : hex(0x6B4A00) }
    /// Spotlight-style translucent fills that read on top of glass in both appearances.
    static var selectionFill: NSColor { NSColor.labelColor.withAlphaComponent(0.11) }
    static var capsuleFill: NSColor { NSColor.labelColor.withAlphaComponent(0.08) }

    static let chipBackground = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.12) : hex(0xEFEFF2) }

    /// "今天 14:20" / "10月28日" / "2024/3/1" (§9: spaces between Chinese and digits where needed).
    nonisolated static func shortDate(_ seconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) { f.dateFormat = "今天 HH:mm" } else if cal.isDateInYesterday(date) { f.dateFormat = "昨天 HH:mm" }
        else if cal.component(.year, from: date) == cal.component(.year, from: Date()) { f.dateFormat = "M月d日" } else { f.dateFormat = "yyyy/M/d" }
        return f.string(from: date)
    }

    nonisolated static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

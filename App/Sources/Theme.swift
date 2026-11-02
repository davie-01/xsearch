import AppKit
import os
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
    /// Over the launcher's glass: strong enough for text over any window behind it.
    static let panelTint = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.black.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.62) }
    static var selectionFill: NSColor { NSColor.labelColor.withAlphaComponent(0.11) }
    static var capsuleFill: NSColor { NSColor.labelColor.withAlphaComponent(0.08) }

    static let chipBackground = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.12) : hex(0xEFEFF2) }

    /// "今天 14:20" / "10月28日" / "2024/3/1" (§9: spaces between Chinese and digits where needed).
    /// Creating a formatter is the slow part (a result list asks for one per row).
    nonisolated private static let formatters = OSAllocatedUnfairLock(initialState: [String: DateFormatter]())

    nonisolated private static func formatter(_ format: String) -> DateFormatter {
        formatters.withLock { cache in
            if let f = cache[format] { return f }
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = format
            cache[format] = f
            return f
        }
    }

    nonisolated static func shortDate(_ seconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let cal = Calendar.current
        let format: String
        if cal.isDateInToday(date) { format = "今天 HH:mm" } else if cal.isDateInYesterday(date) { format = "昨天 HH:mm" }
        else if cal.component(.year, from: date) == cal.component(.year, from: Date()) { format = "M月d日" } else { format = "yyyy/M/d" }
        return formatter(format).string(from: date)
    }

    nonisolated static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// Dev: XS_PERF_LOG=/path appends main-thread timings (performance investigations).
enum PerfLog {
    nonisolated(unsafe) static let handle: FileHandle? = ProcessInfo.processInfo.environment["XS_PERF_LOG"].flatMap { path in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
    /// Records main-thread stalls longer than 40 ms (a 10 ms timer that arrives late).
    @MainActor static func watchMainThread() {
        guard handle != nil else { return }
        var last = Date()
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let now = Date()
            let gap = now.timeIntervalSince(last) * 1000
            if gap > 40 { note(String(format: "STALL %.0f ms", gap)) }
            last = now
        }
    }

    static func note(_ s: String) {
        guard let handle else { return }
        handle.write(Data((String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + s + "\n").utf8))
    }
}

/// Brings one of XSearch's normal windows in front of every app. Activation is cooperative
/// (macOS 14+): a request made while the status menu closes is often declined, which leaves
/// the window above other inactive apps but below the active one. `orderFrontRegardless`
/// raises it anyway; the activation is retried once the menu is gone.
@MainActor
func bringToFront(_ window: NSWindow?) {
    guard let window else { return }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    DispatchQueue.main.async {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

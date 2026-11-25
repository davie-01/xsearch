import AppKit
import os
import XSearchCore

/// Values from docs/design/UI-SPEC.md §2. System semantic colors where the spec allows them,
/// so dark appearance follows automatically (§2.3).
@MainActor
enum Theme {
    static let panelWidth: CGFloat = 640
    static let maxListHeight: CGFloat = 470
    static let rowHeight: CGFloat = 56
    static let groupHeight: CGFloat = 28
    static let panelRadius: CGFloat = 26

    static let inputFont = NSFont.systemFont(ofSize: 26)
    /// Result rows measured from Spotlight on macOS 26 (name ≈ 17 pt, second line ≈ 14.5 pt).
    static let nameFont = NSFont.systemFont(ofSize: 17)
    static let nameMatchFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
    static let pathFont = NSFont.systemFont(ofSize: 14.5)
    static let metaFont = NSFont.systemFont(ofSize: 12)
    static let groupFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let hintFont = NSFont.systemFont(ofSize: 12)
    /// Spotlight's filter pills: 26 pt high, 15 pt text, a faint fill.
    static let pillFont = NSFont.systemFont(ofSize: 15)
    /// Dark: a faint light fill; light: white pills with grey text (Spotlight, measured).
    static let pillFill = NSColor(name: nil) { isDark($0) ? NSColor.white.withAlphaComponent(0.085) : NSColor.white.withAlphaComponent(0.9) }
    static let pillText = NSColor(name: nil) { isDark($0) ? NSColor.white.withAlphaComponent(0.75) : NSColor.black.withAlphaComponent(0.5) }
    /// The hairline under the input.
    static let rule = NSColor(name: nil) { isDark($0) ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08) }

    nonisolated static func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
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
    /// Over the launcher's glass: Spotlight's glass is nearly plain in both appearances and keeps
    /// the colour of what lies behind it (measured against its screenshots over the same dark
    /// window). The former veils (light grey in dark mode, white 50% in light mode) washed the
    /// panel out. Dark keeps a thin dark veil to hold text over bright windows.
    static let panelTint = NSColor(name: nil) { isDark($0) ? NSColor(white: 0.1, alpha: 0.12) : NSColor.white.withAlphaComponent(0.05) }
    /// Matched text over the grey glass: the accent alone is too dark on a selected row, so it
    /// is lifted toward white in dark mode (and deepened a little in light mode).
    static let matchText = NSColor(name: nil) { a in
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let dark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (dark ? accent.blended(withFraction: 0.55, of: .white) : accent.blended(withFraction: 0.15, of: .black)) ?? accent
    }
    /// Spotlight's selected row: a bright veil on dark glass, a faint grey on light glass.
    static let selectionFill = NSColor(name: nil) { isDark($0) ? NSColor.white.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.085) }
    static var capsuleFill: NSColor { NSColor.labelColor.withAlphaComponent(0.14) }

    static let chipBackground = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.12) : hex(0xEFEFF2) }

    /// "今天 14:20" / "10月28日" / "2024/3/1" (§9: spaces between Chinese and digits where needed).
    /// Creating a formatter is the slow part (a result list asks for one per row).
    nonisolated private static let formatters = OSAllocatedUnfairLock(initialState: [String: DateFormatter]())

    nonisolated private static func formatter(_ format: String) -> DateFormatter {
        formatters.withLock { cache in
            if let f = cache[format] { return f }
            let f = DateFormatter()
            f.locale = Loc.locale
            f.dateFormat = format
            cache[format] = f
            return f
        }
    }

    nonisolated static func shortDate(_ seconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let cal = Calendar.current
        let format: String
        if cal.isDateInToday(date) { format = L("今天 HH:mm") } else if cal.isDateInYesterday(date) { format = L("昨天 HH:mm") }
        else if cal.component(.year, from: date) == cal.component(.year, from: Date()) { format = L("M月d日") } else { format = L("yyyy/M/d") }
        return formatter(format).string(from: date)
    }

    /// Date and time in full, as Spotlight puts it before a result's folder.
    nonisolated static func fullDate(_ seconds: Int64) -> String {
        formatter(L("yyyy/M/d HH:mm")).string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
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

/// An app's own icon. Some system apps in /Applications (Safari) are links into
/// /System/Cryptexes, and a link's icon carries the alias arrow; Spotlight shows the app's.
@MainActor
func appIcon(atPath path: String) -> NSImage {
    fileIcon(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
}

/// A file's system icon in the icon style chosen in System Settings → Appearance (macOS 26),
/// as Spotlight and the Dock show it: `NSWorkspace` always hands back the default (light) style.
@MainActor
func fileIcon(atPath path: String) -> NSImage {
    let image = NSWorkspace.shared.icon(forFile: path)
    guard IconStyle.wantsDark else { return image }
    return IconStyle.dark(image) ?? image
}

/// Dark icons through IconServices (private): the `ISIcon` behind an `NSWorkspace` image is
/// rendered again with a dark descriptor. Every step falls back to the image as it came.
@MainActor
enum IconStyle {
    /// By the icon's digest: files of one type share a single rendering.
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    /// `AppleIconAppearanceTheme`: "RegularDark", "ClearDark", "…Automatic", absent = light.
    static var wantsDark: Bool {
        guard let theme = UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme") else { return false }
        if theme.hasSuffix("Dark") { return true }
        if theme.hasSuffix("Automatic") { return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
        return false
    }

    private typealias InitSize = @convention(c) (AnyObject, Selector, CGSize, CGFloat) -> AnyObject?
    private typealias Render = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<CGImage>?
    private typealias Prepare = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
    private static let render = NSSelectorFromString("CGImageForDescriptor:")
    /// Loads the image (custom icons, generated ones) and says whether it is still a placeholder.
    private static let prepare = NSSelectorFromString("prepareImageForDescriptor:")
    private static let size: CGFloat = 64

    /// One dark descriptor (64 pt @2x), made once.
    private static let descriptor: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_LAZY) != nil,
              let cls = NSClassFromString("ISImageDescriptor") as? NSObject.Type else { return nil }
        let initSize = NSSelectorFromString("initWithSize:scale:")
        guard cls.instancesRespond(to: initSize), cls.instancesRespond(to: NSSelectorFromString("setAppearance:")),
              let mem = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let d = unsafeBitCast(cls.instanceMethod(for: initSize), to: InitSize.self)(mem, initSize, CGSize(width: size, height: size), 2) as? NSObject
        else { return nil }
        d.setValue(1, forKey: "appearance")  // 0 light, 1 dark
        return d
    }()

    static func dark(_ image: NSImage) -> NSImage? {
        guard let descriptor, let rep = image.representations.first,
              let ivar = class_getInstanceVariable(type(of: rep), "_icon"),
              let icon = object_getIvar(rep, ivar) as? NSObject, icon.responds(to: render), icon.responds(to: prepare) else { return nil }
        // No digest, no caching: an address could come back for another icon.
        let key = (icon.responds(to: NSSelectorFromString("digest")) ? icon.value(forKey: "digest") : nil).map { "\($0)" as NSString }
        if let key, let cached = cache.object(forKey: key) { return cached }
        // A placeholder (dashed square) is neither shown nor cached: the light icon draws itself.
        guard let prepared = unsafeBitCast(icon.method(for: prepare), to: Prepare.self)(icon, prepare, descriptor) as? NSObject,
              prepared.responds(to: NSSelectorFromString("placeholder")),
              (prepared.value(forKey: "placeholder") as? Bool) == false,
              let cg = unsafeBitCast(icon.method(for: render), to: Render.self)(icon, render, descriptor)?.takeUnretainedValue() else { return nil }
        let result = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        if let key { cache.setObject(result, forKey: key) }
        return result
    }
}

/// Brings one of XSearch's normal windows in front of every app. Activation is cooperative
/// (macOS 14+): a request made while the status menu closes is often declined, which leaves
/// the window above other inactive apps but below the active one. `orderFrontRegardless`
/// raises it anyway; the activation is retried once the menu is gone.
@MainActor
func bringToFront(_ window: NSWindow?) {
    guard let window else { return }
    activateXSearch()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    DispatchQueue.main.async {
        activateXSearch()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// The launcher never activates XSearch, so a window opened from it (⌘E, the reader) is opened
/// by an app that is not in front, and macOS declines a plain `activate()` then: the window
/// showed with no keyboard focus. Only the older call still takes the front for it.
@MainActor
private func activateXSearch() {
    NSApp.activate(ignoringOtherApps: true)
}

import AppKit
import XSearchCore

/// Settings → 打开方式 (ARCHITECTURE §11.3, UI-SPEC §6.4): text and code open in the chosen
/// editor at the hit's line; PDFs can open externally at the hit's page.
enum Editor: String, CaseIterable, Codable, Sendable {
    case system, vscode, cursor, sublime, xcode, textmate

    var title: String {
        switch self {
        case .system: L("默认应用")
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .sublime: "Sublime Text"
        case .xcode: "Xcode"
        case .textmate: "TextMate"
        }
    }

    var bundleID: String? {
        switch self {
        case .system: nil
        case .vscode: "com.microsoft.VSCode"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .sublime: "com.sublimetext.4"
        case .xcode: "com.apple.dt.Xcode"
        case .textmate: "com.macromates.TextMate"
        }
    }

    @MainActor var appURL: URL? {
        guard let id = bundleID else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        return self == .sublime ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.sublimetext.3") : nil
    }

    @MainActor var isInstalled: Bool { self == .system || appURL != nil }

    /// Opens `path` at `line` (1-based); false when the editor is unavailable.
    @MainActor func open(path: String, line: Int) -> Bool {
        let url = URL(fileURLWithPath: path)
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        switch self {
        case .system:
            return NSWorkspace.shared.open(url)
        case .vscode, .cursor:
            guard isInstalled, let u = URL(string: "\(self == .vscode ? "vscode" : "cursor")://file\(encoded):\(line)") else { return false }
            return NSWorkspace.shared.open(u)
        case .textmate:
            let file = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            guard isInstalled, let u = URL(string: "txmt://open?url=\(file)&line=\(line)") else { return false }
            return NSWorkspace.shared.open(u)
        case .sublime:
            guard let app = appURL else { return false }
            return run(app.appendingPathComponent("Contents/SharedSupport/bin/subl").path, ["\(path):\(line)"])
        case .xcode:
            guard isInstalled else { return false }
            return run("/usr/bin/xed", ["--line", String(line), path])
        }
    }

    private func run(_ tool: String, _ args: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        return (try? p.run()) != nil
    }
}

struct OpenWith: Codable, Sendable, Equatable {
    var editor: Editor = .system
    /// PDFs open externally at the hit's page (Skim, or Preview with Accessibility).
    var pdfAtPage = false

    init() {}

    // Field by field with defaults; an editor this version does not know falls back to the system.
    private enum CodingKeys: String, CodingKey { case editor, pdfAtPage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        editor = (try? c.decodeIfPresent(Editor.self, forKey: .editor)) ?? .system
        pdfAtPage = try c.decodeIfPresent(Bool.self, forKey: .pdfAtPage) ?? false
    }
}

@MainActor
enum Opener {
    /// Opens a content hit honouring 打开方式. `line` / `page` locate the current hit; nil
    /// falls back to the default app. Returns a message when the jump could not be made.
    @discardableResult
    static func open(path: String, line: Int?, page: Int?) -> String? {
        let prefs = Preferences.shared.openWith
        let name = (path as NSString).lastPathComponent
        if ContentType.of(name: name) == .text, prefs.editor != .system, let line {
            if prefs.editor.open(path: path, line: line) { return nil }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return L("%@ 不可用，已用默认应用打开", "\(prefs.editor.title)")
        }
        if ContentType.of(name: name) == .pdf, prefs.pdfAtPage, let page {
            return ExternalPDF.open(path: path, page: page).map { $0.title + L("。") + $0.detail }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return nil
    }
}

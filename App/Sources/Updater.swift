import AppKit
import Sparkle

/// Auto-update through Sparkle (M5). Updates are EdDSA-signed (public key in Info.plist, the
/// private key in the developer's Keychain); the feed URL is set at build time. A build
/// without a feed has updates switched off rather than failing.
@MainActor
final class Updater {
    static let shared = Updater()
    private let controller: SPUStandardUpdaterController?

    static var feedURL: String? { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String }
    var isConfigured: Bool { controller != nil }

    private init() {
        controller = Self.feedURL == nil ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?")（\(info["CFBundleVersion"] as? String ?? "?")）"
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate()
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "这个版本没有配置更新地址"
            alert.informativeText = "请到发布页下载新版 DMG 安装。"
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }
}

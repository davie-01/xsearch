import AppKit
import Sparkle
import XSearchCore

/// Auto-update through Sparkle (M5). Updates are EdDSA-signed (public key in Info.plist, the
/// private key in the developer's Keychain); the feed URL is set at build time. A build
/// without a feed has updates switched off rather than failing.
/// No scheduled checks (SUEnableAutomaticChecks is false in Info.plist, so Sparkle neither
/// schedules nor asks): one quiet check per launch when 关于 › 启动时检查更新 is on — Sparkle
/// shows something only when a new version exists — and otherwise only on 检查更新….
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
        return L("%@（%@）", info["CFBundleShortVersionString"] as? String ?? "?", info["CFBundleVersion"] as? String ?? "?")
    }

    var checksAtLaunch: Bool {
        get { Preferences.shared.checkUpdatesAtLaunch }
        set { Preferences.shared.checkUpdatesAtLaunch = newValue }
    }

    /// Called once at launch.
    func checkAtLaunchIfWanted() {
        guard let controller else { return }
        // Installs that once had scheduled checks on keep none.
        controller.updater.automaticallyChecksForUpdates = false
        if checksAtLaunch { controller.updater.checkForUpdatesInBackground() }
    }

    func checkForUpdates() {
        NSApp.activate()
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = L("这个版本没有配置更新地址")
            alert.informativeText = L("请到发布页下载新版 DMG 安装。")
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }
}

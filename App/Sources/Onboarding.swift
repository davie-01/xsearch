import AppKit
import Catalog
import ServiceManagement
import SwiftUI
import XSearchCore

/// First-launch guide (UI-SPEC §6.5): hotkey and login item, content folders (Downloads
/// recommended), optional Full Disk Access, then "按 ⌥Space 试一下".
@MainActor
final class OnboardingModel: ObservableObject {
    struct Folder: Identifiable, Equatable {
        var path: String
        var enabled: Bool
        var recommended: Bool
        var id: String { path }
    }

    @Published var step = 0
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var folders: [Folder]
    @Published var downloadsCount: Int?
    @Published var fullDiskAccess = OnboardingModel.hasFullDiskAccess()
    let hotKey: String
    var onFinish: ((ContentScope) -> Void)?
    var onTry: (() -> Void)?
    private let base: ContentScope

    static let steps = 3

    init(scope: ContentScope, hotKey: String) {
        base = scope
        self.hotKey = hotKey
        let home = NSHomeDirectory()
        var list = [Folder(path: home + "/Downloads", enabled: scope.roots(home: home).contains(home + "/Downloads"), recommended: true)]
        for f in scope.roots(home: home) where f != home + "/Downloads" { list.append(Folder(path: f, enabled: true, recommended: false)) }
        folders = list
    }

    var nextLabel: String { step == Self.steps - 1 ? "完成" : "下一步" }

    func setLaunchAtLogin(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(where: { $0.path == url.path }) {
            folders.append(Folder(path: url.path, enabled: true, recommended: false))
        }
    }

    func refreshAccess() { fullDiskAccess = Self.hasFullDiskAccess() }

    /// Protected files open only with Full Disk Access; `access()` would not tell.
    static func hasFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        for p in ["/Library/Application Support/com.apple.TCC/TCC.db", "/Library/Safari/Bookmarks.plist"] {
            let fd = open(home + p, O_RDONLY)
            if fd >= 0 { close(fd); return true }
        }
        return false
    }

    var scope: ContentScope {
        var s = base
        s.folders = folders.filter(\.enabled).map { PathUtil.abbreviate($0.path, home: NSHomeDirectory()) }
        return s
    }

    var contentSummary: String {
        let chosen = folders.filter(\.enabled)
        if chosen.isEmpty { return "未选择文件夹，可以之后在 设置 › 索引范围 中添加" }
        return chosen.map { FileManager.default.displayName(atPath: $0.path) }.joined(separator: "、") + " 正在建立，完成前已处理的文件即可搜索"
    }

    func next() {
        if step < Self.steps - 1 { step += 1 } else { onFinish?(scope); step = Self.steps }
    }

    func back() { if step > 0 { step -= 1 } }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel

    init(model: OnboardingModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 530), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "XSearch 首次启动引导"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        bringToFront(window)
    }

    /// Back from System Settings: the access state may have changed.
    func windowDidBecomeKey(_ notification: Notification) { model.refreshAccess() }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.step < OnboardingModel.steps {
                Text("第 \(model.step + 1) 步，共 \(OnboardingModel.steps) 步")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
            Group {
                switch model.step {
                case 0: hotKeyStep
                case 1: foldersStep
                case 2: accessStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(.horizontal, 44)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .frame(width: 780, height: 530)
    }

    private func title(_ s: String) -> some View {
        Text(s).font(.system(size: 26, weight: .semibold)).padding(.bottom, 10)
    }

    private func lead(_ s: String) -> some View {
        Text(s).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 22)
    }

    private var hotKeyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("按 \(model.hotKey) 随时搜索")
            lead("XSearch 常驻菜单栏。按快捷键呼出搜索框：直接输入找应用和文件；输入 in 加空格再输入文字，就在文件内容里查找。")
            Card(title: "呼出快捷键", subtitle: "可以随时在设置中修改") {
                Text(model.hotKey)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            Toggle("开机时自动启动 XSearch", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch).padding(.top, 16)
        }
    }

    private var foldersStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("在哪些文件夹里搜索内容？")
            lead("文件名会索引整个磁盘。内容索引需要读取文件，先从“下载”开始，以后可以在 设置 › 索引范围 中添加其他文件夹。")
            VStack(alignment: .leading, spacing: 8) {
                ForEach($model.folders) { $f in
                    Toggle(isOn: $f.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FileManager.default.displayName(atPath: f.path)).font(.system(size: 14, weight: .medium))
                            Text(PathUtil.abbreviate(f.path, home: NSHomeDirectory()) + (f.recommended ? " · 推荐" : ""))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            if f.recommended, let n = model.downloadsCount {
                                Text("约 \(Theme.count(n)) 个可提取的文件；完成前已处理的文件即可搜索").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Button("＋ 添加其他文件夹") { model.addFolders() }.buttonStyle(.link).padding(.top, 4)
                Text("暂不添加也可以，之后随时设置").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Text(verbatim: "支持 Word（含 .doc、WPS）、PDF、Excel、PowerPoint（含旧版 .ppt）、OFD、网页、ePub、RTF、文本和代码，以及压缩包里的这些文件。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("访问权限（可选）")
            lead("不授权也能正常使用：你选择的文件夹和大多数位置都能搜到。只有“邮件”“信息”的附件、部分 ~/Library 等受系统保护的位置需要“完全磁盘访问权限”。遇到这些位置时会再提示你。")
            Card(title: "完全磁盘访问权限", subtitle: model.fullDiskAccess ? "已授权" : "未授权：受保护的位置不会出现在结果中") {
                HStack {
                    Image(systemName: model.fullDiskAccess ? "checkmark.circle.fill" : "lock")
                        .foregroundStyle(model.fullDiskAccess ? Color.green : Color.secondary)
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Button("重新检查") { model.refreshAccess() }.buttonStyle(.link)
                }
            }
            Spacer(minLength: 12)
            Label("文件内容和搜索词只在本机处理，不会上传。", systemImage: "lock.shield").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("准备好了")
            lead("文件名索引正在建立，应用已经可以搜索。")
            Text("内容索引：\(model.contentSummary)").font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if model.step > 0 && model.step < OnboardingModel.steps {
                Button("上一步") { model.back() }.controlSize(.large)
            }
            Spacer()
            if model.step < OnboardingModel.steps {
                Button(model.nextLabel) { model.next() }.keyboardShortcut(.defaultAction).controlSize(.large)
            } else {
                Button("按 \(model.hotKey) 试一下") { model.onTry?() }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
    }
}

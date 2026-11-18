import AppKit
import Catalog
import ServiceManagement
import SwiftUI
import XSearchCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用", scope = "索引范围", syntax = "搜索语法", openWith = "打开方式", diagnostics = "诊断", privacy = "隐私与数据"  // l10n: shown through L(rawValue)
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .scope: "folder"
        case .syntax: "text.magnifyingglass"
        case .openWith: "arrow.up.forward.app"
        case .diagnostics: "stethoscope"
        case .privacy: "lock"
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var scope: NameScope
    @Published var status: NameService.Status
    @Published var hotKey: HotKey.Combo
    @Published var hotKeyError: String?
    @Published var recording = false
    @Published var summonMode: Preferences.SummonMode
    @Published var launchAtLogin: Bool
    @Published var syntax: QuerySyntax { didSet { Preferences.shared.querySyntax = syntax } }
    @Published var matchMode = Preferences.shared.matchMode { didSet { Preferences.shared.matchMode = matchMode } }
    @Published var openWith = Preferences.shared.openWith { didSet { Preferences.shared.openWith = openWith } }
    @Published var keepLastQuery = Preferences.shared.keepLastQuery { didSet { Preferences.shared.keepLastQuery = keepLastQuery } }
    @Published var showRecents = Preferences.shared.showRecents { didSet { Preferences.shared.showRecents = showRecents } }
    @Published var recentsCleared = false
    @Published var newRule = ""
    @Published var content: ContentScope
    @Published var contentStatus: ContentIndexer.Status?
    @Published var contentPaused = false
    /// Settings › 隐私与数据; nil until measured.
    @Published var storage: IndexStorage?
    @Published var storageBusy = false
    @Published var diagnosePath = ""
    @Published var diagnosis: [NameService.DiagnosisItem] = []
    @Published var language = UILanguage.chosen { didSet { UILanguage.chosen = language } }
    /// The language this run started with; another choice applies after a restart.
    let launchLanguage = UILanguage.chosen
    weak var delegate: AppDelegate?
    var names: NameService

    init(names: NameService, delegate: AppDelegate) {
        self.names = names
        self.delegate = delegate
        scope = Preferences.shared.nameScope
        status = names.status
        hotKey = Preferences.shared.hotKey
        summonMode = Preferences.shared.summonMode
        launchAtLogin = SMAppService.mainApp.status == .enabled
        syntax = Preferences.shared.querySyntax
        content = delegate.currentContentScope
        contentStatus = delegate.contentStatus
        contentPaused = delegate.contentIndexingPaused
    }

    func refresh() {
        status = names.status
        contentStatus = delegate?.contentStatus
        contentPaused = delegate?.contentIndexingPaused ?? false
    }

    func setContentPaused(_ paused: Bool) {
        delegate?.setContentIndexingPaused(paused)
        contentPaused = paused
    }

    /// 重新扫描 a folder of the settings (`~` paths), or everything (立即更新).
    func rescan(_ folder: String?) {
        let home = NSHomeDirectory()
        delegate?.rescan(folder.map { $0 == "~" ? home : $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 })
        refresh()
    }

    /// 查看失败的文件: the list, and what the last 重新提取 did.
    @Published var failed: [NameService.FailedExtraction] = []
    @Published var failedNote: String?

    func loadFailed() { failed = names.failedExtractions() }

    /// Files being extracted again from the list; their rows say so until the indexer is done.
    @Published var retrying = Set<Int64>()
    private var retryTimer: Timer?

    /// Extract again (nil: every failed file). Their rows show progress; once no task of theirs
    /// is left, the list reloads and says how it went: most failures (encrypted, damaged) fail
    /// again, and without that answer the list just looked unchanged.
    func retryFailed(_ ids: [Int64]?) {
        let targets = Set(ids ?? failed.map(\.id))
        guard !targets.isEmpty, retrying.isEmpty else { return }
        retrying = targets
        failedNote = contentPaused ? L("内容索引已暂停，恢复后才会重新提取。") : L("正在重新提取 %@ 个文件…", "\(targets.count)")
        let done: @MainActor @Sendable (Int) -> Void = { [weak self] _ in
            self?.refresh()
            self?.watchRetry()
        }
        if let ids { delegate?.reindex(ids, done: done) } else { delegate?.retryFailedExtractions(done: done) }
    }

    private func watchRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkRetry() }
        }
    }

    private func checkRetry() {
        guard !retrying.isEmpty, !contentPaused else { return }
        guard names.pendingContent(retrying).isEmpty else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        let targets = retrying
        retrying = []
        loadFailed()
        refresh()
        let still = targets.intersection(failed.map(\.id)).count
        let fixed = targets.count - still
        failedNote = fixed == 0 ? L("%@ 个文件重新提取后仍然失败，原因没有变化。", "\(still)")
            : still == 0 ? L("%@ 个文件已重新提取成功，正文可以搜索了。", "\(fixed)")
            : L("%@ 个已成功，%@ 个仍然失败。", "\(fixed)", "\(still)")
    }

    /// The sheet closed: stop watching (the indexer carries on by itself).
    func stopWatchingRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
        retrying = []
    }

    func measureStorage() {
        delegate?.measureStorage { [weak self] s in self?.storage = s }
    }

    func clearContentIndex() {
        storageBusy = true
        delegate?.clearContentIndex { [weak self] in
            self?.storageBusy = false
            self?.refresh()
            self?.measureStorage()
        }
    }

    func clearAllIndexes() {
        delegate?.clearAllIndexes()
        refresh()
        // The old files are moved aside and removed in the background.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.measureStorage() }
    }

    func removeLeftovers() {
        storageBusy = true
        delegate?.removeLeftovers { [weak self] in
            self?.storageBusy = false
            self?.measureStorage()
        }
    }

    func commitContent() { delegate?.applyContentScope(content) }

    func addContentFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("添加")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let p = PathUtil.abbreviate(url.path, home: NSHomeDirectory())
            if !content.folders.contains(p) { content.folders.append(p) }
        }
        commitContent()
    }

    func runDiagnosis() {
        let path = diagnosePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        let names = self.names
        DispatchQueue.global(qos: .userInitiated).async {
            let result = names.diagnose(path)
            DispatchQueue.main.async { self.diagnosis = result }
        }
    }

    func commitScope() { delegate?.applyScope(scope) }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("添加")
        guard panel.runModal() == .OK else { return }
        let home = NSHomeDirectory()
        for url in panel.urls {
            let p = PathUtil.abbreviate(url.path, home: home)
            if !scope.folders.contains(p) { scope.folders.append(p) }
        }
        commitScope()
    }

    func addExtraFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.prompt = L("添加")
        guard panel.runModal() == .OK else { return }
        let home = NSHomeDirectory()
        for url in panel.urls {
            let p = PathUtil.abbreviate(url.path, home: home)
            if !scope.extraFolders.contains(p) { scope.extraFolders.append(p) }
        }
        commitScope()
    }

    /// Quits and opens the app again once this process is gone (the new language applies).
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            hotKeyError = nil
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private var monitor: Any?

    /// The monitor sees keys for every XSearch window: recording ends with the Settings window
    /// (closed, or another window such as the launcher takes the keyboard) and with its page.
    func startRecording() {
        stopRecording()
        recording = true
        hotKeyError = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = HotKey.Combo.carbonModifiers(event.modifierFlags)
            if event.keyCode == 53 && mods == 0 { self.stopRecording(); return nil }  // Esc cancels
            guard mods != 0 else { self.hotKeyError = L("需要至少一个修饰键（⌘ ⌥ ⌃ ⇧）"); return nil }
            let combo = HotKey.Combo(keyCode: UInt32(event.keyCode), modifiers: mods)
            if self.delegate?.changeHotKey(combo) == true {
                self.hotKey = combo
                self.hotKeyError = nil
            } else {
                self.hotKeyError = L("%@ 已被其他应用占用，请换一个组合", "\(combo.display)")
            }
            self.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    var names: NameService {
        get { model.names }
        set { model.names = newValue; model.refresh() }
    }

    init(names: NameService, delegate: AppDelegate) {
        model = SettingsModel(names: names, delegate: delegate)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 660), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("XSearch 设置")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.setContentSize(NSSize(width: 940, height: 660))
        window.center()
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) { model.stopRecording() }
    func windowDidResignKey(_ notification: Notification) { model.stopRecording() }

    required init?(coder: NSCoder) { fatalError() }

    func show(tab: SettingsTab) {
        model.tab = tab
        model.refresh()
        showWindow(nil)
        bringToFront(window)
    }

    func refresh() { model.refresh() }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    Button { model.tab = tab } label: {
                        Label(L(tab.rawValue), systemImage: tab.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6).padding(.horizontal, 10)
                            .background(model.tab == tab ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            // The whole row reacts, not only the label's glyphs (a transparent
                            // background is not hit-testable: clicks beside the text did nothing).
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    // The selection highlight shows where you are; no keyboard focus ring.
                    .focusEffectDisabled()
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 200)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.tab {
                    case .general: GeneralPane(model: model)
                    case .scope: ScopePane(model: model)
                    case .syntax: SyntaxPane(model: model)
                    case .openWith: OpenWithPane(model: model)
                    case .diagnostics: DiagnosticsPane(model: model)
                    case .privacy: PrivacyPane(model: model)
                    }
                    Color.clear.frame(height: 1).id("pane-end")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Dev: XS_SETTINGS_BOTTOM=1 scrolls to the end of the pane (screenshots).
            .onAppear {
                if ProcessInfo.processInfo.environment["XS_SETTINGS_BOTTOM"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { withAnimation { proxy.scrollTo("pane-end", anchor: .bottom) } }
                }
            }
            }
        }
        .frame(width: 940, height: 660)
    }
}

struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
    }
}

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Text(L("通用")).font(.system(size: 20, weight: .semibold))
        Card(title: L("呼出快捷键"), subtitle: L("点击后按下新的组合键；与其他应用冲突时会提示")) {
            HStack {
                Button(model.recording ? L("请按下组合键…（Esc 取消）") : model.hotKey.display) {
                    model.recording ? model.stopRecording() : model.startRecording()
                }
                .controlSize(.large)
                if let e = model.hotKeyError { Text(e).font(.system(size: 12)).foregroundStyle(.orange) }
            }
        }
        .onDisappear { model.stopRecording() }
        Card(title: L("语言"), subtitle: L("切换后重新启动 XSearch 生效")) {
            HStack {
                // Each language in its own words, as in System Settings.
                Picker("", selection: $model.language) {
                    Text(L("跟随系统")).tag(UILanguage.system)
                    Text(verbatim: "简体中文").tag(UILanguage.zh)  // l10n: a language in its own words
                    Text(verbatim: "English").tag(UILanguage.en)
                }
                .labelsHidden()
                .fixedSize()
                if model.language != model.launchLanguage {
                    Button(L("立即重启")) { model.relaunch() }
                }
            }
        }
        Card(title: L("开机自动启动")) {
            Toggle(L("登录时打开 XSearch"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
        }
        Card(title: L("软件更新"), subtitle: L("当前版本 %@", "\(Updater.shared.version)")) {
            HStack {
                Toggle(L("自动检查更新"), isOn: Binding(get: { Updater.shared.automaticallyChecks }, set: { Updater.shared.automaticallyChecks = $0; model.objectWillChange.send() }))
                    .toggleStyle(.switch)
                    .disabled(!Updater.shared.isConfigured)
                Spacer()
                Button(L("检查更新…")) { Updater.shared.checkForUpdates() }
            }
            if !Updater.shared.isConfigured {
                Text(L("这个版本没有配置更新地址，新版需要手动下载安装。")).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        Card(title: L("历史记录"), subtitle: L("只保存在本机")) {
            Toggle(L("呼出时保留上次的搜索内容"), isOn: $model.keepLastQuery).toggleStyle(.switch)
            Toggle(L("输入框为空时显示最近打开的文件"), isOn: $model.showRecents).toggleStyle(.switch)
            HStack {
                Button(L("清除最近打开记录")) {
                    model.delegate?.clearRecents()
                    model.recentsCleared = true
                }
                if model.recentsCleared { Text(L("已清除")).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Text(L("收藏不受影响。按使用频率排序的依据也会一并清除。")).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        Card(title: L("呼出时的模式")) {
            Picker("", selection: Binding(get: { model.summonMode }, set: { model.summonMode = $0; Preferences.shared.summonMode = $0 })) {
                Text(L("总是名称模式")).tag(Preferences.SummonMode.alwaysName)
                Text(L("记住上次的模式")).tag(Preferences.SummonMode.rememberLast)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

struct SyntaxPane: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Text(L("搜索语法")).font(.system(size: 20, weight: .semibold))
        Card(title: L("语法开关"), subtitle: L("关闭后对应符号按普通字符搜索；按 ⌘/ 查看速查")) {
            Toggle(isOn: $model.syntax.operators) { Text(L("运算符　甲 | 乙、-草稿、(甲 | 乙) 丙　两种模式")) }
            Toggle(isOn: $model.syntax.wildcards) { Text(L("通配符　*.pdf、报告?.docx、**/合同/*.pdf　名称模式")) }
            Toggle(isOn: $model.syntax.regex) { Text(L("正则　regex:^\\d+\\.txt$")) }
            Toggle(isOn: $model.syntax.proximity) { Text(L("邻近查询　\"合同 金额\"~10　内容模式")) }
        }
        Card(title: L("内容匹配模式"), subtitle: L("只影响内容搜索；完整窗口里可以临时切换")) {
            Picker("", selection: $model.matchMode) {
                Text(L("宽松（默认）：不区分大小写、全角半角和空白差异")).tag("loose")
                Text(L("区分大小写：其余与宽松相同")).tag("caseSensitive")
                Text(L("严格原文：逐字符比较，不做任何归一化")).tag("strict")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

struct OpenWithPane: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Text(L("打开方式")).font(.system(size: 20, weight: .semibold))
        Card(title: L("文本与代码"), subtitle: L("在内容模式下打开时，用所选编辑器跳到命中所在的行")) {
            Picker("", selection: $model.openWith.editor) {
                ForEach(Editor.allCases, id: \.self) { e in
                    Text(e.isInstalled ? e.title : e.title + L("（未安装）")).tag(e).disabled(!e.isInstalled)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        Card(title: "PDF", subtitle: L("在内容模式下打开时，用外部阅读器跳到命中所在的页")) {
            Toggle(L("打开到命中页"), isOn: $model.openWith.pdfAtPage)
            Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: ExternalPDF.skimID) != nil
                 ? L("已安装 Skim：直接跳页。")
                 : L("使用“预览”：需要在 系统设置 → 隐私与安全性 → 辅助功能 中允许 XSearch，否则打开第 1 页。安装 Skim 后不需要这项权限。"))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

struct ScopePane: View {
    @ObservedObject var model: SettingsModel

    var statusLine: String {
        let st = model.status
        let mem = ByteCountFormatter.string(fromByteCount: Int64(st.memoryBytes), countStyle: .memory)
        switch st.phase {
        case .starting: return L("正在打开…")
        case .scanning: return L("正在建立 · %@ 项", "\(Theme.count(st.count))")
        case .ready: return L("%@ 项 · 内存约 %@ · ", Theme.count(st.count), mem) + (st.watching ? L("实时更新") : L("未实时更新，正在重试"))
        case .failed(let m): return L("出错：%@", "\(m)")
        }
    }

    var body: some View {
        Text(L("索引范围")).font(.system(size: 20, weight: .semibold))
        Text(L("文件名和内容分别设置。同一个文件只扫描、提取一次。")).font(.system(size: 12.5)).foregroundStyle(.secondary)
        Card(title: L("文件名索引"), subtitle: statusLine) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("文件变化会实时更新。如果怀疑漏掉了变化（例如在其他电脑上改过外置盘），可以立即重新核对全部范围。"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button(L("立即更新")) { model.rescan(nil) }
            }
            Picker("", selection: Binding(get: { model.scope.wholeDisk }, set: { model.scope.wholeDisk = $0; model.commitScope() })) {
                Text(L("整盘")).tag(true)
                Text(L("指定文件夹")).tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if !model.scope.wholeDisk {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.scope.folders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder")
                            Text(folder).font(.system(size: 13))
                            Spacer()
                            Button(L("重新扫描")) { model.rescan(folder) }.buttonStyle(.borderless)
                            Button(L("移除")) {
                                model.scope.folders.removeAll { $0 == folder }
                                model.commitScope()
                            }
                            .foregroundStyle(.red)
                            .buttonStyle(.borderless)
                        }
                    }
                    if model.scope.folders.isEmpty { Text(L("还没有文件夹。")).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Button(L("＋ 添加")) { model.addFolders() }.buttonStyle(.borderless)
                }
            }
            // Specified folders already take any folder; the list stays visible while it has entries.
            if model.scope.wholeDisk || !model.scope.extraFolders.isEmpty {
                Divider()
                Text(L("额外包含的文件夹")).font(.system(size: 13, weight: .medium))
                Text(L("被排除规则挡住、但仍想按名称搜到的文件夹，例如 ~/Library 里的微信文件。外层的排除规则对它不起作用，它里面的其他排除规则照常生效。"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.scope.extraFolders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder")
                            Text(folder).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(L("重新扫描")) { model.rescan(folder) }.buttonStyle(.borderless)
                            Button(L("移除")) {
                                model.scope.extraFolders.removeAll { $0 == folder }
                                model.commitScope()
                            }
                            .foregroundStyle(.red)
                            .buttonStyle(.borderless)
                        }
                    }
                    if model.scope.extraFolders.isEmpty { Text(L("没有。")).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Button(L("＋ 添加")) { model.addExtraFolders() }.buttonStyle(.borderless)
                }
            }
            Divider()
            Text(L("排除规则")).font(.system(size: 13, weight: .medium))
            Text(L("路径（/System、~/Library）、名称（node_modules）或模式（*.log、**/build/**）。")).font(.system(size: 11.5)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.scope.excludes, id: \.self) { rule in
                    HStack {
                        Text(rule).font(.system(size: 12.5, design: .monospaced))
                        Spacer()
                        Button(L("移除")) {
                            model.scope.excludes.removeAll { $0 == rule }
                            model.commitScope()
                        }
                        .foregroundStyle(.red)
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField(L("＋ 添加规则"), text: $model.newRule)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onSubmit(addRule)
                    Button(L("添加"), action: addRule).disabled(model.newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Divider()
            Toggle(L("包含隐藏文件"), isOn: Binding(get: { model.scope.includeHidden }, set: { model.scope.includeHidden = $0; model.commitScope() }))
                .toggleStyle(.switch)
            Toggle(L("包含应用包内部"), isOn: Binding(get: { model.scope.includePackageContents }, set: { model.scope.includePackageContents = $0; model.commitScope() }))
                .toggleStyle(.switch)
            Text(L("修改后在后台重新核对范围，期间可以继续搜索。外置盘和网络盘在后续版本支持。")).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        ContentCard(model: model)
    }

    private func addRule() {
        let rule = model.newRule.trimmingCharacters(in: .whitespaces)
        guard !rule.isEmpty, !model.scope.excludes.contains(rule) else { return }
        model.scope.excludes.append(rule)
        model.newRule = ""
        model.commitScope()
    }
}

struct PrivacyPane: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmRebuild = false
    @State private var confirmClearContent = false
    @State private var confirmClearAll = false

    private func size(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…"
    }

    private func row(_ title: String, _ detail: String, _ bytes: Int64?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(size(bytes)).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        Text(L("隐私与数据")).font(.system(size: 20, weight: .semibold))
        Card(title: L("数据位置")) {
            Text(L("文件名和搜索词只在本机处理。索引保存在 ~/Library/Application Support/XSearch（目录 0700，文件 0600），日志中不记录搜索词。"))
                .font(.system(size: 12.5))
            Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([Preferences.dataDirectory]) }
        }
        Card(title: L("存储占用")) {
            VStack(alignment: .leading, spacing: 8) {
                row(L("文件名索引"), L("文件目录数据库和文件名快照"), model.storage?.names)
                row(L("内容索引"), L("提取出的正文和检索数据"), model.storage?.content)
                row(L("个人数据"), L("最近打开和收藏；清除索引时保留"), model.storage?.personal)
                HStack(alignment: .firstTextBaseline) {
                    row(L("临时与残留文件"), L("重建留下的旧文件、打开压缩包成员和解包的临时文件"), model.storage?.leftovers)
                    Button(L("清理")) { model.removeLeftovers() }
                        .disabled(model.storageBusy || (model.storage?.leftovers ?? 0) == 0)
                }
                Divider()
                HStack {
                    Text(L("合计")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(size(model.storage?.total)).font(.system(size: 13, weight: .medium).monospacedDigit())
                }
            }
        }
        .onAppear { model.measureStorage() }
        Card(title: L("清除与重建"), subtitle: L("最近打开、收藏和设置始终保留。")) {
            VStack(alignment: .leading, spacing: 12) {
                action(L("清除内容索引…"), L("立即删除内容索引并暂停内容索引；恢复后重新提取全部内容文件。"), destructive: true) { confirmClearContent = true }
                    .confirmationDialog(L("清除内容索引？"), isPresented: $confirmClearContent) {
                        Button(L("清除"), role: .destructive) { model.clearContentIndex() }
                    } message: {
                        Text(L("将删除 %@ 的内容索引并暂停内容索引。恢复内容索引后会重新提取全部内容文件。", size(model.storage?.content)))
                    }
                action(L("重建内容索引…"), L("在后台重新提取全部内容文件；完成前继续使用旧索引，完成后删除旧索引并回收空间。"), destructive: false) {
                    model.delegate?.rebuildContentIndex()
                }
                action(L("重建文件名索引…"), L("删除文件名索引并重新扫描，内容会一并重新提取。"), destructive: true) { confirmRebuild = true }
                    .confirmationDialog(L("重建文件名索引？"), isPresented: $confirmRebuild) {
                        Button(L("重建"), role: .destructive) { model.delegate?.rebuildNameIndex() }
                    } message: {
                        Text(L("重新扫描期间，已处理的部分可以立即搜索。"))
                    }
                action(L("清除全部索引…"), L("删除文件名索引和内容索引并暂停内容索引；文件名索引会立即重新扫描，内容在恢复后重新提取。"), destructive: true) { confirmClearAll = true }
                    .confirmationDialog(L("清除全部索引？"), isPresented: $confirmClearAll) {
                        Button(L("清除"), role: .destructive) { model.clearAllIndexes() }
                    } message: {
                        Text(L("将删除 %@ 的索引文件。名称搜索需要文件名索引，它会立即重新扫描；内容索引保持暂停，恢复后重新提取。", size(model.storage.map { $0.names + $0.content })))
                    }
            }
            .disabled(model.storageBusy)
        }
    }

    private func action(_ title: String, _ detail: String, destructive: Bool, _ run: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            Button(title, action: run).foregroundStyle(destructive ? .red : .primary)
        }
    }
}

struct ContentCard: View {
    @ObservedObject var model: SettingsModel
    @State private var showFailed = false

    var statusLine: String {
        guard let st = model.contentStatus else { return L("内容索引未启动") }
        var parts = [L("%@ 个文件", "\(Theme.count(st.indexed))")]
        if model.contentPaused { parts.insert(L("已暂停"), at: 0) }
        if st.lastError != nil { parts.append(L("写入暂时出错，正在自动重试")) }
        if st.pending > 0 { parts.append(L("待处理 %@", "\(Theme.count(st.pending))")) }
        if st.failed > 0 { parts.append(L("%@ 个提取失败", "\(st.failed)")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card(title: L("内容索引"), subtitle: L("只提取下面的文件夹；网络盘默认不建内容索引。") + "  " + statusLine) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.content.folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder).font(.system(size: 13))
                        Spacer()
                        Button(L("重新扫描")) { model.rescan(folder) }.buttonStyle(.borderless)
                        Button(L("移除")) {
                            model.content.folders.removeAll { $0 == folder }
                            model.commitContent()
                        }
                        .foregroundStyle(.red)
                        .buttonStyle(.borderless)
                    }
                }
                if model.content.folders.isEmpty { Text(L("还没有文件夹，内容搜索暂不可用。")).font(.system(size: 12)).foregroundStyle(.secondary) }
                Button(L("＋ 添加文件夹")) { model.addContentFolders() }.buttonStyle(.borderless)
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.contentPaused ? L("内容索引已暂停") : L("内容索引运行中")).font(.system(size: 13, weight: .medium))
                    Text(model.contentPaused ? L("文件变化会先记下，恢复后再提取；已有内容照常可以搜索。") : L("暂停后不再提取文件内容，已有内容照常可以搜索；文件名索引不受影响。"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.contentPaused ? L("恢复内容索引") : L("暂停内容索引")) { model.setContentPaused(!model.contentPaused) }
            }
            if let failed = model.contentStatus?.failed, failed > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("%@ 个文件提取失败", "\(failed)")).font(.system(size: 13, weight: .medium))
                        Text(L("这些文件的正文搜不到。可以查看每个文件失败的原因。"))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("查看失败的文件…")) {
                        model.failedNote = nil
                        model.loadFailed()
                        showFailed = true
                    }
                }
                .sheet(isPresented: $showFailed) { FailedExtractionsView(model: model) }
            }
            Divider()
            Text(L("提取的文件类型")).font(.system(size: 13, weight: .medium))
            // A grid that wraps: twelve types do not fit one row.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach([(ContentType.text, L("文本 / 代码")), (.pdf, "PDF"), (.docx, L("Word（docx）")), (.doc, L("Word（doc）")), (.wps, L("WPS 文字")), (.sheet, "Excel"), (.slide, "PowerPoint"), (.ofd, "OFD"), (.web, L("网页 HTML")), (.ebook, "ePub"), (.rtf, "RTF"), (.archive, L("压缩包"))], id: \.0) { type, label in
                    Toggle(isOn: Binding(get: { model.content.types.contains(type) }, set: { on in
                        if on { model.content.types.insert(type) } else { model.content.types.remove(type) }
                        model.commitContent()
                    })) { Text(verbatim: label).lineLimit(1) }
                    .toggleStyle(.checkbox)
                }
            }
            Text(L("WPS 表格、演示分别归入 Excel、PowerPoint；压缩包只读一层；图片 OCR 在 M6")).font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack {
                Text(L("单文件上限")).font(.system(size: 13))
                Picker("", selection: Binding(get: { model.content.maxFileBytes }, set: { model.content.maxFileBytes = $0; model.commitContent() })) {
                    Text("50 MB").tag(UInt64(50 << 20))
                    Text("100 MB").tag(UInt64(100 << 20))
                    Text("200 MB").tag(UInt64(200 << 20))
                }
                .labelsHidden()
                .frame(width: 110)
            }
        }
    }
}

struct DiagnosticsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Text(L("诊断：为什么搜不到")).font(.system(size: 20, weight: .semibold))
        Text(L("输入或把文件拖到这里，逐项检查它在索引中的状态。")).font(.system(size: 12.5)).foregroundStyle(.secondary)
        HStack {
            TextField(L("文件路径，例如 ~/Downloads/合同.docx"), text: $model.diagnosePath)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.runDiagnosis() }
            Button(L("检查")) { model.runDiagnosis() }.keyboardShortcut(.defaultAction)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    model.diagnosePath = url.path
                    model.runDiagnosis()
                }
            }
            return true
        }
        if !model.diagnosis.isEmpty {
            Card(title: (model.diagnosePath as NSString).lastPathComponent) {
                ForEach(Array(model.diagnosis.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.level == .ok ? "checkmark.circle.fill" : item.level == .warning ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(item.level == .ok ? Color(nsColor: Theme.hex(0x1E7A45)) : item.level == .warning ? .orange : Color(nsColor: Theme.hex(0xC2410C)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Loc.display(item.label)).font(.system(size: 13, weight: .medium))
                            Text(Loc.display(item.detail)).font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

/// Settings › 内容索引 › 查看失败的文件: which content files could not be extracted and why, with
/// the usual next steps. Re-extraction lives here, not on the card: rescanning a folder does not
/// retry a failed file that has not changed.
struct FailedExtractionsView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<Int64>()

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Loc.locale
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var selected: [NameService.FailedExtraction] { model.failed.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("提取失败的文件（%@）", "\(model.failed.count)")).font(.system(size: 17, weight: .semibold))
            Text(L("解析超时、解析器崩溃、占用内存过多或格式无法识别的文件会被跳过，它们的正文搜不到。文件修改后会自动重新提取；修好文件或更新 XSearch 后，也可以在这里重新提取。"))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Table(model.failed, selection: $selection) {
                TableColumn(L("文件")) { f in
                    VStack(alignment: .leading, spacing: 1) {
                        Text((f.path as NSString).lastPathComponent).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                        Text(PathUtil.abbreviate((f.path as NSString).deletingLastPathComponent, home: NSHomeDirectory()))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .help(f.path)
                }
                .width(min: 180, ideal: 270)
                TableColumn(L("原因")) { f in
                    if model.retrying.contains(f.id) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(model.contentPaused ? L("等待恢复内容索引") : L("正在重新提取…")).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    } else {
                        let reason = ExtractionFailure(f.reason)
                        Text(reason.summary).font(.system(size: 12)).lineLimit(2).help(reason.detail ?? reason.summary)
                    }
                }
                .width(min: 160, ideal: 220)
                TableColumn(L("大小")) { f in
                    Text(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
                .width(min: 64, ideal: 72, max: 90)
                TableColumn(L("修改时间")) { f in
                    Text(Self.dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval(f.mtime)))).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .width(min: 112, ideal: 118, max: 140)
            }
            .contextMenu(forSelectionType: Int64.self) { ids in
                Button(L("在访达中显示")) { reveal(ids) }
                Button(L("重新提取")) { model.retryFailed(Array(ids)) }.disabled(!model.retrying.isEmpty)
                Button(L("复制路径")) { copy(model.failed.filter { ids.contains($0.id) }) }
            } primaryAction: { ids in reveal(ids) }
            .frame(minHeight: 260)
            if let note = model.failedNote {
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Button(L("在访达中显示")) { reveal(selection) }.disabled(selection.isEmpty)
                Button(L("重新提取所选")) { model.retryFailed(Array(selection)) }.disabled(selection.isEmpty || !model.retrying.isEmpty)
                Button(L("复制列表")) { copy(selected.isEmpty ? model.failed : selected) }.disabled(model.failed.isEmpty)
                    .help(L("复制文件路径和原因，便于反馈问题"))
                Spacer()
                Button(L("全部重新提取")) { model.retryFailed(nil) }.disabled(model.failed.isEmpty || !model.retrying.isEmpty)
                // Nothing here to cancel or confirm: one 关闭, for Return and Esc alike.
                Button(L("关闭")) { dismiss() }.keyboardShortcut(.defaultAction)
                    .background(Button("") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false))
            }
            // ⌘W closes the sheet as it would a window (a sheet has no close button of its own).
            .background(Button("") { dismiss() }.keyboardShortcut("w", modifiers: .command).opacity(0).allowsHitTesting(false))
        }
        .padding(20)
        .frame(width: 820, height: 480)
        .onDisappear { model.stopWatchingRetry() }
    }

    private func reveal(_ ids: Set<Int64>) {
        let urls = model.failed.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    private func copy(_ items: [NameService.FailedExtraction]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map { $0.path + "\t" + ExtractionFailure($0.reason).report }.joined(separator: "\n"), forType: .string)
    }
}

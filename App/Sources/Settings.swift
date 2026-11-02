import AppKit
import Catalog
import ServiceManagement
import SwiftUI
import XSearchCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用", scope = "索引范围", syntax = "搜索语法", openWith = "打开方式", diagnostics = "诊断", privacy = "隐私与数据"
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
    @Published var diagnosePath = ""
    @Published var diagnosis: [NameService.DiagnosisItem] = []
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
    }

    func refresh() {
        status = names.status
        contentStatus = delegate?.contentStatus
    }

    func commitContent() { delegate?.applyContentScope(content) }

    func addContentFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
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
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        let home = NSHomeDirectory()
        for url in panel.urls {
            let p = PathUtil.abbreviate(url.path, home: home)
            if !scope.folders.contains(p) { scope.folders.append(p) }
        }
        commitScope()
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

    func startRecording() {
        recording = true
        hotKeyError = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = HotKey.Combo.carbonModifiers(event.modifierFlags)
            if event.keyCode == 53 && mods == 0 { self.stopRecording(); return nil }  // Esc cancels
            guard mods != 0 else { self.hotKeyError = "需要至少一个修饰键（⌘ ⌥ ⌃ ⇧）"; return nil }
            let combo = HotKey.Combo(keyCode: UInt32(event.keyCode), modifiers: mods)
            if self.delegate?.changeHotKey(combo) == true {
                self.hotKey = combo
                self.hotKeyError = nil
            } else {
                self.hotKeyError = "\(combo.display) 已被其他应用占用，请换一个组合"
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
final class SettingsWindowController: NSWindowController {
    let model: SettingsModel
    var names: NameService {
        get { model.names }
        set { model.names = newValue; model.refresh() }
    }

    init(names: NameService, delegate: AppDelegate) {
        model = SettingsModel(names: names, delegate: delegate)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 660), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "XSearch 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.setContentSize(NSSize(width: 940, height: 660))
        window.center()
    }

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
                        Label(tab.rawValue, systemImage: tab.symbol)
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
        Text("通用").font(.system(size: 20, weight: .semibold))
        Card(title: "呼出快捷键", subtitle: "点击后按下新的组合键；与其他应用冲突时会提示") {
            HStack {
                Button(model.recording ? "请按下组合键…（Esc 取消）" : model.hotKey.display) {
                    model.recording ? model.stopRecording() : model.startRecording()
                }
                .controlSize(.large)
                if let e = model.hotKeyError { Text(e).font(.system(size: 12)).foregroundStyle(.orange) }
            }
        }
        Card(title: "开机自动启动") {
            Toggle("登录时打开 XSearch", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
        }
        Card(title: "软件更新", subtitle: "当前版本 \(Updater.shared.version)") {
            HStack {
                Toggle("自动检查更新", isOn: Binding(get: { Updater.shared.automaticallyChecks }, set: { Updater.shared.automaticallyChecks = $0; model.objectWillChange.send() }))
                    .toggleStyle(.switch)
                    .disabled(!Updater.shared.isConfigured)
                Spacer()
                Button("检查更新…") { Updater.shared.checkForUpdates() }
            }
            if !Updater.shared.isConfigured {
                Text("这个版本没有配置更新地址，新版需要手动下载安装。").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        Card(title: "历史记录", subtitle: "只保存在本机") {
            Toggle("呼出时保留上次的搜索内容", isOn: $model.keepLastQuery).toggleStyle(.switch)
            Toggle("输入框为空时显示最近打开的文件", isOn: $model.showRecents).toggleStyle(.switch)
            HStack {
                Button("清除最近打开记录") {
                    model.delegate?.clearRecents()
                    model.recentsCleared = true
                }
                if model.recentsCleared { Text("已清除").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Text("收藏不受影响。按使用频率排序的依据也会一并清除。").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        Card(title: "呼出时的模式") {
            Picker("", selection: Binding(get: { model.summonMode }, set: { model.summonMode = $0; Preferences.shared.summonMode = $0 })) {
                Text("总是名称模式").tag(Preferences.SummonMode.alwaysName)
                Text("记住上次的模式").tag(Preferences.SummonMode.rememberLast)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

struct SyntaxPane: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Text("搜索语法").font(.system(size: 20, weight: .semibold))
        Card(title: "语法开关", subtitle: "关闭后对应符号按普通字符搜索；按 ⌘/ 查看速查") {
            Toggle(isOn: $model.syntax.operators) { Text(verbatim: "运算符　甲 | 乙、-草稿、(甲 | 乙) 丙　两种模式") }
            Toggle(isOn: $model.syntax.wildcards) { Text(verbatim: "通配符　*.pdf、报告?.docx、**/合同/*.pdf　名称模式") }
            Toggle(isOn: $model.syntax.regex) { Text(verbatim: "正则　regex:^\\d+\\.txt$") }
            Toggle(isOn: $model.syntax.proximity) { Text(verbatim: "邻近查询　\"合同 金额\"~10　内容模式") }
        }
        Card(title: "内容匹配模式", subtitle: "只影响内容搜索；完整窗口里可以临时切换") {
            Picker("", selection: $model.matchMode) {
                Text("宽松（默认）：不区分大小写、全角半角和空白差异").tag("loose")
                Text("区分大小写：其余与宽松相同").tag("caseSensitive")
                Text("严格原文：逐字符比较，不做任何归一化").tag("strict")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

struct OpenWithPane: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Text("打开方式").font(.system(size: 20, weight: .semibold))
        Card(title: "文本与代码", subtitle: "在内容模式下打开时，用所选编辑器跳到命中所在的行") {
            Picker("", selection: $model.openWith.editor) {
                ForEach(Editor.allCases, id: \.self) { e in
                    Text(e.isInstalled ? e.title : e.title + "（未安装）").tag(e).disabled(!e.isInstalled)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        Card(title: "PDF", subtitle: "在内容模式下打开时，用外部阅读器跳到命中所在的页") {
            Toggle("打开到命中页", isOn: $model.openWith.pdfAtPage)
            Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: ExternalPDF.skimID) != nil
                 ? "已安装 Skim：直接跳页。"
                 : "使用“预览”：需要在 系统设置 → 隐私与安全性 → 辅助功能 中允许 XSearch，否则打开第 1 页。安装 Skim 后不需要这项权限。")
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
        case .starting: return "正在打开…"
        case .scanning: return "正在建立 · \(Theme.count(st.count)) 项"
        case .ready: return "\(Theme.count(st.count)) 项 · 内存约 \(mem) · " + (st.watching ? "实时更新" : "未实时更新，正在重试")
        case .failed(let m): return "出错：\(m)"
        }
    }

    var body: some View {
        Text("索引范围").font(.system(size: 20, weight: .semibold))
        Text("文件名和内容分别设置。同一个文件只扫描、提取一次。").font(.system(size: 12.5)).foregroundStyle(.secondary)
        Card(title: "文件名索引", subtitle: statusLine) {
            Picker("", selection: Binding(get: { model.scope.wholeDisk }, set: { model.scope.wholeDisk = $0; model.commitScope() })) {
                Text("整盘").tag(true)
                Text("指定文件夹").tag(false)
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
                            Button("移除") {
                                model.scope.folders.removeAll { $0 == folder }
                                model.commitScope()
                            }
                            .foregroundStyle(.red)
                            .buttonStyle(.borderless)
                        }
                    }
                    if model.scope.folders.isEmpty { Text("还没有文件夹。").font(.system(size: 12)).foregroundStyle(.secondary) }
                    Button("＋ 添加") { model.addFolders() }.buttonStyle(.borderless)
                }
            }
            Divider()
            Text("排除规则").font(.system(size: 13, weight: .medium))
            Text(verbatim: "路径（/System、~/Library）、名称（node_modules）或模式（*.log、**/build/**）。").font(.system(size: 11.5)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.scope.excludes, id: \.self) { rule in
                    HStack {
                        Text(rule).font(.system(size: 12.5, design: .monospaced))
                        Spacer()
                        Button("移除") {
                            model.scope.excludes.removeAll { $0 == rule }
                            model.commitScope()
                        }
                        .foregroundStyle(.red)
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("＋ 添加规则", text: $model.newRule)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onSubmit(addRule)
                    Button("添加", action: addRule).disabled(model.newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Divider()
            Toggle("包含隐藏文件", isOn: Binding(get: { model.scope.includeHidden }, set: { model.scope.includeHidden = $0; model.commitScope() }))
                .toggleStyle(.switch)
            Toggle("包含应用包内部", isOn: Binding(get: { model.scope.includePackageContents }, set: { model.scope.includePackageContents = $0; model.commitScope() }))
                .toggleStyle(.switch)
            Text("修改后在后台重新核对范围，期间可以继续搜索。外置盘和网络盘在后续版本支持。").font(.system(size: 11.5)).foregroundStyle(.secondary)
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

    var body: some View {
        Text("隐私与数据").font(.system(size: 20, weight: .semibold))
        Card(title: "数据位置") {
            Text("文件名和搜索词只在本机处理。索引保存在 ~/Library/Application Support/XSearch（目录 0700，文件 0600），日志中不记录搜索词。")
                .font(.system(size: 12.5))
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([Preferences.dataDirectory]) }
        }
        Card(title: "重建内容索引", subtitle: "在后台重新提取全部内容文件；完成前继续使用旧索引，完成后删除旧索引并回收空间。") {
            Button("重建内容索引…") { model.delegate?.rebuildContentIndex() }
        }
        Card(title: "重建文件名索引", subtitle: "删除文件名索引并重新扫描。最近打开记录和设置单独保存，不受影响。") {
            Button("重建文件名索引…") { confirmRebuild = true }
                .foregroundStyle(.red)
                .confirmationDialog("重建文件名索引？", isPresented: $confirmRebuild) {
                    Button("重建", role: .destructive) { model.delegate?.rebuildNameIndex() }
                } message: {
                    Text("重新扫描期间，已处理的部分可以立即搜索。")
                }
        }
    }
}

struct ContentCard: View {
    @ObservedObject var model: SettingsModel

    var statusLine: String {
        guard let st = model.contentStatus else { return "内容索引未启动" }
        var parts = ["\(Theme.count(st.indexed)) 个文件"]
        if st.lastError != nil { parts.append("写入暂时出错，正在自动重试") }
        if st.pending > 0 { parts.append("待处理 \(Theme.count(st.pending))") }
        if st.failed > 0 { parts.append("\(st.failed) 个提取失败") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card(title: "内容索引", subtitle: "只提取下面的文件夹；网络盘默认不建内容索引。" + "  " + statusLine) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.content.folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder).font(.system(size: 13))
                        Spacer()
                        Button("移除") {
                            model.content.folders.removeAll { $0 == folder }
                            model.commitContent()
                        }
                        .foregroundStyle(.red)
                        .buttonStyle(.borderless)
                    }
                }
                if model.content.folders.isEmpty { Text("还没有文件夹，内容搜索暂不可用。").font(.system(size: 12)).foregroundStyle(.secondary) }
                Button("＋ 添加文件夹") { model.addContentFolders() }.buttonStyle(.borderless)
            }
            Divider()
            Text("提取的文件类型").font(.system(size: 13, weight: .medium))
            // A grid that wraps: twelve types do not fit one row.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach([(ContentType.text, "文本 / 代码"), (.pdf, "PDF"), (.docx, "Word（docx）"), (.doc, "Word（doc）"), (.wps, "WPS 文字"), (.sheet, "Excel"), (.slide, "PowerPoint"), (.ofd, "OFD"), (.web, "网页 HTML"), (.ebook, "ePub"), (.rtf, "RTF"), (.archive, "压缩包")], id: \.0) { type, label in
                    Toggle(isOn: Binding(get: { model.content.types.contains(type) }, set: { on in
                        if on { model.content.types.insert(type) } else { model.content.types.remove(type) }
                        model.commitContent()
                    })) { Text(verbatim: label).lineLimit(1) }
                    .toggleStyle(.checkbox)
                }
            }
            Text("WPS 表格、演示分别归入 Excel、PowerPoint；压缩包只读一层；图片 OCR 在 M6").font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack {
                Text("单文件上限").font(.system(size: 13))
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
        Text("诊断：为什么搜不到").font(.system(size: 20, weight: .semibold))
        Text("输入或把文件拖到这里，逐项检查它在索引中的状态。").font(.system(size: 12.5)).foregroundStyle(.secondary)
        HStack {
            TextField("文件路径，例如 ~/Downloads/合同.docx", text: $model.diagnosePath)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.runDiagnosis() }
            Button("检查") { model.runDiagnosis() }.keyboardShortcut(.defaultAction)
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
                            Text(item.label).font(.system(size: 13, weight: .medium))
                            Text(item.detail).font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

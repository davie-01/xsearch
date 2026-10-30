import AppKit
import Catalog
import ServiceManagement
import SwiftUI
import XSearchCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用", scope = "索引范围", privacy = "隐私与数据"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .scope: "folder"
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
    @Published var newRule = ""
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
    }

    func refresh() { status = names.status }

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
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 200)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.tab {
                    case .general: GeneralPane(model: model)
                    case .scope: ScopePane(model: model)
                    case .privacy: PrivacyPane(model: model)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
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

struct ScopePane: View {
    @ObservedObject var model: SettingsModel

    var statusLine: String {
        let st = model.status
        let mem = ByteCountFormatter.string(fromByteCount: Int64(st.memoryBytes), countStyle: .memory)
        switch st.phase {
        case .starting: return "正在打开…"
        case .scanning: return "正在建立 · \(Theme.count(st.count)) 项"
        case .ready: return "\(Theme.count(st.count)) 项 · 内存约 \(mem) · 实时更新"
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
            Text("路径（/System、~/Library）、名称（node_modules）或模式（*.log、**/build/**）。").font(.system(size: 11.5)).foregroundStyle(.secondary)
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
        Card(title: "内容索引", subtitle: "内容搜索将在下一个版本提供：只提取你选定的文件夹，首次推荐“下载”。") {
            EmptyView()
        }
        .opacity(0.6)
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

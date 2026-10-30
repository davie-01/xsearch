# XSearch 架构设计

> 版本：v0.3（2026-10-29）
> 状态：方案已定，待开工
> 平台：**仅支持 macOS 26 及以上、Apple Silicon（arm64）**，不考虑 x86 和低版本系统

---

## 1. 产品定位

XSearch 是一款快捷键呼出的启动器式本地搜索工具，提供两种能力：

- **文件名搜索**：参照 Everything / oil-find，自建内存索引，输入即出结果，延迟在毫秒级。
- **文件内容搜索**：参照 AnyTXT / pivotsearch，自建全文索引，**任意子串零漏检**，预览时能定位并高亮命中处。

设计原则：

1. **不依赖 Spotlight 索引**。文件名索引和内容索引都由 XSearch 自己建立和维护。
2. **精准优先**。对中文采用“不丢字”的切分方式，召回之后再做一次精确核验，不使用停用词。
3. **原生体验**。启动器呼出在 50ms 以内，常驻内存小，预览直接使用系统的 PDFKit 和 Vision。
4. **完全离线**。所有数据只存在本机，不联网。

## 2. 参考项目与借鉴边界

| 项目 | 协议 | 借鉴内容 | 使用方式 |
|---|---|---|---|
| oil-find | MIT（免费部分） | 用 getattrlistbulk 扫描目录；列式内存存储；C + NEON 匹配；在上次结果上继续筛选；FSEvents 断点续传（lastEventId）；拼音别名；搜索语法 | 可以参考并改写代码，保留 MIT 版权声明 |
| pivotsearch | Apache-2.0 | 解析器注册表；用 mtime 判断增量；任务队列；snippet 截取 | 可以参考并改写代码，保留 NOTICE |
| MacHunt | 未声明许可证 | 文件名用 SQLite FTS5 trigram 建索引；FSEvents 断点续传；每 10 秒轮询 `/Volumes` 发现网络盘；Tauri 中调用原生 AppKit 拖拽；收藏/置顶 | 只借鉴思路。它的结论反过来印证了我们的选择：trigram 搜不了 2 个汉字，中文和短查询都要退回 `LIKE` 全表扫描，所以文件名搜索坚持用内存索引 |
| DocFetcher | EPL-1.0 | Lucene；可切换分析器（默认把汉字逐字切分 + 短语查询、可选 Ansj 中文分词、源码分析器）；按文件夹建立索引并可移植；关闭时用守护进程记录变化；多层嵌套压缩包、邮件、HTML 及其 `_files` 目录合并为一篇；按内容识别 MIME；邻近查询 | 只借鉴思路。它是 Java + Tika 实现，建索引约 200 文件/分钟，预览只有纯文本 |
| Easydict | **GPL-3.0** | Vision OCR 的参数配置、预热、阅读顺序恢复、中文行拼接规则 | **只借鉴思路，不复制代码**，否则 XSearch 会被 GPL 传染 |

pivotsearch 中**不采用**的做法：jieba 分词 + 停用词（会漏搜子串和虚词）；正文不存储、预览时重新解析（大文件预览慢）；Tauri/WebView 做界面。

## 3. 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| 工具链 | Xcode 26、Swift 6.2（严格并发检查）、Rust stable（只编 aarch64-apple-darwin） | |
| 工程组织 | XcodeGen 生成 .xcodeproj；Rust 部分用 cargo workspace，产出 XCFramework | 方便管理 helper 进程、签名和 entitlements |
| UI | AppKit（NSPanel 启动器、结果列表、预览）+ SwiftUI（设置、引导页）；启动器背景用 macOS 26 的 Liquid Glass（`NSGlassEffectView`） | |
| 文件名引擎 | Swift + C（NEON） | 全部常驻内存 |
| 内容引擎 | Rust：Tantivy + 自定义分词器 + 解析器；通过 UniFFI 生成 Swift 绑定 | |
| 文本提取 | PDFKit（PDF 文字层）、Rust 解析器（Office、ePub、HTML、zip）、`textutil`（.doc/.rtf）、Vision（OCR） | 优先使用系统能力 |
| 元数据 | SQLite（WAL 模式） | |
| 进程间通信 | XPC（NSXPCConnection）；helper 通过 SMAppService 注册 | |
| 分发 | Developer ID 签名、公证、DMG、Sparkle 自动更新；**不开沙盒**（需要完全磁盘访问权限） | 不上架 App Store |

既然只支持 macOS 26，可以放心使用：Vision 新的 Swift API（`RecognizeTextRequest`、`RecognizeDocumentsRequest`）、Swift 6 并发模型、Observation 框架、Liquid Glass，**不需要写任何兼容旧系统的代码分支**。

## 4. 总体架构

```
┌─────────────── XSearch.app（菜单栏常驻，LSUIElement）────────────────┐
│ HotKeyManager ──▶ LauncherPanel (NSPanel, nonactivating)             │
│                    ├ QueryField + ModeBar [名称|内容|全部]             │
│                    ├ ResultList（虚拟化列表）                          │
│                    └ PreviewPane（Text / PDF / Code / Image-OCR）     │
│ QueryParser ──▶ NameEngine（内存列式索引，C/NEON）◀── NameWatcher      │
│             └─▶ ContentSearcher（Tantivy 只读 + TextStore 读取）       │
│ IndexerClient (XPC) ── 状态、进度、暂停/恢复、重建                       │
└──────────────▲──────────────────────────────────────────────────────┘
               │ XPC 控制通道；索引目录共享（writer 提交后 reader 自动刷新）
┌──────────────┴──── XSearchIndexer（后台 helper，SMAppService）───────┐
│ ChangeFeed（FSEvents + lastEventId 断点续传 + 定期对账）                │
│   ─▶ JobQueue（SQLite 持久化；优先级：最近修改 > 新增 > 历史文件）       │
│   ─▶ Extractor 池                                                     │
│        PDFKit │ Rust 解析器 │ textutil │ OCRKit（Vision）               │
│   ─▶ ContentWriter（Tantivy）+ TextStore（zstd 压缩）+ meta.sqlite      │
│ Throttle：background QoS、用电池或低电量模式时暂停、温度高时降速、          │
│           单文件超时、单文件大小上限                                     │
└──────────────────────────────────────────────────────────────────────┘
```

**为什么分成两个进程**：解析损坏或恶意的 PDF/Office 文件、批量 OCR，都放在 helper 里做。helper 崩溃只会被自动拉起，不影响启动器；UI 进程只负责读索引，保持轻量。

**文件名索引放在 UI 进程**：搜文件名要求亚毫秒级响应，不能经过 XPC 往返。文件名的 FSEvents 监听也在 UI 进程里，和 helper 各自独立监听。

## 5. 文件名引擎（NameEngine）

### 5.1 数据结构（参考 oil-find）

- 列式数组：`nameOff[] / parent[] / size[] / mtime[] / flags[] / depth[] / kind[]`，所有文件名的 UTF-8 字节拼在一整块 `names` 里。
- 路径不存储，显示时沿 `parent` 链实时拼出来。
- 别名区 `alt*`：存中文名的拼音全拼和首字母，支持多音字。
- 用读写锁保护；增量修改原地进行，删除的条目先打标记，累积到一定量后统一压缩。
- 持久化：整块写成 `names.idx`（带版本号、配置指纹、lastEventId、FSEvents UUID），启动时用 mmap 直接加载，不需要重新扫描。

### 5.2 扫描与更新

- 首次全量扫描：C 实现，用 `getattrlistbulk` 批量读目录项，多线程按子树分工。
- 增量更新：FSEvents 使用 `kFSEventStreamCreateFlagFileEvents`，延迟 0.15 秒。
- 断点续传：重启后用 `sinceWhen = lastEventId` 补齐离线期间的变化；如果卷的 UUID 变了、事件 ID 回绕，或者收到 `MustScanSubDirs` 事件，就对受影响的子树重新扫描。
- **网络盘**（SMB / NFS / WebDAV）：FSEvents 收不到这类盘上的变化（MacHunt 已证实），所以改为监听挂载通知 + 定时增量对账（默认 30 分钟，可配置），默认不建内容索引。
- 默认索引整个系统盘，排除 `node_modules`、`.git`、应用包内部、`~/Library`、系统目录，这些都可以在设置里打开。外置磁盘插上后自动建立索引。

### 5.3 匹配与排序

- 匹配：C + NEON，大小写不敏感；输入是上次输入的延续时，只在上次结果里继续筛。
- 排序优先级：完全相同 > 前缀匹配 > 单词边界匹配 > 子串匹配 > 拼音匹配 > 模糊匹配；再按最近使用频率（frecency）、修改时间、路径深度加权。
- 性能目标：85 万个文件时，单次查询 P50 小于 1ms、P99 小于 10ms，常驻内存小于 60MB。

## 6. 内容引擎（ContentEngine，Rust）

### 6.1 分词：保证“精准”的关键

- **CJK 字符**：同时产出单字和双字（bigram）词元。查询时转换成短语查询，所以任意中文子串都能命中，一个字也能搜。
- **拉丁字母和数字**：按单词切分，转小写，做 Unicode NFKC 归一化（全角半角统一），不做词干还原。
- **代码标识符**（参考 DocFetcher 的 SourceCodeAnalyzer）：`getUserName`、`user_name` 既保留整个词，也拆出 `get / user / name`，搜任何一段都能命中。
- **不使用停用词**：“的话”“可以”这类词也能搜到。
- 可选增加 `content_word` 字段：用词典分词，只用来给排序加分，不参与召回。

### 6.2 两阶段匹配

1. **召回**：用 Tantivy 短语查询或布尔查询，快速得到候选文件。
2. **核验**：从 TextStore 读出候选文件的正文，在归一化后的文本上精确查找，得到每个命中的字符区间。这样既排除了假阳性，也让高亮位置准确到字符。

### 6.3 Schema

| 字段 | 类型 | 说明 |
|---|---|---|
| `doc_id` | u64 fast | 对应 meta.sqlite 里的主键 |
| `path` | raw string | 用于 `in:` 目录过滤（前缀查询） |
| `name` | 文本（同一分词器） | 文件名同时命中时加分 |
| `content` | 文本（CJK bigram + 单词） | 不存储原文 |
| `ext` / `kind` | raw string | 类型过滤 |
| `size` / `mtime` | i64 fast | 范围过滤、排序 |
| `source` | raw string | 标记文本来源：text / ocr / ocr_alt |

### 6.3.1 按根目录分区（参考 DocFetcher）

每个内容索引根目录（例如 `~/Documents`、某块外置磁盘）对应**一个独立的 Tantivy 索引**，查询时多个索引并行搜索后合并结果（Tantivy 原生支持多索引联合查询）。好处：
- 删除或重建某个目录时，直接删掉它的分区，不影响其他目录；
- 外置磁盘的分区以卷 UUID 命名，磁盘拔掉后索引仍保留，可以继续搜（结果标为“离线”），插回后增量对账；
- 某个分区损坏时只需重建这一个分区。

### 6.4 TextStore

- 每个文件的归一化正文用 zstd 压缩后存储，按 doc_id 分片放进 pack 文件。
- 同时存储**位置映射**：
  - PDF：页码 → 文本区间；
  - OCR：文字框坐标 ↔ 文本区间；
  - Office：段落、工作表、幻灯片 → 文本区间。
- 预览和高亮直接读取这里的数据，不需要重新解析原文件。

### 6.5 排序

BM25 + 完整短语加分 + 文件名命中加分 + 最近修改时间加分 + 用户最近打开过的文件加分。

### 6.6 兜底模式：实时扫描

对没有建内容索引的目录（例如代码仓库），可以调用基于 ripgrep `grep-searcher` 库的实时扫描，结果以流的形式返回。查询里写 `in:路径 rg:` 时，或者在没有索引的目录下搜索时触发。

## 7. 文本提取

| 格式 | 首批（M2） | 实现方式 |
|---|---|---|
| txt / md / csv / log / 源代码 | ✓ | Rust 读取，自动识别编码（UTF-8 / GBK / GB18030 / Big5） |
| docx / xlsx / pptx | ✓ | Rust 解析 zip + XML |
| pdf（有文字层） | ✓ | PDFKit，逐页提取 |
| pdf（扫描件） | M3 | PDFKit 渲染成图片后走 OCRKit |
| 图片（png/jpg/heic/截图） | M3 | OCRKit |
| doc / rtf / webarchive | M4 | 调用 `textutil -convert txt` |
| html / epub | M4 | Rust |
| zip / 7z / tar 包内文件 | M4 | Rust 解压后逐个解析，路径记为 `a.zip!/内部路径`，支持多层嵌套；解压出的临时文件放进有大小上限的缓存 |
| 邮件 .emlx / .eml | M4 | 解析 Apple Mail 本地邮件库，标题、发件人、正文、附件都进索引 |
| 网页另存的 `x.html` + `x_files/` | M4 | 合并为一篇文档（参考 DocFetcher） |
| 没有扩展名或扩展名不对的文件 | M2 | 用 UTType 和文件头魔数识别实际类型，再分派给对应的解析器 |
| Pages / Numbers / Keynote | M4 | 读取包内的预览 PDF，或解析 iwa 格式（待评估） |
| wps / ofd | 待定 | 根据实际使用量决定是否做 |

限制：单文件默认上限 100MB（可配置）；单个文件解析超时 30 秒，超时后标记为失败，下次文件变化时再重试；解析失败的原因记录到 meta.sqlite，在设置页里可以查看。

## 8. OCRKit（Vision，macOS 26 新 API）

参考 Easydict 的思路，用 Swift **自己实现**，运行在 helper 进程中。

```
输入：CGImage（图片文件，或 PDF 扫描页按 2 倍分辨率渲染出的图）
 ① 预热：helper 启动后先识别一张合成的小图，把模型加载进内存
 ② 识别：RecognizeTextRequest
      recognitionLevel = .accurate
      usesLanguageCorrection = true
      recognitionLanguages = [zh-Hans, en-US]（固定顺序，不自动检测语言）
      跳过过小的图片（短边小于 64px）和明显不含文字的图片
 ③ 文档结构（可选）：RecognizeDocumentsRequest，取段落和表格结构
      → M3 阶段用实际文档对比测试，效果好就用它替代 ④ 的大部分逻辑
 ④ 阅读顺序：按纵坐标切分区块 → 判断分栏 → 按“从上到下、从左到右”排序
 ⑤ 行拼接：中日文之间不加空格；英文之间加空格；英文行尾的连字符去掉后拼接
 ⑥ 输出：正文（source=ocr）+ 每个文字框的坐标和对应文本区间
      可选：每个框的第 2 个候选文字写入 ocr_alt（低权重，用来提高召回率）
 ⑦ 附带：用 DetectBarcodesRequest 识别二维码，内容一并写入索引
```

并发：OCR 任务最多同时跑 2 个，使用 utility QoS。检测到用电池、低电量模式或温度偏高时暂停。

## 9. 查询语法

文件名搜索和内容搜索共用一套过滤语法：

| 语法 | 含义 |
|---|---|
| `foo bar` | 同时包含 foo 和 bar |
| `foo \| bar` | 包含 foo 或 bar |
| `"完整短语"` | 内容模式下按短语精确匹配 |
| `-词` 或 `!词` | 排除 |
| `ext:pdf;docx` | 按扩展名 |
| `kind:doc/image/code/folder/app…` | 按类型 |
| `in:~/工作/示例` 或 `~/工作/示例/ 关键词` | 只在该目录下搜 |
| `size:>10mb`、`size:1mb..5mb` | 按大小 |
| `dm:today/week/2026-10-01` | 按修改时间 |
| `"甲 乙"~10` | 邻近查询：甲和乙相距 10 个字以内（内容模式） |
| `regex:…` | 正则表达式（文件名模式；内容模式下走实时扫描） |
| `wd`、`wendang` | 拼音首字母或全拼（仅文件名） |

模式前缀：`'词` 或 `in 词` 表示内容模式；`f 词` 表示名称模式。

## 10. 交互设计

### 10.1 启动器

- 默认快捷键 `⌥Space`（可在设置里改）。呼出时不抢占当前应用的焦点，按 `Esc` 或点击窗口外部即关闭。
- 模式栏 **[名称] [内容] [全部]**，用 `Tab` 或 `⌘1/2/3` 切换，记住上次使用的模式。
- **名称模式**：窄长条窗口，宽 720，最多显示 9 行结果。
- **内容模式**：窗口自动加宽到约 1100，分为左右两栏：左边是结果列表，右边是预览。
- **全部模式**：结果按“文件名命中 / 内容命中”分组显示。

```
┌───────────────────────────────────────────────────────────────────┐
│ 🔍 [内容] 数据共享交换平台                         ext:docx  ⌘1 ⌘2 ⌘3 │
├──────────────────────────┬────────────────────────────────────────┤
│ 📄 实施方案.docx      12处  │  实施方案.docx              第 3/12 处 ↑↓ │
│   …建设数据共享交换平台，…    │ ┃ 二、建设内容                          │
│   ~/工作/示例 · 3天前         │ ┃ （一）建设【数据共享交换平台】…         │
│ 📕 技术方案.pdf  p.14  3处  │ ┃                                    ▮ │
│ 🖼 截图 2026-10-20.png OCR  │ ┃                                    ▮ │
├──────────────────────────┴────────────────────────────────────────┤
│ ↵ 打开  ⌘↵ 定位到命中处  ⌘R 在访达中显示  ⌘G/⇧⌘G 下/上一处  ⌘C 复制路径 │
└───────────────────────────────────────────────────────────────────┘
```

### 10.1.1 完整窗口模式

在启动器里按 `⌘E` 展开为可调整大小的普通窗口，用于需要长时间查找资料的场景（参考 DocFetcher / MacHunt 的主窗口）：
- 左栏：索引目录树（可勾选搜索范围）、文件类型勾选、时间和大小过滤；
- 中栏：结果表格，列可排序（名称、路径、命中数、大小、修改时间），支持多选；
- 右栏：和启动器相同的预览面板。

### 10.1.2 收藏

在结果上按 `⌘D` 收藏，空输入时显示收藏列表和最近打开的文件（参考 MacHunt 的 Pinned）。

### 10.2 预览面板（PreviewPane）

| 类型 | 渲染方式 | 高亮方式 |
|---|---|---|
| 纯文本 / Markdown / Office | NSTextView 显示 TextStore 里的正文，保留段落结构 | 背景色标记，当前命中处颜色加深 |
| 代码 | NSTextView + 语法高亮，带行号 | 同上 |
| PDF | PDFView 显示原始页面 | 用 PDFSelection 在页面上高亮，并自动跳到对应页 |
| 图片 / 扫描页 | 显示原图，叠加 OCR 文字框图层 | 给命中的文字框画上框线 |

通用功能：
- 打开预览时自动滚动到第一处命中；用 `⌘G` / `⇧⌘G` 跳到下一处/上一处，顶部显示“第 n/N 处”；右侧缩略条标出所有命中的位置。
- 预览中可以输入新的关键词，只在当前文件里查找。

### 10.3 定位到原文件（⌘↵）

- 文本或代码文件：用配置好的编辑器打开到对应行（VS Code：`code -g 文件:行`；Sublime：`subl 文件:行`；Zed：`zed 文件:行`）。
- PDF：在 XSearch 自带的阅读窗口中打开到对应页，并保留高亮（系统“预览”App 不支持从外部传入页码）。
- 其他类型：用默认应用打开，同时把关键词写入系统查找剪贴板，打开后按 `⌘F` 就是这个关键词。

### 10.4 其他

- 结果可以直接拖到其他应用；按空格键调用 Quick Look；`⌘⌫` 移到废纸篓；用 `↑` 调出搜索历史；按 `⌘/` 打开语法速查。
- 菜单栏图标：显示索引进度，提供暂停/恢复、打开设置的入口。
- 首次启动引导：引导开启完全磁盘访问权限，选择要建内容索引的目录，设置快捷键。

## 11. 存储布局

```
~/Library/Application Support/XSearch/
├── names/
│   ├── system.idx           # 系统盘文件名索引
│   └── <volumeUUID>.idx     # 外置磁盘
├── content/                 # Tantivy 索引目录
├── text/                    # TextStore pack 文件（zstd）
├── meta.sqlite              # 文件状态、任务队列、解析错误、使用频率
└── logs/
```

meta.sqlite 主要表：
- `files(doc_id, path, inode, dev, size, mtime, ext, parser, status, error, indexed_at, text_ref)`
- `jobs(doc_id, priority, reason, attempts, enqueued_at)`
- `usage(path, open_count, last_opened)`

## 12. 工程结构

```
XSearch/
├── project.yml                  # XcodeGen 配置
├── docs/ARCHITECTURE.md
├── App/                         # XSearch.app
│   ├── Launcher/                # HotKey、LauncherPanel、QueryField、ModeBar
│   ├── Results/                 # ResultList、单元格、分组
│   ├── Preview/                 # Text / PDF / Code / Image 预览
│   ├── Settings/                # SwiftUI 设置页
│   └── Onboarding/
├── Indexer/                     # XSearchIndexer helper
│   ├── ChangeFeed/  JobQueue/  Extractors/  Throttle/
│   └── XPC/
├── Packages/
│   ├── XSearchCore/             # 公共模型、查询解析、XPC 协议
│   ├── NameEngine/              # Swift + C(NEON)
│   └── OCRKit/                  # Vision 封装、阅读顺序、行拼接
├── rust/
│   ├── Cargo.toml               # workspace
│   ├── xs-tokenizer/            # CJK bigram 分词器
│   ├── xs-index/                # schema、writer、reader、两阶段匹配
│   ├── xs-textstore/
│   ├── xs-parsers/              # docx/xlsx/pptx/epub/html/zip/编码识别
│   ├── xs-grep/                 # 实时扫描
│   └── xs-ffi/                  # UniFFI 导出
├── cli/xs/                      # 命令行工具，供 benchmark 和脚本调用
├── scripts/                     # build-rust.sh、notarize.sh、bench.sh
└── Tests/
```

## 13. 实施里程碑

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **M0 骨架** | XcodeGen 工程、菜单栏常驻、全局快捷键、Liquid Glass 风格的 NSPanel、设置页、权限引导、Rust 构建脚本和 UniFFI 联通 | 快捷键呼出小于 50ms；Swift 能调用到 Rust 函数 |
| **M1 文件名引擎** | 扫描、列式存储、持久化、FSEvents 断点续传、查询语法、拼音、排序、名称模式 UI | 85 万文件冷启动扫描小于 5 秒；查询 P50 小于 1ms；重启后不需要全量重扫 |
| **M2 内容引擎** | 分词器、Tantivy、TextStore、两阶段匹配、Indexer helper、任务队列、节流；格式：文本类、Office、有文字层的 PDF | 任意中文子串零漏检（有对照测试集）；文件修改后 3 秒内能搜到 |
| **M3 内容 UI + OCR** | 双栏预览、命中跳转、PDF 页面高亮、定位到原文件；OCRKit（图片 + 扫描版 PDF）；对比测试 RecognizeDocumentsRequest | 常用的 docx/pdf/xlsx/截图都能正确预览和定位 |
| **M4 扩展** | .doc/rtf、html/epub、zip 包内搜索、iWork、外置磁盘、实时扫描模式、`xs` 命令行工具 | 根据需要取舍 |
| **M5 发布** | 签名公证、DMG、Sparkle、性能回归测试 | |

## 14. 待确认事项

1. 是否需要支持 wps / ofd 格式（取决于日常公文中的使用量）。
2. 默认快捷键：`⌥Space` 是否和你现有的工具冲突。
3. 默认对哪些目录建内容索引。
4. OCR 是否保存第 2 候选文字（召回率更高，但可能多出一些误命中）。

## 15. 风险与对策

| 风险 | 对策 |
|---|---|
| Tantivy 的 bigram 索引体积偏大 | 正文不存在 Tantivy 里；content 字段只记录位置信息；定期合并段 |
| 大量 OCR 占用 CPU、发热 | 限制并发、监测电源和温度、用户可以暂停、只对指定目录做 OCR |
| 解析器崩溃或卡死 | 解析放在 helper 进程，设置单文件超时，失败后自动重启并跳过该文件 |
| FSEvents 丢事件 | 收到 MustScanSubDirs 时对子树重扫；每天在空闲时做一次轻量对账（只比较 mtime 和 size） |
| 首次建内容索引太慢（DocFetcher 约 200 文件/分钟） | 解析器并行 + 按最近修改优先；目标是文本类和 Office 文件不低于 300 文件/秒，PDF 不低于 30 文件/秒；建索引过程中已经处理完的文件立即可搜 |
| UniFFI 调用开销 | 按批传递数据，查询结果一次性返回，避免逐条跨语言调用 |

## 16. 变更记录

| 版本 | 变更 |
|---|---|
| v0.1 | 初版方案（参考 oil-find、pivotsearch） |
| v0.2 | 只支持 macOS 26；新增 OCRKit（参考 Easydict 的思路）；补充工程结构和存储布局 |
| v0.3 | 参考 MacHunt、DocFetcher：内容索引按根目录分区（外置盘拔掉后也能搜）；分词器增加代码标识符拆分；新增邻近查询；新增完整窗口模式和收藏；网络盘改为定时对账；扩充格式（嵌套压缩包、邮件、网页 + `_files` 目录、无扩展名文件按内容识别）；明确建索引速度目标 |

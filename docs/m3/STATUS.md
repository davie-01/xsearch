# M3 进度

| 块 | 状态 | 说明 |
|---|---|---|
| M3-1 提取 | ✅ 完成 | 见下 |
| M3-2 语法 | ✅ 完成 | 见下 |
| M3-3 窗口 | ✅ 完成 | 见下 |
| M3-4 设置与收尾 | 待开始 | |

## M3-1 提取

- `xs-parsers::office`：
  - 表格：XLSX / XLSM / XLS / ODS，经 calamine 0.30.1（MIT）读取；每个非空行一行，单元格以制表符分隔，锚点为 `工作表!B3`（行内第一个非空单元格）；公式取缓存值。
  - PPTX：幻灯片按编号的数字顺序排列（slide2 在 slide10 之前），每页一个锚点，讲者备注跟在本页后面，锚点为“备注 n”。
  - OFD：按 OFD.xml → DocRoot → Document.xml 的 Page 顺序读取各页 Content.xml 里的 TextObject/TextCode，每页一个锚点；缺少页表时按 `Page_N` 数字顺序兜底。
- 三类各有独立的提取器版本号（`extractor.sheet/slide/ofd`）。版本升级时只重建对应类型（沿用 M2 的升级重建逻辑）。
- 解包与文本预算沿用 `maxUnpackedBytes`，超出时标为部分完成并给出警告。
- Swift：`ContentType` 新增 sheet、slide、ofd；Extractor 分发到 FFI；预览边栏显示“预算!B3”或“幻灯片 3”；设置里新增 Excel、PowerPoint、OFD 三个开关。
- 验证：
  - Rust office 测试 3 项、Swift 分发测试 1 项，均通过；
  - 用本地真实样本（xls 1、xlsx 3、pptx 1）跑 `cargo run --example probe`（只输出统计、不输出正文），全部完整提取，每个文件耗时都在 25 ms 以内；
  - 本地样本里没有 OFD 文件，OFD 目前只有合成测试覆盖。

## M3-2 语法

- 名称模式改为表达式树（`NameExpr`）：
  - 支持 `|`、`-`、括号、通配符（`Glob`：按 UTF-8 字符的 NFA）和 `regex:`（NSRegularExpression，在折叠后的名称键上匹配）；
  - 只有 AND 连接的普通词时，仍走 M1 的 memmem 快速路径，排序沿用第一个正向词的匹配等级；
  - 含路径模式时，不再按名称键缓存结果，改为逐条判断；完整路径要等文件名通过最后一段检查后才去拼。
- `size:` 和 `dm:` 由 `MetaFilter` 解析；多个同类条件取交集，互相矛盾时一个都不匹配。
- 内容引擎：
  - `Expr` 新增 `Near` 和 `Regex`；
  - 正则必须出现的固定文字由 regex-syntax 的 HIR 提取，用来做三元组召回；
  - 正则既取不到固定文字、又没有 dir:/ext: 时，返回带说明的查询错误；
  - 正则命中的片段参与摘要和预览高亮。
- 设置 → 通用 → 搜索语法：四个开关（运算符、通配符、正则、邻近查询）。⌘/ 速查按当前模式显示，被关闭的语法会标出。
- 测试：Rust `proximity_and_regex`；Swift `nameOperatorsWildcardsAndRegex`、`sizeAndDateFilters`、`contentSyntaxSwitchesAndMetaFilters`、`complexQueriesFilterAndRank`。

## M3-3 窗口

- **收藏（⌘D）**：
  - 存在 `user.sqlite` 的 `favorites` 表，记录 file_id 并保存路径；重建索引不受影响。
  - 输入框为空时，先显示“收藏”，再显示“最近打开”。
  - 收藏的文件被移动后，按 file_id 在文件名索引里找到新路径，并更新收藏记录。
- **移到废纸篓（⌘⌫）**：
  - 启动器：在提示区确认（再按一次 ⌘⌫，或点“移到废纸篓”）。启动器是非激活的透明面板，弹窗会抢走焦点并关掉面板，所以不用弹窗。没有选中结果时，⌘⌫ 仍然用来编辑输入框。
  - 完整窗口：焦点在表格里时按 ⌘⌫，弹出确认表单，可以一次处理多个选中项。
- **阅读窗口**（内容模式下按 ⌘↵，或预览区的“阅读窗口”按钮）：
  - 左侧列出全部命中，显示所在页或位置和上下文。
  - PDF 显示原始页面，命中处用高亮注释画出。PDF 的提取正文就是各页 `page.string` 依次拼接（每页后加换行），所以命中区间减去所在页的起点，就是这一页里的精确位置，再交给 `PDFPage.selection(for:)`，不需要模糊查找。
  - 其他格式显示提取的正文，可以跳到每一处命中。
  - 打开前用 revision（mtime 纳秒）核对文件。如果文件已改动，就不画高亮，显示提示；重新索引由 FSEvents 的正常流程负责。
  - “在外部打开到第 N 页”：装了 Skim 时用 AppleScript 直接跳页。只有“预览”时，有辅助功能权限就模拟“前往页面”快捷键；没有权限时打开第 1 页，并提示去哪里开启权限。为此应用签名增加了 `com.apple.security.automation.apple-events` 权限，Info.plist 增加了 NSAppleEventsUsageDescription。
- **完整窗口（⌘E）**：
  - 沿用启动器的输入和模式。
  - 左侧栏：位置或内容索引范围（勾选后作为 dir: 条件；都不勾表示不限）、文件类型（名称模式转成 kind:，内容模式转成 ext:）、修改时间（转成 dm:）、匹配模式（仅内容模式）。
  - 中间表格：名称、位置、命中、大小、修改时间。点表头排序，再点一次反向；不排序时保持引擎的相关度顺序。支持多选和拖出。
  - 右侧预览：名称模式用 Quick Look，内容模式用带命中跳转的正文预览。
  - 名称模式最多列出 5,000 项，内容模式逐批追加，并显示核验进度。
  - 快捷键：⌘1/⌘2、⌘↵、⌘D、⌘G、⇧⌘C、⌘F。
- 开发用环境变量：`XS_FULL_TEXT`（直接打开完整窗口）、`XS_FULL_MODE=content`、`XS_READER`（把第一个内容结果打开到阅读窗口）。
- 验证：
  - 自动测试：Swift 收藏测试；
  - 手动查看了真实索引下的完整窗口（名称和内容两种模式）和 PDF 阅读窗口，命中位置准确；
  - Skim 和“预览”的跳页还没有手动验证（本机需要授权）。

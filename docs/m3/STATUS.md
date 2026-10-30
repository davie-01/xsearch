# M3 进度

| 块 | 状态 | 说明 |
|---|---|---|
| M3-1 提取 | ✅ 完成 | 见下 |
| M3-2 语法 | ✅ 完成 | 见下 |
| M3-3 窗口 | 待开始 | |
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

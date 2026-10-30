# M3 进度

| 块 | 状态 | 说明 |
|---|---|---|
| M3-1 提取 | ✅ 完成 | 见下 |
| M3-2 语法 | 待开始 | |
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

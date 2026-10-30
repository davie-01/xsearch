# XSearch M2 计划：内容最小闭环

日期：2026-10-30。依据：ARCHITECTURE v0.8 §8–§11、§14、§18；UI-SPEC v1.3。

**通过条件（§18）**：新增文件 → 搜到 → 定位，全流程正确；在任意一步崩溃后重放，都不会损坏已经可用的索引。另按 §19 校准：普通内容查询到首屏已核验结果 P95 < 200 ms；小文本保存后队列空闲时 < 3 秒可搜。

## 可复用的 M0 资产

| 资产 | 位置 | M2 处理 |
|---|---|---|
| Unicode 17 归一化与偏移映射、C ABI | `rust/xs-core/src/normalize.rs`、`ffi.rs` | 直接使用；补批量与错误码 |
| 字节 trigram + 末尾特殊项、2 字节前缀区间、三模式核验、AND/OR/NOT 解析 | `index.rs`、`query.rs` | 改为产品 schema（§8.5），加取消、工作量预算、渐进返回、命中区间 |
| 暴力扫描对照集（16,992 次 0 差异） | `validation.rs`、`cli/xs` | 原样保留为回归测试 |
| 恢复协议验证器（11 个退出点） | `recovery.rs`、`cli/xs/tests/crash.rs` | 协议移植到产品写入端，测试保留并接入真实组件 |
| TXT/DOCX 提取、DOCX 锚点 | `extract.rs` | 加编码识别、大小与解压上限 |
| PDFKit 页文本与状态、DOC（NSAttributedString / textutil） | `native/m0/NativeProbe.swift` | 移入 ExtractionWorker |
| 签名主程序 → XPC → 子进程 | `native/m0/PermissionProbe.m` | 改为 IndexService.xpc + ExtractionWorker.xpc |

## 分块与顺序

每块都能单独测试和验收，后一块依赖前一块。

**M2-1 内容引擎（Rust）**
产品 schema：`file_id`、`revision`、`extractor_ver`、`norm_ver`、`scope_ids`、`dir_path`、`tri`、`display_text`（Zstd 16 KB + 块缓存）、`anchors`、`extract_state` 与页级状态、`extract_key`、`applied_seq`。写入端带 `index_instance_id` / `commit_batch_id` 的 commit payload。查询：字面召回 + 三模式核验、2 字节前缀区间、1 字节与重查询扫描正文（预算、取消、渐进返回）、命中区间与片段。Swift 接口按 §4 用 UniFFI（目前只有诊断用的 JSON C ABI）。
验收：M0 对照集 0 差异；取消与预算测试；合成 + 真实语料的延迟基线。

**M2-2 提取**
Rust：txt/代码（编码识别）、DOCX。Swift：PDFKit（页级 `partial_text` / `waiting_ocr`）、DOC（NSAttributedString，textutil 兜底）。ExtractionWorker.xpc：租约、超时强杀、退避、多次失败隔离；提取缓存键 = 强摘要 + 提取器版本 + 配置。
验收：M0 的 12 份真实样本结果不退化；坏文件、超大文件、超时注入测试。

**M2-3 任务流水线与提交协议**
目录数据库加 `in_content`、`op_seq`、任务表；内容范围变化、提取器升级写入 op_journal；`content` 消费者水位（与 M1 的 `name` 水位并列，日志按两者较小值清理）。IndexService.xpc 作为唯一写入者，实现 §9.3 全部步骤（序号表按实例隔离、单个未确认批次、提交前复核租约、结果不确定的两条路径、重建与实例切换）。
验收：M0 的 11 个退出点在真实组件上重跑；端到端“新建 → 可搜”时延；任意步骤强杀后重放一致。

**M2-4 界面**
内容模式（`in 词`、⌘2）：结果列表（片段、“N 处”、状态标签）、双栏预览（锚点、全部命中高亮、当前命中光圈、滚动条标记、⌘G / ⇧⌘G）、短查询与重查询提示条、“没有结果”的原因。名称与内容共用运算符解析（空格 / 引号 / `|` / `-`）。设置：内容范围卡片（首次推荐“下载”）、诊断页“为什么搜不到”。预览打开前核对文件版本，已变化则不画高亮并重新排队。
验收：UI-SPEC 第 4、6、7 节逐项走查；端到端“新建 → 搜到 → 定位”。

**M2-5 OCR 三项预留（§14）**
锚点模型预留 OCR 类型、页级提取状态、`extractor_ver` / `source` 字段与可暂停、感知电源与温度的调度器。随 M2-1～M2-3 一起落地，不单独成块。

## 风险

- 内容索引体积与首次提取耗时：M0 只测了 12 份真实文档，M2-1 做大语料基线后再定单文件上限的默认值。
- XPC 服务在自动化环境中无法 bootstrap（M0 已知），涉及 XPC 的端到端测试需要在正常用户会话中运行。
- 预览中 PDF 的字符级高亮依赖 PDFKit 文字层质量；文字层异常的页面按 `partial_text` 显示状态。

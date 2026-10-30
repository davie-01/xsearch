# XSearch

面向 macOS 26+ / Apple Silicon 的原生文件名与文件内容搜索应用。已完成 M0 技术验证、M1（名称与启动）和 **M2（内容搜索最小闭环）**，进度与证据见 `docs/m1/STATUS.md`、`docs/m2/STATUS.md`。

## M1 应用

```sh
bash scripts/swift-test.sh                                         # Swift 测试（含真实 FSEvents 端到端）
XS_SIGN_IDENTITY='你的 Apple Development 签名身份' bash scripts/build-app.sh
open target/XSearch.app                                            # 菜单栏常驻，⌥Space 呼出
```

源码：`App/`（AppKit 启动器、菜单栏、设置）、`Packages/XSearchCore`（查询语法、范围规则、文件名键）、`Packages/NameEngine`（内存索引、快照、C 扫描器）、`Packages/Catalog`（SQLite 目录、事件日志、FSEvents、对账、应用列表）。数据在 `~/Library/Application Support/XSearch`。

- 产品与实施方案：`docs/ARCHITECTURE.md`
- 已定稿界面：`docs/design/UI-SPEC.md`、`docs/design/prototype/`
- M0 结果与边界：`docs/m0/RESULTS.md`

## 当前可运行内容

`xs` Rust CLI：导入文本语料、字节 trigram 召回、三模式逐字核验、布尔查询、归一化、TXT/DOCX 提取、正确性对照、性能基线和故障注入。

`xs-core`：Tantivy 索引探针、Unicode 17 归一化和偏移映射、供 Swift 调用的 C ABI，以及使用真实 SQLite/WAL 与 Tantivy commit 的恢复协议验证器。

`native/m0`：Swift/PDFKit 提取与字符选择探针、旧版 DOC 提取探针、签名主程序 → XPC → 子进程只读访问探针。它们不是最终的 XSearch 界面或完整后台服务。

`bench/m0b`、`native/m0b`：M0-B 方案对比——文件名布局、stored fields 读取、布隆实际解压量（插桩的 Tantivy 副本，独立 workspace）、XPC 往返延迟、Vision OCR 小实验。复现方法见 `docs/m0/RESULTS.md` 第 6 节。

## 构建和测试

已验证环境：arm64、macOS 27.0.1、Swift 6.4、Rust 1.99.1。原生构建部署目标为 macOS 26；macOS 26 实机回归尚未执行。

本机 Rust 工具链安装在 `.tools/`，不修改用户的全局 PATH 或 shell 配置。新机器可使用已安装的 Rust stable；若使用项目内工具链，先在项目根目录执行：

```sh
source scripts/env.sh
cargo test --workspace --locked
cargo build --release --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
```

原生探针需要完整 Xcode/Swift SDK：

```sh
# 未指定签名身份时仅使用 ad-hoc；权限链路验收应使用自己的 Apple Development 身份。
XS_SIGN_IDENTITY='你的 Apple Development 签名身份' bash scripts/build-native.sh
```

一次重跑所有自动化 M0 验证，样本目录只读：

```sh
XS_SIGN_IDENTITY='你的 Apple Development 签名身份' \
  bash scripts/run-m0.sh '/只读样本目录'
```

先在正常用户终端运行权限探针，才能完成权限项验收（自动化沙箱会阻断 XPC bootstrap）：

```sh
bash scripts/run-permission-probe.command '/允许只读访问的样本文件'
```

结果写到 `work/m0/permission-user-session.json`。探针仅读取 16 字节并报告成功状态，不输出内容，也不自动更改系统权限。此测试验证当前账号对该目录的访问链路，不代表已验证完全磁盘访问、其他受保护目录、未挂载卷或发布公证。

`run-m0.sh` 在 `work/m0/runs/` 创建独立索引目录，避免重跑污染体积数据。原始提取文本、索引及真实样本清单只保存在忽略的 `work/m0/`，不会加入源码夹或公开报告。`scripts/m0-gate.py` 聚合当前测试结果；新增测试或验收条件时同步更新它。

## CLI 示例

```sh
target/release/xs help
target/release/xs validate work/m0/new-validation-run
target/release/xs extract Tests/Fixtures/m0/structure.docx
target/release/xs normalize Tests/Fixtures/m0/normalization.json
target/release/xs index work/m0/demo-index work/m0/real-corpus.json
target/release/xs search work/m0/demo-index '项目 -不存在' loose
target/release/xs search work/m0/demo-index '"数据共享" | AI' strict
```

语料 JSON 为 `[{"id":1,"name":"示例.txt","text":"正文"}]`。`index` 按 ID 更新输入文件，不删除本次输入缺失的旧 ID；要做新的全量导入，请使用新目录。`extract` 的输出包含正文，保存时应放在私有目录。

M0 查询语法：空格表示 AND，`|` 表示 OR，前置 `-` 表示 NOT，支持括号、双引号字面短语和反斜杠转义。应用界面的 `in` / `dir:` 语法、结果排序、分页、取消与诊断面板属于后续产品实现。本 CLI 不接受通配符或正则语义。

## 实现边界

- M0 为验证原理的最小实现：候选集目前完整收集到内存，性能测试只覆盖 12 份真实文档及合成集，不代表百万文件能力。
- 恢复验证器串行模拟文件/范围/配置事件；使用真实 SQLite/Tantivy 持久化，但尚未连接 FSEvents、文件身份检测、实际扫描器及异步提取调度器。M0 schema 不承诺升级兼容。
- 归一化和检索正确性以已提取文本为边界。DOCX 片段覆盖不是版面保真证明；嵌入对象、复杂修订、未知格式与 OCR 不属于这次交付。
- PDF 原始页文本保留不变，NUL/替换字符页标记为 `partial_text`，空白页标记为 `waiting_ocr`。启发式质量检测不能发现全部 PDF 编码或阅读顺序问题。
- C ABI 目前只用于统一归一化和映射，JSON 传输是 M0 诊断实现。产品接口的批量缓冲、取消、错误模型、版本与资源约束在 M1/M2 落实。
- Unicode 数据及依赖来源见 `THIRD_PARTY_NOTICES.md`。Cargo 包设为 `publish = false`；项目分发许可尚未指定。

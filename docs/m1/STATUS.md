# XSearch M1 进度：名称与启动

日期：2026-10-30。状态：**M1 完成**。启动器界面已按用户反馈改为 Spotlight 风格并经用户确认；设置页仍待人工走查（见第 4 节）。

## 1. 交付内容

| 交付（ARCHITECTURE §18） | 位置 | 状态 |
|---|---|---|
| 文件名引擎：目录块深度优先、名称驻留、排序键池、增量层、后台合并、快照 | `Packages/NameEngine/` | 完成，有对照测试 |
| `getattrlistbulk` 扫描器、`fsgetpath` 定位 | `Packages/NameEngine/CScan/` | 完成 |
| FileCatalog（SQLite WAL）、op_journal、FSEvents 断点续传、对账 | `Packages/Catalog/` | 完成，有端到端测试 |
| 查询语法 `dir:` / `ext:` / `kind:`、范围与排除规则 | `Packages/XSearchCore/` | 完成 |
| 文件名键：Rust 固定 Unicode 17 实现，经 C ABI 调用（D12） | `rust/xs-core/src/ffi.rs` `xs_name_key` | 完成 |
| 应用启动（不依赖 Spotlight） | `Packages/Catalog/Sources/AppCatalog.swift` | 完成 |
| NSPanel 启动器（Spotlight 风格：胶囊搜索框、液体分离的模式按钮、弹簧动画）、⌥Space、菜单栏、打开 / 在访达中显示 / 拖拽 / 快速查看 / 复制路径 | `App/Sources/` | 完成，用户已确认外观与动画 |
| 文件名范围设置（整盘 / 文件夹、排除规则、隐藏文件、包内容） | `App/Sources/Settings.swift` | 完成，待手动验收 |
| 最近打开、按使用次数排序（user.sqlite，与索引分开） | `Packages/Catalog/Sources/UsageStore.swift` | 完成 |

## 2. 构建与测试

```sh
bash scripts/swift-test.sh                         # Swift 单元 + 端到端测试
XS_BENCH=1 bash scripts/swift-test.sh -c release --filter benchMillionEntries
XS_SIGN_IDENTITY='Apple Development: …' bash scripts/build-app.sh   # 生成 target/XSearch.app
```

开发时可用 `XS_DATA_DIR=/临时目录 XS_NAME_ROOTS=/Applications,/Library` 启动 `target/XSearch.app/Contents/MacOS/XSearch`，不碰真实索引，也不触发受保护目录的授权弹窗。

## 3. 验收证据

**通过条件 1：重启后不需要重扫。** 启动时加载快照，回放数据库中比快照新的行，再从持久化的 FSEvents 事件 ID 继续，回放未应用的日志。测试 `restartReplaysHistoryWithoutRescan` 在停机期间新建、删除、改名，重启后结果正确、文件 ID 不变、全量扫描次数为 0；`recoversAfterCrashAndCorruptSnapshot` 覆盖未正常退出（快照过期）和快照损坏（从数据库重建，不扫盘）。实机冒烟：23.4 万项，停机期间的改动在重启后 0.3 秒内生效。

**通过条件 2：改名、移动、删除、原子保存都能正确更新。** `liveUpdatesKeepIdentity` 用真实 FSEvents 验证新建、改名（ID 不变）、跨目录移动、移动整个目录（子项路径跟随）、原子保存（inode 变化，ID 不变）、只改大小写、删除子树、实时创建的排除项。`changeInsideRenamedDirectory` 6 个确定性用例覆盖目录改名与内部改动的各种先后顺序、移走后原路径重建、删除后重建。`randomOperationsMatchDisk`：6 轮 × 40 次随机新建 / 删除 / 改名 / 移动 / 原子保存，每轮与磁盘遍历做完整集合对照，并要求全程没有触发兜底的全量对账；连续多次运行全部通过。

**通过条件 3：主线程不被阻塞。** 查询、应用扫描、最近打开读取都在后台队列；结果按请求序号只投递最新一次。目录、合并、快照写入在各自的串行队列。例外：设置中“重建文件名索引”和退出时会同步等待快照写入（数百毫秒）。

**正确性与性能**

| 项目 | 结果 |
|---|---|
| 引擎对照：4 个随机树 × 26 条查询 × 基础 / 增量层 / 后台合并 rebase / 快照读写往返 | 与暴力扫描完全一致；变异测试能发现错误 |
| 100 万条引擎耗时（release，含 2,000 条增量层） | 11 条查询 P95 为 6–32 ms，低于 80 ms 目标 |
| 首次扫描（/Applications、/System/Applications、/Library，23.4 万项） | 3.6 秒到快照落盘，约 6.5 万项/秒 |
| 快照体积 / 内存 | 23.4 万项约 25 MB；100 万项基础层约 79 MB |
| 真实整盘（本机默认范围） | 119,331 项（16,526 个目录），2 个无权限目录保留旧条目；快照 10 MB；数据目录 0700 |
| 测试 | Swift 20 项（核心 6、引擎 6 含默认跳过的基准、目录 8）；Rust 20 项、clippy 无警告 |

## 4. 尚未验证 / 已知限制

- 启动器按用户反馈改为 Spotlight 风格（UI-SPEC v1.3），动画参数由 Spotlight 录屏逐帧测得。设置页、拖拽、快速查看、浅色外观仍待人工走查。
- 整盘实测为 11.9 万项；百万文件规模的真实扫描耗时仍未测（合成 100 万条的引擎耗时见上表）。
- 已修复：目录数据库的 WAL 从不回写（缓存语句未 reset，一直持有读锁），本机 WAL 曾达 81 MB。现在每次提交后 reset 语句，快照写盘和退出时执行 `wal_checkpoint(TRUNCATE)`，测试覆盖。
- 使用 SwiftPM + 打包脚本构建，没有用 XcodeGen（本机未安装，避免改动全局环境）；以后加 `project.yml` 不影响代码结构。
- M1 中空格按 AND 处理，引号保留空格；`|`、`-`、通配符、正则按普通字符搜索（M2/M3）。
- “收窄”复用旧结果的优化没有实现：100 万条完整查询已在 35 ms 以内，按 M0 白名单规则以后再加。
- 外置卷、网络盘（`/Volumes`）不在 M1 范围内；默认排除。
- 内容模式（⌘2、`in 词`）只显示“下一个版本提供”。完整窗口、收藏、引导页不在 M1。
- 同一批事件中，一个目录在“自己的移动尚未被识别”时又被移到自己原来的子目录下这类极端情况，按推迟一轮处理；仍无法确定时，该批失败两次后会跳过并对全部范围做一次全量对账（不会卡住流水线）。

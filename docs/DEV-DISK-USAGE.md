# 开发期间的磁盘占用清单（2026-11-01 实测）

测量方法：`du -sh` 实测。只统计这个项目在开发过程中产生的文件；其他应用的数据不计入。运行时用到的位置另见 [STORAGE.md](STORAGE.md)。

## 1. 汇总

| 位置 | 清理前 | 现在 | 性质 |
|---|---|---|---|
| 项目目录 `XSearch/` | 15 GB | 15 GB | 其中 14 GB 是可重新生成的编译产物 `target/` |
| 系统临时目录 `$TMPDIR` 里的测试残留 | **8.2 GB** | 0.26 MB | 已清理（见 §3） |
| 本次开发会话的临时目录 `/private/tmp/claude-501` | 550 MB | 550 MB | 截图、后台任务日志，重启后由系统清除 |
| 编译器模块缓存（`$DARWIN_USER_CACHE_DIR/clang`、`~/Library/Caches/org.swift.swiftpm`） | 296 MB | 296 MB | 可重新生成 |
| 应用数据 `~/Library/Application Support/XSearch` | 56 MB | 56 MB | 真实使用的索引和个人数据 |
| 崩溃报告（`xs-extract` 25 份，XSearch 3 份） | 0.7 MB | 0.7 MB | 已停止新增（见 §3） |
| **合计** | **约 24 GB** | **约 16 GB** | |

磁盘可用空间：清理前 45 GB，清理后 53 GB（总容量 995 GB）。

## 2. 项目目录明细（15 GB）

| 路径 | 大小 | 是什么 | 为什么这么大 | 能否删除 |
|---|---|---|---|---|
| `target/debug/` | **11 GB** | Rust 的调试构建：`cargo test`、`cargo clippy`、各 `examples` 的产物 | `deps/` 8.1 GB：每个 crate 的测试可执行文件、rlib，以及按代码生成单元拆分的大量 `.o`（xs-core 约 5,900 个文件、xs-parsers 约 4,900 个，增量编译不断累积）；Tantivy、calamine、zip、7z、unrar（C++）等依赖都各编一份带调试信息的版本；`incremental/` 2 GB 是增量编译缓存；`examples/` 309 MB | 可以：`cargo clean --profile dev`，下次跑测试会重新编译（约几分钟） |
| `target/release/` | 2.0 GB | Rust 的发布构建：应用链接的 `libxs_ffi.a`（73 MB）、基准和探测工具 | `deps/` 1.7 GB：同上，但开了优化 | 可以：`cargo clean --release`，下次打包时重新编译 |
| `target/swift/` | 1.1 GB | SwiftPM 的构建目录（debug 和 release，以及测试包） | 预编译的 SDK 模块 271 MB、模块缓存 220 MB、产物 466 MB | 可以：`rm -rf target/swift`，下次构建重新生成 |
| `target/XSearch.app`、`target/*.dmg` | 47 MB + 34 MB | 打包好的应用和 DMG（0.1.0、0.1.1 测试版） | — | 可以，随时能重新打包 |
| `.tools/` | 1.0 GB | 项目内的 Rust 工具链（rustup 463 MB）、cargo 依赖源码缓存（432 MB）、Sparkle（107 MB） | 按约定不改动全局环境，所以工具链装在项目内 | **保留**（删了要重新下载才能编译） |
| `work/` | 571 MB | 已加入 .gitignore 的验证输出：M0 的测试语料、基准索引（376 MB）、M2 的提取验证（113 MB）、M0-B（81 MB）、M4 统计、回归测试的输出 | 基准用的合成语料和索引 | 可以删除 M0 / M0-B 的中间结果（结论已写进 docs）；含真实样本统计的部分只在本机 |
| 源码、文档、测试样例（`App`、`Packages`、`rust`、`docs`、`Tests`、`.git`…） | 约 4 MB | — | — | 保留 |

## 3. 已发现并修正的“垃圾来源”

1. **测试沙盒残留 8.2 GB**（已清理）：
   - 文件名引擎和目录数据库的测试会在 `$TMPDIR/xs-catalog-<名称>-<pid>-<随机数>/` 建临时目录，测试结束时删除；但测试一旦被超时强制结束（`perl alarm`），就来不及删。累计留下 43 个。
   - 其中两个 `xs-catalog-random-*` 各有一个 **4.8 GB 和 3.8 GB 的 `catalog.sqlite-wal`**，来自 10 月 30 日上午，即 M1 中“WAL 从不回写”那个问题还没修好时（缓存的查询语句没有 reset，一直持有读锁，WAL 无法回写，只能不断增长）。那个问题当天已修复，残留文件一直留着。
   - 修正：测试沙盒创建时，自动删除超过 6 小时的旧沙盒（这次运行时已删除全部 43 个）。
2. **崩溃报告**：提取进程的“崩溃注入”测试用 `abort()`，每跑一次，系统就生成一份 `xs-extract-….ips`。改为 `SIGKILL`：被测的监督逻辑看到的效果相同，但系统不再写报告。
3. **从压缩包打开的文件**：`$TMPDIR/XSearch-open/` 原来不会清理，现在应用启动时删除超过一天的。

## 4. 为什么你感觉有 40 多 GB

实测能确认是这个项目产生的，合计约 24 GB。剩下的差距可能来自以下几处，它们都无法按目录用 `du` 测出来：

- **Spotlight 索引**：macOS 默认会索引 `~/Documents` 下的项目目录，`target/` 里几万个编译中间文件也会被反复索引，索引存放在 `/System/Volumes/Data/.Spotlight-V100`（需要管理员权限才能查看大小）。建议在 系统设置 › Spotlight › 隐私（或“搜索隐私”）中加入 `XSearch/target`。
- **已删除文件的空间延迟回收**：APFS 和“可清除”空间的统计会滞后，访达里显示的可用空间不一定是实时的。
- **开发期间的其他工具**：Xcode、浏览器缓存、其他应用的数据，这些不在这次统计范围内。

需要精确核对的话，可以在终端运行 `sudo du -sh /System/Volumes/Data/.Spotlight-V100`，或者在 关于本机 › 储存空间 里看“系统数据”的大小。

## 5. 一键清理（全部可重新生成，不影响源码、文档和应用数据）

```bash
cd ~/Documents/Private/Code/XSearch
source scripts/env.sh
cargo clean --profile dev          # 约 11 GB：Rust 调试构建
cargo clean --release              # 约 2 GB：Rust 发布构建（下次打包重新编译）
rm -rf target/swift                # 约 1.1 GB：SwiftPM 构建
rm -rf work/m0 work/m0b            # 约 0.46 GB：M0 / M0-B 中间结果
```

清理后，下次运行 `scripts/build-app.sh` 或测试会重新编译，第一次需要几分钟。只想腾出最多空间的话，执行第一条就够了。

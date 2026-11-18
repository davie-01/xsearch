# XSearch 第三方许可

本清单对应 XSearch 提交 `ca30e7e`。它覆盖主 Rust 工作区锁定的 **249 个第三方 crate 版本**、M0-B 独立工作区的 **176 个锁定 crate 版本**（与主工作区重复的版本共用同一条记录），以及 Rust 锁文件以外随应用使用或随源码分发的组件和素材。第三方材料保留各自的许可与版权声明。XSearch 原创代码采用 GPL 第 3 版，附 UnRAR 链接例外。[GPLv3 原文](LICENSE) · [链接例外](LICENSES/XSearch-UnRAR-linking-exception.md)

## UnRAR 与 GPLv3 发行

当前 `xs-parsers → unrar → unrar_sys` 会编译 RARLAB 的 UnRAR 源码并静态链接到 `libxs_ffi.a`。Rust 包装层使用 `MIT OR Apache-2.0`。UnRAR 原生代码适用单独的 **UnRAR License**，限制使用其源码重建 RAR 压缩算法或开发兼容的压缩工具。[UnRAR 许可原文](LICENSES/UnRAR-license.txt) · [RARLAB 源码下载](https://www.rarlab.com/rar_add.htm)

XSearch 版权人依据 GPLv3 第 7 节授予额外许可，允许把 XSearch 与指定的 UnRAR 实现链接并分发组合成果。该例外适用于 XSearch 授权，UnRAR 本身仍遵守 UnRAR License。分发组合二进制时，按照例外文本提供实际上使用的 UnRAR 源码和 GPLv3 对应源码。[XSearch UnRAR 链接例外](LICENSES/XSearch-UnRAR-linking-exception.md) · [GNU GPLv3 第 7 节](https://www.gnu.org/licenses/gpl-3.0.html#section7)

## 框架、嵌入代码与第三方数据

| 名称与版本 | 使用位置或用途 | 许可 | 上游项目、下载地址或原文 |
| --- | --- | --- | --- |
| Sparkle 2.10.0 | 应用内更新框架及其辅助程序。构建下载固定版本并校验归档 SHA-256，打包时重新签名。 | MIT | [2.10.0 发布页](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0) · [该版本许可原文](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE) |
| bsdiff / bspatch 4.3 | Sparkle 自带的增量补丁组件。 | BSD-2-Clause | [上游项目](https://www.daemonology.net/bsdiff/) · [Sparkle 所附许可](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE) |
| sais-lite（2010-08-07） | Sparkle 自带的后缀数组实现。 | MIT | [上游项目](https://sites.google.com/site/yuta256/sais) · [Sparkle 所附许可](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE) |
| Portable C Ed25519 | Sparkle 自带的 Orson Peters 签名实现。 | zlib 风格条款（以 Sparkle 收录文本为准） | [上游项目](https://github.com/orlp/ed25519) · [Sparkle 所附许可](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE) |
| Mark Hamlin 的 SUSignatureVerifier.m | Sparkle 所附许可列出的签名校验代码。 | BSD-2-Clause | [Sparkle 2.10.0 许可原文](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE) |
| UniFFI 0.29.5 | 生成 Swift 和 C 绑定，并提供 Rust 桥接运行时代码。生成物及脚本位置见设计文档。分发时保留所用 MPL 文件的声明，按 MPL-2.0 第 3 节提供适用的源码。 | MPL-2.0 | [上游项目](https://github.com/mozilla/uniffi-rs) · [MPL 原文](https://www.mozilla.org/en-US/MPL/2.0/) |
| Unicode CaseFolding 17.0.0 | `Tests/Fixtures/m0/CaseFolding-17.0.0.txt`。Rust 构建时用它生成默认大小写折叠表。许可副本在 `Tests/Fixtures/m0/licenses/UNICODE-LICENSE.txt`。 | Unicode-3.0 | [Unicode 数据](https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt) · [Unicode 许可](https://www.unicode.org/license.txt) |
| Unicode 正则字符表 | `regex-syntax` 随包提供的生成表，许可在其 `src/unicode_tables/LICENSE-UNICODE`。 | Unicode 数据文件和软件许可（包内收录文本） | [regex-syntax 0.8.11 源码与许可文件](https://docs.rs/crate/regex-syntax/0.8.11/source/src/unicode_tables/LICENSE-UNICODE) |
| UnRAR 源码（内置版头标记 7.1） | `unrar_sys 0.5.8` 的 `vendor/unrar`，通过 C++ 编译到应用依赖里。 | UnRAR License，含额外使用限制 | [RARLAB](https://www.rarlab.com/rar_add.htm) · [所用源码包许可](https://docs.rs/crate/unrar_sys/0.5.8/source/vendor/unrar/license.txt) |
| RAR 测试数据 `version.rar` | 从 `unrar 0.5.8` 取得，位于 `Tests/Fixtures/m4/rar/`。 | MIT OR Apache-2.0（随样本来源声明） | [样本上游](https://github.com/muja/unrar.rs) |
| RAR 测试数据 `crypted.rar` | 从 `unrar 0.5.8` 取得，位于 `Tests/Fixtures/m4/rar/`。 | MIT OR Apache-2.0（随样本来源声明） | [样本上游](https://github.com/muja/unrar.rs) |
| SQLite 3.50.2 | Rust 的 `libsqlite3-sys 0.35.0` 以 bundled 特性编译的 C 源码。Swift Catalog 也使用 macOS 提供的 SQLite。 | 公有领域（SQLite 核心源码） | [源码版权说明](https://www.sqlite.org/copyright.html) · [所用 C 源码](https://docs.rs/crate/libsqlite3-sys/0.35.0/source/sqlite3/sqlite3.c) |
| Zstandard 1.5.7 | `zstd-sys` 内置 C 源码，用于 Tantivy 压缩存储。 | BSD-3-Clause OR GPL-2.0-only，构建可使用 BSD-3-Clause 条款 | [v1.5.7 授权说明](https://github.com/facebook/zstd/tree/v1.5.7#license) |
| libbzip2 的 Rust 移植 | `libbz2-rs-sys` 的上游 C 源码来源，随对应 crate 的 Rust 移植使用。 | bzip2-1.0.6 | [移植项目](https://github.com/trifectatechfoundation/libbzip2-rs) · [原始项目](https://sourceware.org/bzip2/) |
| 7-Zip PPMd 代码与原始算法实现 | `ppmd-rust` 上游声明的代码来源。 | 原始来源为公有领域，Rust 移植为 CC0-1.0 OR MIT-0 | [移植项目的致谢和许可](https://github.com/hasenbanck/ppmd-rust) |
| librustdoc HTML 模板 | `askama_parser` 上游源码包的基准测试素材。 | MIT OR Apache-2.0 | [该版本所附声明](https://docs.rs/crate/askama_parser/0.13.0/source/benches/librustdoc/LICENSE.md) |
| SQLCipher | `libsqlite3-sys` 发布包附带的可选源码。当前 `bundled` 构建选用 SQLite。 | BSD-3-Clause | [上游项目](https://github.com/sqlcipher/sqlcipher) · [所附许可](https://docs.rs/crate/libsqlite3-sys/0.35.0/source/sqlcipher/LICENSE) |
| 经插桩的 Tantivy 0.27.0 | `bench/m0b/Cargo.toml` 指向 `work/m0b/tantivy-instrumented`。脚本从同版本 crate 准备实验副本，`work/` 由 Git 忽略。 | MIT | [上游项目](https://github.com/quickwit-oss/tantivy) · [锁定版本](https://crates.io/crates/tantivy/0.27.0) |

Sparkle 许可原文还随下载的框架资源提供。文档内的架构调研项目仅用于解释技术选型。公共文档使用合成示例，仓库的项目自制测试素材另行维护。

## macOS 平台、开发工具与可选集成

| 名称 | 用途 | 许可或分发关系 | 上游地址 |
| --- | --- | --- | --- |
| macOS 与 Apple 系统 SDK | AppKit、SwiftUI、Foundation、PDFKit、Quartz / Quick Look、CoreServices / FSEvents、Carbon HIToolbox、ApplicationServices、ImageIO、CryptoKit、ServiceManagement、UniformTypeIdentifiers、Darwin、系统日志和 XPC。原生探针另用 Vision。 | 随系统或 SDK 提供，适用 Apple 对应条款 | [Apple SDK 文档](https://developer.apple.com/documentation/) · [Apple 许可页面](https://www.apple.com/legal/sla/) |
| Apple 系统 SQLite | Swift 文件目录与个人数据存储。 | SQLite 核心为公有领域，系统构建随 macOS 提供 | [SQLite 版权说明](https://www.sqlite.org/copyright.html) |
| 系统 libz | 链接 macOS 提供的压缩库。 | Zlib（上游），系统构建随 macOS 提供 | [zlib 许可](https://zlib.net/zlib_license.html) |
| 系统 libc++ | Rust 静态库中 C++ 依赖的运行时。 | Apache-2.0 WITH LLVM-exception（LLVM 上游），系统构建随 macOS 提供 | [LLVM 许可](https://llvm.org/LICENSE.txt) |
| Apple Xcode 与命令行工具 | 编译、`actool`、`codesign`、`hdiutil` 及 `textutil` 等构建或系统调用。 | 适用对应 Apple 工具、SDK 或系统条款 | [Xcode](https://developer.apple.com/xcode/) · [Apple 开发许可协议](https://developer.apple.com/support/terms/) |
| Swift、SwiftPM、Swift Testing | Swift 构建、依赖与测试。应用构建使用 Xcode 工具链。 | Apache-2.0 WITH Swift-exception（上游） | [Swift](https://github.com/swiftlang/swift) · [SwiftPM](https://github.com/swiftlang/swift-package-manager) · [Swift Testing](https://github.com/swiftlang/swift-testing) |
| Rust 与 Cargo | 编译 Rust 引擎和锁定、构建依赖。 | MIT OR Apache-2.0（上游主许可） | [Rust](https://github.com/rust-lang/rust) · [Cargo](https://github.com/rust-lang/cargo) |
| Python 3 | 回归测试、合成样本和开发探针脚本，使用标准库。 | PSF-2.0（上游主许可） | [Python 许可](https://docs.python.org/3/license.html) |
| Skim | 可选的外部 PDF 阅读器，利用已安装副本的 AppleScript 接口跳页。 | BSD，独立安装 | [Skim 官方项目](https://sourceforge.net/projects/skim-app/) |
| Apple「预览」与 Finder | 使用系统应用显示原文或定位文件。 | 随 macOS 提供，适用 Apple 条款 | [预览使用手册](https://support.apple.com/zh-cn/guide/preview/welcome/mac) · [Finder 使用说明](https://support.apple.com/zh-cn/guide/mac-help/mchlp2605/mac) |

## Rust 依赖逐项清单

版本以两份 `Cargo.lock` 为准，许可按该版本 crate 的 `Cargo.toml` 记录。上游链接指向对应的 crates.io 版本页。旧式斜杠写法按原样保留。`OR` 表示可选择的许可，`AND` 表示同时适用的条件。

“应用构建图”表示该项出现在 `aarch64-apple-darwin` 下 `xs-ffi` 的普通或构建依赖树中，包含构建脚本和过程宏。主锁文件的其余条目可能用于其他平台、测试或其他目标。M0-B 栏表示该版本也登记在独立基准工作区的锁文件中。实际二进制的许可材料需要按发行产物核对。

| 名称 | 版本与来源 | 许可 | 所在锁文件 | 应用构建图 |
| --- | --- | --- | --- | --- |
| `adler2` | [2.0.1](https://crates.io/crates/adler2/2.0.1) | `0BSD OR MIT OR Apache-2.0` | 主、M0-B | 是 |
| `aes` | [0.9.3](https://crates.io/crates/aes/0.9.3) | `MIT OR Apache-2.0` | 主 | 是 |
| `aho-corasick` | [1.1.5](https://crates.io/crates/aho-corasick/1.1.5) | `Unlicense OR MIT` | 主、M0-B | 是 |
| `anstyle` | [1.0.14](https://crates.io/crates/anstyle/1.0.14) | `MIT OR Apache-2.0` | 主 | 是 |
| `anyhow` | [1.0.104](https://crates.io/crates/anyhow/1.0.104) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `arbitrary` | [1.5.0](https://crates.io/crates/arbitrary/1.5.0) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `arc-swap` | [1.9.3](https://crates.io/crates/arc-swap/1.9.3) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `askama` | [0.13.1](https://crates.io/crates/askama/0.13.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `askama_derive` | [0.13.1](https://crates.io/crates/askama_derive/0.13.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `askama_parser` | [0.13.0](https://crates.io/crates/askama_parser/0.13.0) | `MIT OR Apache-2.0` | 主 | 是 |
| `async-trait` | [0.1.92](https://crates.io/crates/async-trait/0.1.92) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `atoi_simd` | [0.16.1](https://crates.io/crates/atoi_simd/0.16.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `autocfg` | [1.5.1](https://crates.io/crates/autocfg/1.5.1) | `Apache-2.0 OR MIT` | 主、M0-B | 是 |
| `base64` | [0.23.1](https://crates.io/crates/base64/0.23.1) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `basic-toml` | [0.1.10](https://crates.io/crates/basic-toml/0.1.10) | `MIT OR Apache-2.0` | 主 | 是 |
| `bitflags` | [2.13.2](https://crates.io/crates/bitflags/2.13.2) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `bitpacking` | [0.9.3](https://crates.io/crates/bitpacking/0.9.3) | `MIT` | 主、M0-B | 是 |
| `block-buffer` | [0.12.1](https://crates.io/crates/block-buffer/0.12.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `block-padding` | [0.4.2](https://crates.io/crates/block-padding/0.4.2) | `MIT OR Apache-2.0` | 主 | 是 |
| `bon` | [3.10.3](https://crates.io/crates/bon/3.10.3) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `bon-macros` | [3.10.3](https://crates.io/crates/bon-macros/3.10.3) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `bumpalo` | [3.20.3](https://crates.io/crates/bumpalo/3.20.3) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `byteorder` | [1.5.0](https://crates.io/crates/byteorder/1.5.0) | `Unlicense OR MIT` | 主、M0-B | 是 |
| `bytes` | [1.12.1](https://crates.io/crates/bytes/1.12.1) | `MIT` | 主 | 是 |
| `bzip2` | [0.6.1](https://crates.io/crates/bzip2/0.6.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `calamine` | [0.30.1](https://crates.io/crates/calamine/0.30.1) | `MIT` | 主 | 是 |
| `camino` | [1.2.6](https://crates.io/crates/camino/1.2.6) | `MIT OR Apache-2.0` | 主 | 是 |
| `cargo-platform` | [0.1.9](https://crates.io/crates/cargo-platform/0.1.9) | `MIT OR Apache-2.0` | 主 | 是 |
| `cargo_metadata` | [0.19.2](https://crates.io/crates/cargo_metadata/0.19.2) | `MIT` | 主 | 是 |
| `cbc` | [0.2.1](https://crates.io/crates/cbc/0.2.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `cc` | [1.10.0](https://crates.io/crates/cc/1.10.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `census` | [0.4.2](https://crates.io/crates/census/0.4.2) | `MIT` | 主、M0-B | 是 |
| `cfb` | [0.15.0](https://crates.io/crates/cfb/0.15.0) | `MIT` | 主 | 是 |
| `cfg-if` | [1.0.5](https://crates.io/crates/cfg-if/1.0.5) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `cipher` | [0.5.2](https://crates.io/crates/cipher/0.5.2) | `MIT OR Apache-2.0` | 主 | 是 |
| `clap` | [4.6.7](https://crates.io/crates/clap/4.6.7) | `MIT OR Apache-2.0` | 主 | 是 |
| `clap_builder` | [4.6.7](https://crates.io/crates/clap_builder/4.6.7) | `MIT OR Apache-2.0` | 主 | 是 |
| `clap_derive` | [4.6.7](https://crates.io/crates/clap_derive/4.6.7) | `MIT OR Apache-2.0` | 主 | 是 |
| `clap_lex` | [1.1.1](https://crates.io/crates/clap_lex/1.1.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `codepage` | [0.1.3](https://crates.io/crates/codepage/0.1.3) | `Apache-2.0 OR MIT` | 主 | 是 |
| `const-oid` | [0.10.2](https://crates.io/crates/const-oid/0.10.2) | `Apache-2.0 OR MIT` | 主 | 是 |
| `core_detect` | [1.0.0](https://crates.io/crates/core_detect/1.0.0) | `MIT/Apache-2.0` | 主、M0-B | — |
| `cpubits` | [0.1.1](https://crates.io/crates/cpubits/0.1.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `cpufeatures` | [0.3.1](https://crates.io/crates/cpufeatures/0.3.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `crc32fast` | [1.5.3](https://crates.io/crates/crc32fast/1.5.3) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `crossbeam-channel` | [0.5.17](https://crates.io/crates/crossbeam-channel/0.5.17) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `crossbeam-deque` | [0.8.8](https://crates.io/crates/crossbeam-deque/0.8.8) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `crossbeam-epoch` | [0.9.21](https://crates.io/crates/crossbeam-epoch/0.9.21) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `crossbeam-utils` | [0.8.23](https://crates.io/crates/crossbeam-utils/0.8.23) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `crunchy` | [0.2.4](https://crates.io/crates/crunchy/0.2.4) | `MIT` | 主、M0-B | 是 |
| `crypto-common` | [0.2.2](https://crates.io/crates/crypto-common/0.2.2) | `MIT OR Apache-2.0` | 主 | 是 |
| `darling` | [0.24.1](https://crates.io/crates/darling/0.24.1) | `MIT` | 主、M0-B | 是 |
| `darling_core` | [0.24.1](https://crates.io/crates/darling_core/0.24.1) | `MIT` | 主、M0-B | 是 |
| `darling_macro` | [0.24.1](https://crates.io/crates/darling_macro/0.24.1) | `MIT` | 主、M0-B | 是 |
| `datasketches` | [0.5.0](https://crates.io/crates/datasketches/0.5.0) | `Apache-2.0` | 主、M0-B | 是 |
| `debug_unsafe` | [0.1.4](https://crates.io/crates/debug_unsafe/0.1.4) | `MIT OR Apache-2.0` | 主 | 是 |
| `deranged` | [0.5.9](https://crates.io/crates/deranged/0.5.9) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `derive_arbitrary` | [1.5.0](https://crates.io/crates/derive_arbitrary/1.5.0) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `digest` | [0.11.3](https://crates.io/crates/digest/0.11.3) | `MIT OR Apache-2.0` | 主 | 是 |
| `downcast-rs` | [2.0.2](https://crates.io/crates/downcast-rs/2.0.2) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `either` | [1.19.0](https://crates.io/crates/either/1.19.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `encoding_rs` | [0.8.42](https://crates.io/crates/encoding_rs/0.8.42) | `(Apache-2.0 OR MIT) AND BSD-3-Clause` | 主、M0-B | 是 |
| `equivalent` | [1.0.3](https://crates.io/crates/equivalent/1.0.3) | `Apache-2.0 OR MIT` | 主、M0-B | 是 |
| `erased-serde` | [0.4.11](https://crates.io/crates/erased-serde/0.4.11) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `errno` | [0.3.14](https://crates.io/crates/errno/0.3.14) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `fallible-iterator` | [0.3.0](https://crates.io/crates/fallible-iterator/0.3.0) | `MIT/Apache-2.0` | 主、M0-B | 是 |
| `fallible-streaming-iterator` | [0.1.9](https://crates.io/crates/fallible-streaming-iterator/0.1.9) | `MIT/Apache-2.0` | 主、M0-B | 是 |
| `fast-float2` | [0.2.4](https://crates.io/crates/fast-float2/0.2.4) | `MIT OR Apache-2.0` | 主 | 是 |
| `fastdivide` | [0.4.2](https://crates.io/crates/fastdivide/0.4.2) | `zlib-acknowledgement OR MIT` | 主、M0-B | 是 |
| `fastrand` | [2.5.0](https://crates.io/crates/fastrand/2.5.0) | `Apache-2.0 OR MIT` | 主、M0-B | 是 |
| `filetime` | [0.2.29](https://crates.io/crates/filetime/0.2.29) | `MIT/Apache-2.0` | 主 | 是 |
| `find-msvc-tools` | [0.1.15](https://crates.io/crates/find-msvc-tools/0.1.15) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `flate2` | [1.1.10](https://crates.io/crates/flate2/1.1.10) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `fnv` | [1.0.7](https://crates.io/crates/fnv/1.0.7) | `Apache-2.0 / MIT` | 主、M0-B | 是 |
| `foldhash` | [0.1.5](https://crates.io/crates/foldhash/0.1.5) | `Zlib` | 主、M0-B | 是 |
| `foldhash` | [0.2.0](https://crates.io/crates/foldhash/0.2.0) | `Zlib` | 主、M0-B | 是 |
| `frostem` | [1.20260821.8](https://crates.io/crates/frostem/1.20260821.8) | `BSD-3-Clause` | 主、M0-B | 是 |
| `fs-err` | [2.11.0](https://crates.io/crates/fs-err/2.11.0) | `MIT/Apache-2.0` | 主 | 是 |
| `fs4` | [0.13.1](https://crates.io/crates/fs4/0.13.1) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `futures-core` | [0.3.34](https://crates.io/crates/futures-core/0.3.34) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `futures-macro` | [0.3.34](https://crates.io/crates/futures-macro/0.3.34) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `futures-task` | [0.3.34](https://crates.io/crates/futures-task/0.3.34) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `futures-util` | [0.3.34](https://crates.io/crates/futures-util/0.3.34) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `getrandom` | [0.3.4](https://crates.io/crates/getrandom/0.3.4) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `getrandom` | [0.4.3](https://crates.io/crates/getrandom/0.4.3) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `glob` | [0.3.4](https://crates.io/crates/glob/0.3.4) | `MIT OR Apache-2.0` | 主 | 是 |
| `goblin` | [0.8.2](https://crates.io/crates/goblin/0.8.2) | `MIT` | 主 | 是 |
| `hashbrown` | [0.15.5](https://crates.io/crates/hashbrown/0.15.5) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `hashbrown` | [0.17.1](https://crates.io/crates/hashbrown/0.17.1) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `hashlink` | [0.10.0](https://crates.io/crates/hashlink/0.10.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `heck` | [0.5.0](https://crates.io/crates/heck/0.5.0) | `MIT OR Apache-2.0` | 主 | 是 |
| `htmlescape` | [0.3.1](https://crates.io/crates/htmlescape/0.3.1) | `Apache-2.0 / MIT / MPL-2.0` | 主、M0-B | 是 |
| `hybrid-array` | [0.4.15](https://crates.io/crates/hybrid-array/0.4.15) | `MIT OR Apache-2.0` | 主 | 是 |
| `ident_case` | [1.0.1](https://crates.io/crates/ident_case/1.0.1) | `MIT/Apache-2.0` | 主、M0-B | 是 |
| `indexmap` | [2.14.2](https://crates.io/crates/indexmap/2.14.2) | `Apache-2.0 OR MIT` | 主、M0-B | 是 |
| `inout` | [0.2.5](https://crates.io/crates/inout/0.2.5) | `MIT OR Apache-2.0` | 主 | 是 |
| `inventory` | [0.3.25](https://crates.io/crates/inventory/0.3.25) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `itertools` | [0.14.0](https://crates.io/crates/itertools/0.14.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `itoa` | [1.0.18](https://crates.io/crates/itoa/1.0.18) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `jobserver` | [0.1.35](https://crates.io/crates/jobserver/0.1.35) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `js-sys` | [0.3.106](https://crates.io/crates/js-sys/0.3.106) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `levenshtein_automata` | [0.2.1](https://crates.io/crates/levenshtein_automata/0.2.1) | `MIT` | 主、M0-B | 是 |
| `libbz2-rs-sys` | [0.2.6](https://crates.io/crates/libbz2-rs-sys/0.2.6) | `bzip2-1.0.6` | 主 | 是 |
| `libc` | [0.2.191](https://crates.io/crates/libc/0.2.191) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `libsqlite3-sys` | [0.35.0](https://crates.io/crates/libsqlite3-sys/0.35.0) | `MIT` | 主、M0-B | 是 |
| `linux-raw-sys` | [0.12.1](https://crates.io/crates/linux-raw-sys/0.12.1) | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` | 主、M0-B | — |
| `log` | [0.4.34](https://crates.io/crates/log/0.4.34) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `lru` | [0.18.5](https://crates.io/crates/lru/0.18.5) | `MIT` | 主、M0-B | 是 |
| `lz4_flex` | [0.14.0](https://crates.io/crates/lz4_flex/0.14.0) | `MIT` | 主、M0-B | 是 |
| `lzma-rust2` | [0.23.0](https://crates.io/crates/lzma-rust2/0.23.0) | `Apache-2.0` | 主 | 是 |
| `measure_time` | [0.9.0](https://crates.io/crates/measure_time/0.9.0) | `MIT` | 主、M0-B | 是 |
| `memchr` | [2.8.3](https://crates.io/crates/memchr/2.8.3) | `Unlicense OR MIT` | 主、M0-B | 是 |
| `memmap2` | [0.9.12](https://crates.io/crates/memmap2/0.9.12) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `minimal-lexical` | [0.2.1](https://crates.io/crates/minimal-lexical/0.2.1) | `MIT/Apache-2.0` | 主、M0-B | 是 |
| `miniz_oxide` | [0.9.1](https://crates.io/crates/miniz_oxide/0.9.1) | `MIT OR Zlib OR Apache-2.0` | 主、M0-B | 是 |
| `multiversion_no_op` | [1.0.0](https://crates.io/crates/multiversion_no_op/1.0.0) | `Apache-2.0 OR MIT` | 主、M0-B | 是 |
| `murmurhash32` | [0.4.0](https://crates.io/crates/murmurhash32/0.4.0) | `MIT` | 主、M0-B | 是 |
| `nom` | [7.1.3](https://crates.io/crates/nom/7.1.3) | `MIT` | 主、M0-B | 是 |
| `num-conv` | [0.2.2](https://crates.io/crates/num-conv/0.2.2) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `num-traits` | [0.2.19](https://crates.io/crates/num-traits/0.2.19) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `once_cell` | [1.21.4](https://crates.io/crates/once_cell/1.21.4) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `oneshot` | [0.1.13](https://crates.io/crates/oneshot/0.1.13) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `ordered-float` | [5.5.1](https://crates.io/crates/ordered-float/5.5.1) | `MIT` | 主、M0-B | 是 |
| `ownedbytes` | [0.9.0](https://crates.io/crates/ownedbytes/0.9.0) | `MIT` | 主、M0-B | 是 |
| `percent-encoding` | [2.3.2](https://crates.io/crates/percent-encoding/2.3.2) | `MIT OR Apache-2.0` | 主 | — |
| `pin-project-lite` | [0.2.17](https://crates.io/crates/pin-project-lite/0.2.17) | `Apache-2.0 OR MIT` | 主、M0-B | 是 |
| `pkg-config` | [0.3.34](https://crates.io/crates/pkg-config/0.3.34) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `plain` | [0.2.3](https://crates.io/crates/plain/0.2.3) | `MIT/Apache-2.0` | 主 | 是 |
| `powerfmt` | [0.2.1](https://crates.io/crates/powerfmt/0.2.1) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `ppmd-rust` | [1.5.2](https://crates.io/crates/ppmd-rust/1.5.2) | `CC0-1.0 OR MIT-0` | 主 | 是 |
| `ppv-lite86` | [0.2.21](https://crates.io/crates/ppv-lite86/0.2.21) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `prettyplease` | [0.3.0](https://crates.io/crates/prettyplease/0.3.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `proc-macro2` | [1.0.107](https://crates.io/crates/proc-macro2/1.0.107) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `quick-xml` | [0.37.5](https://crates.io/crates/quick-xml/0.37.5) | `MIT` | 主 | 是 |
| `quote` | [1.0.47](https://crates.io/crates/quote/1.0.47) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `r-efi` | [5.3.0](https://crates.io/crates/r-efi/5.3.0) | `MIT OR Apache-2.0 OR LGPL-2.1-or-later` | 主、M0-B | — |
| `r-efi` | [6.0.0](https://crates.io/crates/r-efi/6.0.0) | `MIT OR Apache-2.0 OR LGPL-2.1-or-later` | 主、M0-B | — |
| `rand` | [0.9.5](https://crates.io/crates/rand/0.9.5) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `rand_chacha` | [0.9.0](https://crates.io/crates/rand_chacha/0.9.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `rand_core` | [0.9.5](https://crates.io/crates/rand_core/0.9.5) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `rayon` | [1.12.0](https://crates.io/crates/rayon/1.12.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `rayon-core` | [1.13.0](https://crates.io/crates/rayon-core/1.13.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `regex` | [1.13.1](https://crates.io/crates/regex/1.13.1) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `regex-automata` | [0.4.18](https://crates.io/crates/regex-automata/0.4.18) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `regex-syntax` | [0.8.11](https://crates.io/crates/regex-syntax/0.8.11) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `roxmltree` | [0.20.0](https://crates.io/crates/roxmltree/0.20.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `rusqlite` | [0.37.0](https://crates.io/crates/rusqlite/0.37.0) | `MIT` | 主、M0-B | 是 |
| `rustc-hash` | [2.1.3](https://crates.io/crates/rustc-hash/2.1.3) | `Apache-2.0 OR MIT` | 主、M0-B | 是 |
| `rustix` | [1.1.6](https://crates.io/crates/rustix/1.1.6) | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` | 主、M0-B | 是 |
| `rustversion` | [1.0.23](https://crates.io/crates/rustversion/1.0.23) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `scopeguard` | [1.2.0](https://crates.io/crates/scopeguard/1.2.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `scroll` | [0.12.0](https://crates.io/crates/scroll/0.12.0) | `MIT` | 主 | 是 |
| `scroll_derive` | [0.12.1](https://crates.io/crates/scroll_derive/0.12.1) | `MIT` | 主 | 是 |
| `semver` | [1.0.28](https://crates.io/crates/semver/1.0.28) | `MIT OR Apache-2.0` | 主 | 是 |
| `serde` | [1.0.229](https://crates.io/crates/serde/1.0.229) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `serde-tuple-vec-map` | [1.0.1](https://crates.io/crates/serde-tuple-vec-map/1.0.1) | `MIT` | 主、M0-B | 是 |
| `serde_core` | [1.0.229](https://crates.io/crates/serde_core/1.0.229) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `serde_derive` | [1.0.229](https://crates.io/crates/serde_derive/1.0.229) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `serde_json` | [1.0.154](https://crates.io/crates/serde_json/1.0.154) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `sevenz-rust2` | [0.24.1](https://crates.io/crates/sevenz-rust2/0.24.1) | `Apache-2.0` | 主 | 是 |
| `sha2` | [0.11.1](https://crates.io/crates/sha2/0.11.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `shlex` | [2.0.1](https://crates.io/crates/shlex/2.0.1) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `simd-adler32` | [0.3.10](https://crates.io/crates/simd-adler32/0.3.10) | `MIT` | 主、M0-B | 是 |
| `simdutf8` | [0.1.5](https://crates.io/crates/simdutf8/0.1.5) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `siphasher` | [0.3.11](https://crates.io/crates/siphasher/0.3.11) | `MIT/Apache-2.0` | 主 | 是 |
| `sketches-ddsketch` | [0.4.2](https://crates.io/crates/sketches-ddsketch/0.4.2) | `Apache-2.0` | 主、M0-B | 是 |
| `slab` | [0.4.12](https://crates.io/crates/slab/0.4.12) | `MIT` | 主、M0-B | 是 |
| `smallvec` | [1.16.4](https://crates.io/crates/smallvec/1.16.4) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `smawk` | [0.3.3](https://crates.io/crates/smawk/0.3.3) | `MIT` | 主 | 是 |
| `stable_deref_trait` | [1.2.1](https://crates.io/crates/stable_deref_trait/1.2.1) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `static_assertions` | [1.1.0](https://crates.io/crates/static_assertions/1.1.0) | `MIT OR Apache-2.0` | 主 | 是 |
| `strsim` | [0.11.1](https://crates.io/crates/strsim/0.11.1) | `MIT` | 主、M0-B | 是 |
| `syn` | [2.0.119](https://crates.io/crates/syn/2.0.119) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `syn` | [3.0.9](https://crates.io/crates/syn/3.0.9) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `tantivy` | [0.27.0](https://crates.io/crates/tantivy/0.27.0) | `MIT` | 主 | 是 |
| `tantivy-bitpacker` | [0.27.0](https://crates.io/crates/tantivy-bitpacker/0.27.0) | `MIT` | 主、M0-B | 是 |
| `tantivy-columnar` | [0.27.0](https://crates.io/crates/tantivy-columnar/0.27.0) | `MIT` | 主、M0-B | 是 |
| `tantivy-common` | [0.27.0](https://crates.io/crates/tantivy-common/0.27.0) | `MIT` | 主、M0-B | 是 |
| `tantivy-fst` | [0.5.0](https://crates.io/crates/tantivy-fst/0.5.0) | `Unlicense/MIT` | 主、M0-B | 是 |
| `tantivy-query-grammar` | [0.27.0](https://crates.io/crates/tantivy-query-grammar/0.27.0) | `MIT` | 主、M0-B | 是 |
| `tantivy-sstable` | [0.27.0](https://crates.io/crates/tantivy-sstable/0.27.0) | `MIT` | 主、M0-B | 是 |
| `tantivy-stacker` | [0.27.0](https://crates.io/crates/tantivy-stacker/0.27.0) | `MIT` | 主、M0-B | 是 |
| `tantivy-tokenizer-api` | [0.7.0](https://crates.io/crates/tantivy-tokenizer-api/0.7.0) | `MIT` | 主、M0-B | 是 |
| `tar` | [0.4.46](https://crates.io/crates/tar/0.4.46) | `MIT OR Apache-2.0` | 主 | 是 |
| `tempfile` | [3.27.0](https://crates.io/crates/tempfile/3.27.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `textwrap` | [0.16.4](https://crates.io/crates/textwrap/0.16.4) | `MIT` | 主 | 是 |
| `thiserror` | [2.0.21](https://crates.io/crates/thiserror/2.0.21) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `thiserror-impl` | [2.0.21](https://crates.io/crates/thiserror-impl/2.0.21) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `time` | [0.3.55](https://crates.io/crates/time/0.3.55) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `time-core` | [0.1.9](https://crates.io/crates/time-core/0.1.9) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `time-macros` | [0.2.32](https://crates.io/crates/time-macros/0.2.32) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `tinyvec` | [1.13.3](https://crates.io/crates/tinyvec/1.13.3) | `Zlib OR Apache-2.0 OR MIT` | 主、M0-B | 是 |
| `toml` | [0.5.11](https://crates.io/crates/toml/0.5.11) | `MIT/Apache-2.0` | 主 | 是 |
| `typeid` | [1.0.3](https://crates.io/crates/typeid/1.0.3) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `typenum` | [1.20.1](https://crates.io/crates/typenum/1.20.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `typetag` | [0.2.23](https://crates.io/crates/typetag/0.2.23) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `typetag-impl` | [0.2.23](https://crates.io/crates/typetag-impl/0.2.23) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `unicode-ident` | [1.0.27](https://crates.io/crates/unicode-ident/1.0.27) | `(MIT OR Apache-2.0) AND Unicode-3.0` | 主、M0-B | 是 |
| `unicode-normalization` | [0.1.25](https://crates.io/crates/unicode-normalization/0.1.25) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `unicode-width` | [0.2.3](https://crates.io/crates/unicode-width/0.2.3) | `MIT OR Apache-2.0` | 主 | — |
| `uniffi` | [0.29.5](https://crates.io/crates/uniffi/0.29.5) | `MPL-2.0` | 主 | 是 |
| `uniffi_bindgen` | [0.29.5](https://crates.io/crates/uniffi_bindgen/0.29.5) | `MPL-2.0` | 主 | 是 |
| `uniffi_core` | [0.29.5](https://crates.io/crates/uniffi_core/0.29.5) | `MPL-2.0` | 主 | 是 |
| `uniffi_internal_macros` | [0.29.5](https://crates.io/crates/uniffi_internal_macros/0.29.5) | `MPL-2.0` | 主 | 是 |
| `uniffi_macros` | [0.29.5](https://crates.io/crates/uniffi_macros/0.29.5) | `MPL-2.0` | 主 | 是 |
| `uniffi_meta` | [0.29.5](https://crates.io/crates/uniffi_meta/0.29.5) | `MPL-2.0` | 主 | 是 |
| `uniffi_pipeline` | [0.29.5](https://crates.io/crates/uniffi_pipeline/0.29.5) | `MPL-2.0` | 主 | 是 |
| `uniffi_udl` | [0.29.5](https://crates.io/crates/uniffi_udl/0.29.5) | `MPL-2.0` | 主 | 是 |
| `unrar` | [0.5.8](https://crates.io/crates/unrar/0.5.8) | `MIT OR Apache-2.0` | 主 | 是 |
| `unrar_sys` | [0.5.8](https://crates.io/crates/unrar_sys/0.5.8) | `MIT OR Apache-2.0` | 主 | 是 |
| `unwrap-infallible` | [1.0.0](https://crates.io/crates/unwrap-infallible/1.0.0) | `MIT OR Apache-2.0` | 主、M0-B | 是 |
| `utf8-ranges` | [1.0.5](https://crates.io/crates/utf8-ranges/1.0.5) | `Unlicense/MIT` | 主、M0-B | 是 |
| `uuid` | [1.29.0](https://crates.io/crates/uuid/1.29.0) | `Apache-2.0 OR MIT` | 主、M0-B | 是 |
| `vcpkg` | [0.2.15](https://crates.io/crates/vcpkg/0.2.15) | `MIT/Apache-2.0` | 主、M0-B | 是 |
| `wasip2` | [1.0.4+wasi-0.2.12](https://crates.io/crates/wasip2/1.0.4+wasi-0.2.12) | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` | 主、M0-B | — |
| `wasm-bindgen` | [0.2.129](https://crates.io/crates/wasm-bindgen/0.2.129) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `wasm-bindgen-macro` | [0.2.129](https://crates.io/crates/wasm-bindgen-macro/0.2.129) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `wasm-bindgen-macro-support` | [0.2.129](https://crates.io/crates/wasm-bindgen-macro-support/0.2.129) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `wasm-bindgen-shared` | [0.2.129](https://crates.io/crates/wasm-bindgen-shared/0.2.129) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `web-time` | [1.1.0](https://crates.io/crates/web-time/1.1.0) | `MIT OR Apache-2.0` | 主 | 是 |
| `weedle2` | [5.0.0](https://crates.io/crates/weedle2/5.0.0) | `MIT` | 主 | 是 |
| `widestring` | [1.2.1](https://crates.io/crates/widestring/1.2.1) | `MIT OR Apache-2.0` | 主 | 是 |
| `winapi` | [0.3.9](https://crates.io/crates/winapi/0.3.9) | `MIT/Apache-2.0` | 主、M0-B | — |
| `winapi-i686-pc-windows-gnu` | [0.4.0](https://crates.io/crates/winapi-i686-pc-windows-gnu/0.4.0) | `MIT/Apache-2.0` | 主、M0-B | — |
| `winapi-x86_64-pc-windows-gnu` | [0.4.0](https://crates.io/crates/winapi-x86_64-pc-windows-gnu/0.4.0) | `MIT/Apache-2.0` | 主、M0-B | — |
| `windows-link` | [0.2.1](https://crates.io/crates/windows-link/0.2.1) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `windows-sys` | [0.59.0](https://crates.io/crates/windows-sys/0.59.0) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `windows-sys` | [0.61.2](https://crates.io/crates/windows-sys/0.61.2) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `windows-targets` | [0.52.6](https://crates.io/crates/windows-targets/0.52.6) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `windows_aarch64_gnullvm` | [0.52.6](https://crates.io/crates/windows_aarch64_gnullvm/0.52.6) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `windows_aarch64_msvc` | [0.52.6](https://crates.io/crates/windows_aarch64_msvc/0.52.6) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `windows_i686_gnu` | [0.52.6](https://crates.io/crates/windows_i686_gnu/0.52.6) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `windows_i686_gnullvm` | [0.52.6](https://crates.io/crates/windows_i686_gnullvm/0.52.6) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `windows_i686_msvc` | [0.52.6](https://crates.io/crates/windows_i686_msvc/0.52.6) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `windows_x86_64_gnu` | [0.52.6](https://crates.io/crates/windows_x86_64_gnu/0.52.6) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `windows_x86_64_gnullvm` | [0.52.6](https://crates.io/crates/windows_x86_64_gnullvm/0.52.6) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `windows_x86_64_msvc` | [0.52.6](https://crates.io/crates/windows_x86_64_msvc/0.52.6) | `MIT OR Apache-2.0` | 主、M0-B | — |
| `winnow` | [0.7.15](https://crates.io/crates/winnow/0.7.15) | `MIT` | 主 | 是 |
| `wit-bindgen` | [0.57.1](https://crates.io/crates/wit-bindgen/0.57.1) | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` | 主、M0-B | — |
| `xattr` | [1.7.0](https://crates.io/crates/xattr/1.7.0) | `MIT OR Apache-2.0` | 主 | 是 |
| `zerocopy` | [0.8.63](https://crates.io/crates/zerocopy/0.8.63) | `BSD-2-Clause OR Apache-2.0 OR MIT` | 主、M0-B | 是 |
| `zerocopy-derive` | [0.8.63](https://crates.io/crates/zerocopy-derive/0.8.63) | `BSD-2-Clause OR Apache-2.0 OR MIT` | 主、M0-B | — |
| `zip` | [2.6.1](https://crates.io/crates/zip/2.6.1) | `MIT` | M0-B | — |
| `zip` | [4.6.1](https://crates.io/crates/zip/4.6.1) | `MIT` | 主 | 是 |
| `zlib-rs` | [0.6.8](https://crates.io/crates/zlib-rs/0.6.8) | `Zlib` | 主 | 是 |
| `zmij` | [1.0.23](https://crates.io/crates/zmij/1.0.23) | `MIT` | 主、M0-B | 是 |
| `zopfli` | [0.8.4](https://crates.io/crates/zopfli/0.8.4) | `Apache-2.0` | 主、M0-B | 是 |
| `zstd` | [0.14.3](https://crates.io/crates/zstd/0.14.3) | `BSD-3-Clause` | 主、M0-B | 是 |
| `zstd-safe` | [8.2.0](https://crates.io/crates/zstd-safe/8.2.0) | `BSD-3-Clause` | 主、M0-B | 是 |
| `zstd-sys` | [2.1.2+zstd.1.5.7](https://crates.io/crates/zstd-sys/2.1.2+zstd.1.5.7) | `BSD-3-Clause` | 主、M0-B | 是 |

## 发布时随附的材料

- 项目 `LICENSE`、[`LICENSES/XSearch-UnRAR-linking-exception.md`](LICENSES/XSearch-UnRAR-linking-exception.md)、[UnRAR 许可原文](LICENSES/UnRAR-license.txt)、本清单，以及链接进应用的全部 Rust crate 许可原文（`Rust-crates.txt`，由 `scripts/collect-licenses.py` 生成）。构建脚本把它们放在应用包的 `Contents/Resources/Licenses/` 和 DMG 的“许可与源码”文件夹中。Sparkle 的许可随框架资源一并分发。
- 按同一发行版本提供 GPLv3 第 6 节和链接例外要求的对应源码：每个 GitHub Release 附带 `XSearch-<版本>-source.tar.gz`（`scripts/source-archive.sh` 生成），含 tag 对应的仓库源码、构建脚本，以及 `cargo vendor` 收录的全部 Rust 依赖源码（含 UnRAR 源码）。DMG 中的 `对应源码.txt` 给出下载地址。
- 更新锁文件、Sparkle 版本、原生库或测试素材时，同步核对本清单和发行附件。替换归档实现后重新核对 UnRAR 相关条目。

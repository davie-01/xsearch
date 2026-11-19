**简体中文** · [English](README.en.md)

![XSearch 产品概览：在 Mac 上搜索文件名和文件正文，预览并高亮命中](docs/assets/xsearch-overview-zh.png)

# XSearch

**在 Mac 上找文件、搜正文，直接跳到命中的位置。**

XSearch 是一款面向 Apple 芯片 Mac 的原生菜单栏应用。按下 `⌥Space` 就能打开应用或查找文件和文件夹。只记得文档里的一句话时，切换到内容模式，即可搜索已建立索引的文档并查看高亮片段。文件、索引和查询都在本机处理。配置了自动更新地址的版本会联网检查更新，可在设置中关闭自动检查。

## 能做什么

| 功能 | 适用场景 |
| --- | --- |
| 名称搜索与应用启动 | 输入应用、文件或文件夹名称的一部分，打开结果、用空格快速查看，或在 Finder 中定位。 |
| 文档正文搜索 | 按词、短语、正则或邻近条件检索已索引的文本。可切换宽松、区分大小写和严格原文三种匹配方式。 |
| 完整搜索窗口与阅读窗口 | 在完整窗口筛选和查看大量结果，在阅读窗口浏览命中上下文，逐处跳转。PDF 等格式的原文定位取决于文件格式及所用阅读器。 |
| 压缩包内容搜索 | 索引受支持的包内文件，查看命中的成员，并按需解出单个成员打开。 |
| 独立的索引范围 | 分别管理名称与内容的目录、排除规则及索引状态。内容索引还可以限制文件类型和单文件大小。 |

### 可以搜索哪些正文

- **文档与表格**：有文字层的 PDF，Word（DOC、DOCX、DOT、DOCM），Excel（XLS、XLSX、XLSM），PowerPoint（PPT、PPTX、PPS、PPTM），OpenDocument（ODT、ODS、ODP），以及部分 WPS 格式（WPS、ET、DPS）。
- **文本与出版物**：纯文本、Markdown、日志、常见代码和配置文件，以及 HTML、EPUB、FB2、RTF、OFD。
- **邮件**：EML 和 Apple Mail 的 EMLX，包括主题、发件人、收件人、日期、正文和附件名。
- **思维导图**：XMind（新版和 XMind 8 及更早版本），包括各画布的主题、标签、备注、外框和联系的文字。
- **归档**：ZIP、TAR、GZ、TGZ、7z、RAR。XSearch 可搜索已提取的包内正文，并在结果中标出命中的成员。

正文检索依赖实际提取结果。扫描 PDF 的无文字层页面目前会标记为等待 OCR，图片文字识别尚未接入。加密、损坏、超限或无法访问的文件可能只提取一部分，或无法提取。归档提取只处理一层，并有解包量限制。

## 下载和安装

需要 **Apple 芯片（arm64）与 macOS 26 或更高版本**。可在 ** → 关于本机** 核对。

1. 从本项目 GitHub 仓库顶部的 **Releases** 下载对应版本的 `XSearch-<版本>.dmg`。如果没有 DMG，请使用下方的源码构建步骤。
2. 打开 DMG，将 `XSearch.app` 拖入 **应用程序**，退出磁盘映像，再从 Finder 的 **应用程序** 启动。
3. 启动后从菜单栏访问 XSearch，或按 `⌥Space` 呼出。

### macOS 阻止首次启动

当前安装包未经过 Apple 公证。确认下载来自项目的发布页后，先尝试打开一次 **应用程序** 中的 XSearch，再前往 **系统设置 → 隐私与安全性**，在安全性区域选择 **仍要打开**，并按提示确认。这项许可只针对该应用。[Apple 官方说明](https://support.apple.com/zh-cn/102445)

如果系统未提供该按钮，且你已经核对安装包来源和签名完整性，可以用终端查看并移除该应用副本的下载隔离标记。先执行以下检查，签名校验通过后再执行后面的命令。

```sh
codesign --verify --deep --strict --verbose=2 "/Applications/XSearch.app"
xattr -p com.apple.quarantine "/Applications/XSearch.app"
```

```sh
xattr -dr com.apple.quarantine "/Applications/XSearch.app"
open "/Applications/XSearch.app"
```

签名完整性校验只能检查签名与文件内容是否一致。若校验失败，或系统明确提示应用包含恶意软件，请停止并核对下载包。若 `xattr -p` 提示没有该属性，启动失败另有原因，可先核对系统版本与芯片架构。若应用安装在别处，将命令中的路径替换为实际位置。

## 第一次搜索

1. 根据首次启动引导选择内容索引目录。可以从 **下载** 开始，再在 **设置 → 索引范围** 添加经常使用的项目目录。默认名称索引覆盖可访问范围，并排除部分系统目录、隐藏项和常见开发缓存。
2. 按 `⌥Space`，输入文件名或应用名的一部分。若快捷键被占用，在菜单栏打开设置并重新录制。
3. 在启动器输入小写 `in` 后接一个英文空格，或按 `⌘2`，进入内容模式。完整窗口可直接切换至 **内容**。用 `⌘1` 回到名称模式。
4. 用方向键选中结果。按 `Return` 打开，按 `⌘Return` 在名称模式下显示于 Finder，在内容模式下进入阅读窗口。按 `⌘E` 进入完整搜索窗口。

### 查询示例

| 在快捷启动器输入 | 效果 |
| --- | --- |
| `项目计划 ext:docx;pdf` | 按名称查找 Word 或 PDF。 |
| `合同 -草稿 kind:word` | 按名称查找含“合同”的 Word 文档，排除含“草稿”的名称。 |
| `ext:pdf dm:7d` | 查找最近七天修改的 PDF。 |
| `in "项目计划" dir:~/Documents ext:pdf;docx` | 搜索文稿目录中 PDF 或 Word 文档的正文。 |
| `in "合同 金额"~10` | 搜索“合同”和“金额”在指定字符距离内出现的正文。 |
| `in 支付条件 name:验收` | 搜索文件名含“验收”、正文含“支付条件”的文档。 |
| `in regex:HT-[0-9]{4}` | 按编号格式搜索正文。 |

两个模式都支持布尔组合及 `dir:`、`ext:`、`size:`、`dm:`。名称模式另外支持 `kind:` 和通配符，内容模式支持 `name:` 文件名条件和邻近查询。内容模式的 `dir:` 需要文件系统路径，支持 `~/`。路径有空格时，用英文双引号包住路径。启动器按 `⌘/` 可查看语法速查和开关状态。完整语法、正则写法和更多示例见 [搜索语法与正则指南](docs/SEARCH-GUIDE.md)。

### 找不到结果时

先核对搜索模式，再到 **设置 → 索引范围** 查看文件所在目录、排除规则、类型和大小上限。在 **诊断** 中检查路径与索引状态。刚添加目录或修改文件时，正文可能还在等待提取。受保护目录可能需要在 **系统设置 → 隐私与安全性** 中授权，完全磁盘访问为可选项。按需授权后重新打开 XSearch。

## 从源码构建

准备 Apple 芯片 Mac、带 macOS 26 SDK 和 Swift 6.2 或更新版本的完整 Xcode，以及适用于 Apple Silicon 的 Rust stable（含 Cargo）。先在 Xcode 中完成组件安装，并确保 `xcode-select -p` 指向完整 Xcode。构建脚本会下载锁定版本的 Rust 依赖和 Sparkle，首次构建需要联网。

从项目仓库克隆源码，或下载 Release 中对应版本的 `XSearch-<版本>-source.tar.gz`（附带全部 Rust 依赖源码，可离线获取依赖），然后在源码根目录运行：

```sh
xcodebuild -version
swift --version
rustc --version
cargo --version

bash scripts/build-app.sh
open target/XSearch.app
```

构建依次生成 Rust 静态库、Swift 可执行文件、索引 XPC 服务和提取子进程，然后组装 `target/XSearch.app`。默认使用 ad-hoc 签名。有开发签名身份时，可以为构建命令设置 `XS_SIGN_IDENTITY`。本地构建默认不配置自动更新源。

```sh
# 构建 DMG，输出 target/XSearch-<版本>.dmg
bash scripts/build-dmg.sh

# 运行 Rust 和 Swift 测试
source scripts/env.sh
cargo test --workspace --locked
bash scripts/swift-test.sh
```

在干净检出中首次跑 Swift 测试前，先运行应用构建或 `bash scripts/fetch-sparkle.sh`，确保框架已就位。

## 本机数据与反馈

索引和记录保存在 `~/Library/Application Support/XSearch/`。全部写入位置见[本机文件位置](docs/STORAGE.md)。内容索引中包含提取出的正文。可从 **设置 → 隐私与数据** 重建索引，收藏和最近打开记录保存在单独数据库中。卸载时先退出应用，再将应用移入废纸篓。如需同时清理本机数据，删除数据目录前请备份需要保留的收藏和历史。

如果遇到问题，可通过项目的 GitHub **Issues** 提交系统版本、XSearch 版本、搜索模式和最小复现步骤。可用合成文件重现时，附上合成样本即可。

## 许可证

XSearch 的原创代码采用 **GNU 通用公共许可证第 3 版，附 UnRAR 链接例外**。你可以依许可使用、修改和再分发软件，包括商业用途。链接例外允许分发与指定 UnRAR 实现链接的 XSearch，UnRAR 继续适用其自身许可。再分发时须保留适用声明，并按要求提供对应源码。每个 Release 附带同版本的完整源码包，DMG 与应用包内也附有许可原文和第三方声明。软件依 GPLv3 条款提供，无担保。

[GPLv3 原文](LICENSE) · [UnRAR 链接例外](LICENSES/XSearch-UnRAR-linking-exception.md) · [第三方许可与发行说明](THIRD_PARTY_NOTICES.md) · [搜索语法](docs/SEARCH-GUIDE.md) · [设计文档](docs/DESIGN.md) · [更新日志](CHANGELOG.md) · [参与开发](CONTRIBUTING.md)

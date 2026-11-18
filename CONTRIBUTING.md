**简体中文** · [English](CONTRIBUTING.en.md)

# 参与 XSearch 开发

欢迎提交问题和改动。动手前建议先读 [docs/DESIGN.md](docs/DESIGN.md)：它说明了进程结构、两条检索路径和各目录的职责。界面改动以 [docs/design/UI-SPEC.md](docs/design/UI-SPEC.md) 为准。

## 环境

- Apple 芯片 Mac，macOS 26 或更高版本
- 完整 Xcode（含 macOS 26 SDK、Swift 6.2 或更新版本），`xcode-select -p` 指向它
- Rust stable。项目脚本通过 `scripts/env.sh` 把工具链放在 `.tools/`，不改全局 PATH；首次可按 README 安装，或在 `source scripts/env.sh` 后运行 rustup 安装器

## 构建与测试

```sh
source scripts/env.sh
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
bash scripts/fetch-sparkle.sh      # 干净检出中第一次跑 Swift 测试前需要
bash scripts/swift-test.sh
bash scripts/build-app.sh          # 组装 target/XSearch.app（未设 XS_SIGN_IDENTITY 时 ad-hoc 签名）
```

开发时可用 `XS_DATA_DIR` 指定独立数据目录，避免影响日常使用的索引；`XS_LANG=en` 以英文界面启动。涉及查询或索引性能的改动，提交前运行 `bash scripts/regression.sh`。

热键、权限提示（TCC）、XPC 服务和自动更新只能在正常桌面会话中验证：构建应用后从 Finder 启动，按改动范围手动走一遍，并在 PR 中写明步骤与结果。

## 提交约定

- 一个提交只做一件事。标题用英文，格式为 `模块: 说明行为的一句话`，例如 `Catalog: purging tombstones never frees the highest file id`；需要解释原因时写在正文里。
- 查询语法变化同步搜索指南（[中文](docs/SEARCH-GUIDE.md)、[英文](docs/SEARCH-GUIDE.en.md)）；新增或升级依赖同步 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；面向用户的变化写入更新日志（[中文](CHANGELOG.md)、[英文](CHANGELOG.en.md)）。
- 有英文版（`*.en.md`）的文档，中英文一起修改。
- 界面文字以中文为源语言，写法见 [docs/design/LOCALIZATION.md](docs/design/LOCALIZATION.md)。
- 测试样例只用合成数据，不提交真实文档、真实路径或个人索引。

## 许可

XSearch 以 GPLv3 附 UnRAR 链接例外发布。提交代码即表示你同意以相同条款授权你的贡献，包括 [UnRAR 链接例外](LICENSES/XSearch-UnRAR-linking-exception.md)。

## 发布（维护者）

1. `XS_SIGN_IDENTITY='…' XS_GITHUB_REPO='davie-01/xsearch' bash scripts/release.sh <版本>`：改版本号、构建 DMG（含许可与源码说明）、生成签名的 `appcast.xml`。
2. 提交版本号改动，打 `v<版本>` tag，推送 `main` 与 tag。
3. `bash scripts/source-archive.sh <版本>`：生成附带全部 Rust 依赖源码的 `work/source/XSearch-<版本>-source.tar.gz`。
4. CI 通过后，在 GitHub 新建 `v<版本>` Release，标为 Latest，上传 DMG、`appcast.xml` 和源码包，发行说明取自 CHANGELOG。

详细说明见 [docs/DESIGN.md](docs/DESIGN.md) 第 6 节。

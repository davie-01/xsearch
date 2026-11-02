# M5 进度（发布 1.0）

用户决定（2026-10-31）：
- 暂时没有 Apple Developer 账号：签名和公证先跳过，做到能打出 DMG（ad-hoc 签名）为止；有账号以后再补 Developer ID 签名和公证。
- 索引服务在 1.0 前拆成独立进程（XPC）。

| 项 | 状态 |
|---|---|
| 首次启动引导 | ✅ 完成 |
| 索引服务拆成独立进程（XPC） | ✅ 完成 |
| DMG 安装包 | ✅ 完成（未公证） |
| 自动更新（Sparkle） | ✅ 完成（待建 GitHub 发布仓库） |
| 升级和数据迁移 | ✅ 完成 |
| 性能和正确性回归测试 | ✅ 完成 |
| Developer ID 签名、公证 | 暂缓（需要账号） |

## 首次启动引导（UI-SPEC §6.5）

- 共三步，外加一个完成页，窗口 780×530：
  1. 快捷键说明，以及“开机时自动启动”开关；
  2. 选择内容索引的文件夹：推荐“下载”（显示本地化名称，以及从文件名索引统计出的可提取文件数），可以取消，也可以添加其他文件夹；
  3. 完全磁盘访问权限（可选）：通过能否打开受保护文件判断是否已授权，从系统设置回来时自动刷新；
  - 完成页：“按 ⌥Space 试一下”。
- 只在真正首次启动时出现（数据目录里还没有 catalog.sqlite）；已经有数据的安装直接标记为已完成，不会突然弹出。菜单栏“使用引导…”可以随时打开。
- 点“完成”时，如果所选文件夹和当前不同，就应用新的内容范围。
- 开发用环境变量：`XS_ONBOARDING=1` 强制显示，`XS_ONBOARDING_STEP=0…3` 直接打开某一步（用于截图）。
- 验证：四个页面都截图检查过。

## 索引服务拆成独立进程（ARCHITECTURE §5）

- `IndexService.xpc` 打包在 `XSearch.app/Contents/XPCServices/` 里（可执行目标 `IndexService`，`App/IndexService/Info.plist`，ServiceType 为 Application）。其中运行 ContentIndexer：它是唯一的 Tantivy 写入者，也负责调度 `xs-extract` 提取子进程（子进程的父进程是 IndexService）。
- 主应用保留文件名索引、目录数据库的变化检测和全部读取（查询、预览）。双方共用 catalog.sqlite（WAL 模式，锁等待 5 秒）；原来就是两个连接，拆成两个进程后数据语义不变。
- 接口（`IndexServiceProtocol`，NSXPC）：启动、快照（状态和当前实例目录，JSON）、重建内容索引、停止。
- 主应用 `IndexServiceClient`：
  - 启动时就连接（预热）；状态随原来的 2 秒定时器异步拉取；
  - 服务崩溃或被结束时，在中断回调里重新启动索引器（launchd 收到下一条消息会自动拉起服务）；
  - 退出应用和重建文件名索引时，先同步停止服务，确保写入干净收尾。
  - 服务在应用断开连接时停止索引器并退出，不会比应用活得更久。
  - 包里没有服务时（直接 `swift run`、测试），或设置了 `XS_INPROCESS_INDEX=1`，退回到进程内运行，接口相同。
- 打包脚本按由内到外的顺序签名：xs-extract、IndexService.xpc，最后是应用本身。
- 真机验证：
  - 在“下载”新建带唯一词的文件，约 10 秒内被提取进索引并可以搜到；
  - `kill -9` 结束服务后，新的服务进程被拉起，新文件照常进入索引；
  - 退出应用后，服务和提取子进程全部退出。

## DMG 安装包

- `scripts/build-dmg.sh`：先用 build-app.sh 打包，再把应用和指向 /Applications 的链接放进 APFS 压缩镜像，生成 `target/XSearch-<版本>.dmg`（目前 16 MB）。打完后挂载镜像，校验其中应用的签名。
- 没有 Developer ID：应用用 `XS_SIGN_IDENTITY`（本机的 Apple Development 证书）签名，没有设置时用 ad-hoc 签名；不做公证。其他 Mac 第一次打开需要右键 → 打开。有账号后再补 Developer ID 签名、`notarytool` 公证和 `stapler`。

## 自动更新（Sparkle 2.10.0，经 GitHub Releases 分发）

- `scripts/fetch-sparkle.sh`：把官方发布包下载到 `.tools/`，按 GitHub 公布的 SHA-256 校验（c2bf58aa…）。Sparkle 2.10.1 发布才 6 天，所以选用已发布 6 周的 2.10.0。
- 打包：Sparkle.framework 放进 `Contents/Frameworks`（rpath 为 `@executable_path/../Frameworks`），按由内到外的顺序签名（Installer.xpc、Downloader.xpc、Autoupdate、Updater.app、framework）；Info.plist 写入 `SUPublicEDKey`；只有设置了 `XS_FEED_URL` 才写入 `SUFeedURL`，没有更新地址的版本自动更新处于关闭状态，“检查更新”会提示手动下载。
- 密钥：EdDSA 密钥对由 `generate_keys --account xsearch` 生成；私钥只存在本机登录钥匙串里（不进仓库），公钥在 `App/Resources/sparkle-public-key.txt`。
  - **请备份私钥**：`.tools/sparkle-2.10.0/bin/generate_keys --account xsearch -x 备份文件路径`，把文件存到安全的地方。私钥丢失后，已经安装的版本就无法再接收更新。
- 界面：菜单栏“检查更新…”；设置 → 通用 → 软件更新（显示当前版本、“自动检查更新”开关、“检查更新…”按钮）。
- 发布流程（`scripts/release.sh`）：
  1. 在 GitHub 新建一个仓库用来发布（源码可以不公开），比如 `你的用户名/xsearch-releases`；
  2. `XS_SIGN_IDENTITY=… XS_GITHUB_REPO=你的用户名/xsearch-releases bash scripts/release.sh 0.2.0`：修改版本号（主应用和 IndexService 的 Info.plist，build 号加 1），打出带更新地址的 DMG，用钥匙串里的私钥签名，生成包含 `work/releases/` 里所有版本的 appcast.xml；
  3. 在 GitHub 新建 Release，标签为 `v0.2.0`，上传 `work/releases/XSearch-0.2.0.dmg` 和 `appcast.xml`，并设为 Latest。更新地址是 `https://github.com/<repo>/releases/latest/download/appcast.xml`，始终指向最新那个 Release 里的 appcast。
- 端到端验证（本机，用 `python3 -m http.server` 代替 GitHub）：
  - 0.1.0（更新地址指向本地）检查到 0.1.1，弹出“新版本的 XSearch 已经发布”；
  - 下载并通过 EdDSA 校验，安装后重新启动；测试副本变为 0.1.1，签名校验通过，IndexService 也跟着重新启动；
  - 测试文件已删除，仓库里的版本号已恢复为 0.1.0。
- 开发用环境变量：`XS_CHECK_UPDATES=1`，启动后立即检查更新。
- 注意：没有 Developer ID 公证时，用户从网页下载的第一个 DMG 仍需右键 → 打开；之后通过 Sparkle 安装的更新不需要再这样操作。

## 升级和数据迁移

| 数据 | 可否重建 | 版本标记 | 升级 | 遇到更新版本写入的文件（降级） |
|---|---|---|---|---|
| catalog.sqlite | 可以（扫描得到） | `PRAGMA user_version`，当前为 2 | `Migrations.migrate` 逐步执行，每步一个事务，步骤必须幂等（应用和 IndexService 可能同时打开）；没有版本号的旧库从 0 开始（v1 = M1 表，v2 = M2 内容列） | 抛出 `NewerFormat` → NameService 删除目录数据库、文件名快照和内容索引后重新扫描 |
| user.sqlite（收藏、最近打开） | **不可以** | `user_version`，当前为 1 | 同上 | 原样使用（表只会增加），**绝不删除** |
| 文件名快照 | 可以 | 文件头 `XSNAME01` + 名称键版本 + 目录数据库 id | 不一致时从目录数据库重建（M1 已有） | 同左 |
| 内容索引 | 可以（重新提取） | 附带文件里的 schema（`xs-content-v1`） | 不一致时 `resetIndexInstance`：换新实例、删除旧目录和未确认的批次，所有内容文件重新排队（以前会直接启动失败，内容搜索一直不可用） | 同左 |
| 提取器版本 | — | `content_extractors` 记录各类型的版本 | 只重新提取版本变化的类型（M2 已有） | 同左 |
| 设置（UserDefaults JSON） | — | — | QuerySyntax、NameScope、OpenWith 改为逐字段解码、缺失时用默认值，未知字段忽略；不认识的编辑器回退为系统默认；ContentScope 有 knownTypes 迁移（M4） | 同左 |

- IndexService 启动失败（比如目录数据库正在重建）时，客户端每 3 秒重试一次，最多 5 次。
- 测试（MigrationTests）：
  - 没有版本号的 M1 目录数据库被迁移，原有数据保留；
  - 更新版本写入的目录数据库被重建，个人数据保留；
  - 内容索引的 schema 不一致时，换新实例后内容能重新搜到；
  - 设置缺少字段或多出未知字段时，用户的选择保持不变。
- 真机：启动后本机的 catalog.sqlite 标为版本 2，user.sqlite 标为版本 1，“最近打开”记录保留。

## 性能和正确性回归测试

`bash scripts/regression.sh`（发版前必须通过；`--update-baseline` 用当前机器的数字重新记录基线 `docs/m5/perf-baseline.json`）：

1. 正确性：
   - Rust 全部测试（release 模式，包括三种匹配模式下与暴力扫描的对照、邻近、正则、压缩包成员拆分等）；
   - clippy，警告即失败；
   - Swift 全部测试（文件名引擎、目录数据库与 FSEvents、内容流水线、提取、迁移、XPC 以外的部分）。
2. 性能（release 构建、固定种子的合成数据）：
   - 文件名引擎：100 万条，建立耗时、内存，11 个查询的 P95 和命中数；
   - 内容查询：1 万份文档，14 个查询的首屏 P95、完成 P95 和命中数；
   - 提取：docx、txt 测试样例，以及约 13 MB 生成文本的耗时和字数。
3. 判定（`scripts/perf_compare.py`）：
   - 延迟超过基线 × 1.5，并且至少慢 5 ms，判为失败；
   - 内存超过基线 × 1.2，判为失败；
   - 命中数或提取字数只要和基线不同，就判为正确性回归。

基线（本机，2026-10-31）中的部分数字：文件名建立 2.3 s，内存 79 MB，最慢查询 P95 为 32 ms（`ext:pdf 合同`），“报告” 为 14 ms；内容查询最慢的首屏 P95 为 30 ms（`合同 -附件`）；13 MB 文本提取 96 ms。

验证：
- 记录基线后再跑一次检查，73 项全部在范围内（两次之间的波动约 1–3%）；
- 往基线里注入一个更快的 P95 和一个不同的命中数，两处都被判为回归。

## 发版检查清单

1. `bash scripts/regression.sh` 通过；
2. 更新 `docs/` 中的进度和 ARCHITECTURE 变更记录；
3. `XS_SIGN_IDENTITY=… XS_GITHUB_REPO=<仓库> bash scripts/release.sh <版本>`；
4. 在 GitHub 新建 Release（标签 `v<版本>`，设为 Latest），上传 DMG 和 appcast.xml；
5. 用上一个版本“检查更新”确认能更新上来。

## 测试反馈修正（2026-11-01）

1. **内容模式输入英文时卡顿**：
   - 原因：英文短词（如 `wp`、`wpa`）容易命中很大的文档（实测有一份 644 万字），每次结果变化，预览都在主线程完整排版一遍，单次卡住约 950 ms，期间的按键都在排队。中文输入法上屏前不触发搜索，所以感觉不明显。
   - 用开发工具定位：`XS_PERF_LOG` 记录主线程上超过 40 ms 的卡顿，`XS_TYPE` 模拟逐键输入，空格、退格都按真实路径走。
   - 修正：
     - 文本框改用非连续排版；
     - 定位命中时只排版命中那一段；
     - 高亮作为文本属性，在文本接入排版系统之前加好（事后给远处的命中上色，会迫使系统生成整个前文的字形，约 200 ms）；
     - 切换命中时只改上一个和当前这一个；
     - 超过 30 万字的文档只显示当前命中附近约 20 万字，切换命中时窗口跟着移动，并给出提示；
     - 预览加载防抖 0.12 秒。
   - 结果：大文档预览 950 ms → 22 ms；模拟的“in wp ␣␣␣⌫⌫⌫ab⌫⌫”整个过程中，主线程没有超过 50 ms 的卡顿。
2. **从菜单栏打开的设置窗口不在最前面**：macOS 14 起是协作式激活，在菜单关闭的那一刻发出的激活请求会被拒绝，窗口只排在 XSearch 自己的层级里（活动应用之下、其他应用之上）。新增 `bringToFront`：`orderFrontRegardless`，菜单关闭后再请求一次激活；设置、完整窗口、阅读窗口、引导都改用它。以后台方式启动时设置窗口也排在最前面（按窗口层级顺序验证）。
3. **设置 › 内容索引的类型排版异常**：12 个复选框和说明文字挤在一个 HStack 里，被压成竖排。改为自适应网格（截图验证为 4 列 3 行），说明文字移到网格下方。
4. **侧栏“通用”上一直有焦点框；点击切换有时不生效**：焦点框来自键盘焦点，已对侧栏按钮关闭焦点效果；点击不生效是因为透明背景不响应点击，只有文字和图标处能点，现在给整行加了 `contentShape`。另外，排除规则说明里的 `**/build/**` 被当作 Markdown 显示，改为按原样显示。
5. **历史记录开关**（设置 › 通用 › 历史记录）：“呼出时保留上次的搜索内容”“输入框为空时显示最近打开的文件”两个开关，以及“清除最近打开记录”按钮（收藏不受影响）。

## 测试反馈修正（2026-11-01，第二轮）

- 用 `in` 进入内容模式后，在空输入框按 ⌫ 不能删除“内容”标签：现在会删除标签，回到名称模式。
- Tab 按应用或文件夹缩小范围（规则见 UI-SPEC §5.2.1，参照苹果帮助和 TidBITS 的说明）：
  - 新增 `DocumentTypes`：读取应用声明的文档类型，按 UTI 是否属于这些类型来判断，兼容旧式扩展名声明，排除容器类型；
  - 文件名引擎在每次搜索内按扩展名缓存判断结果；
  - 测试 `tabOnAppScopesToItsDocuments`。
  - 按用户要求只用于文件名搜索；切到内容模式时清掉范围标签。
  - 真机验证：“预览”范围下 `合同` 只列出 PDF 和图片（macOS 26 的“预览”声明了 `public.ofd`，所以也包含 OFD）；“下载”文件夹范围正确；⌫ 依次删除标签。
  - 修正：类型判断最初对每个像扩展名的后缀（如 `报告.2024-v3`）都向系统查询，在几十万个文件上会堵住搜索队列，导致清空输入框后结果迟迟不刷新；现在只查询 1–12 位字母或数字的扩展名。
- 结果列表中较长的文件名改为单行显示（之前会折成两行，把路径挤掉）。

## 代码审查修复（2026-11-02）

审查报告的逐项核实和修复清单见 [代码审查核实-2026-11-02.md](代码审查核实-2026-11-02.md)。第 0 批（R05、R06-a/b、N1、R25）、第 1 批（R01–R04、R07、R14）和第 2 批（R08、R10、R12、R13、R19、R20、R23、风险 2）已完成；第 3 批（含 R09）和第 4 批已完成。catalog.sqlite 的格式版本升到 3（新增部分索引 `files_content_state`）。

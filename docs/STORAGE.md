# XSearch 运行时的文件位置

XSearch 在使用过程中写入的全部位置。除特别说明外，都只在本机，不会上传。路径里的 `~` 指用户主目录，`$TMPDIR` 是系统为当前用户分配的临时目录（`/var/folders/…/T/`）。

## 1. 数据目录 `~/Library/Application Support/XSearch/`（权限 0700）

| 路径 | 内容 | 能否重建 | 大小参考（本机，约 17 万个文件名、231 个内容文件） |
|---|---|---|---|
| `catalog.sqlite`（及 `-wal`、`-shm`） | 文件目录数据库：每个文件的 id、父目录、名称、大小、修改时间、inode，是否在内容范围内，内容任务队列，操作日志 | 可以（重新扫描） | 30 MB + WAL 4 MB |
| `names/local.idx` | 文件名索引快照（启动时直接加载，不用重新扫描） | 可以（从 catalog 重建） | 16 MB |
| `content/<实例 id>/` | 内容索引（Tantivy）：提取出的正文、三元组索引、锚点；重建内容索引时会短暂并存两个实例，切换后删除旧的 | 可以（重新提取） | 6 MB；约为被索引正文的 1–2 倍 |
| `user.sqlite`（及 `-wal`、`-shm`） | **个人数据**：最近打开的记录（含打开次数，用于排序）、收藏 | **不能**，重建索引不会动它 | < 1 MB |

- 设置 › 隐私与数据 中的“重建文件名索引”会删除 `catalog.sqlite*`、`names/`、`content/` 后重新扫描；“重建内容索引”只重建 `content/`；`user.sqlite` 始终保留。
- 开发时可以用环境变量 `XS_DATA_DIR` 换一个数据目录。

## 2. 设置 `~/Library/Preferences/org.xsearch.XSearch.plist`

快捷键、文件名与内容索引范围、语法开关、匹配模式、打开方式、历史记录开关、是否完成首次引导等，约 4 KB。由系统的 UserDefaults 管理。

## 3. 缓存

| 路径 | 内容 |
|---|---|
| `~/Library/Caches/org.xsearch.XSearch/` | 系统网络缓存（`Cache.db`），以及 Sparkle 的更新缓存；检查更新时下载的新版 DMG 先放在 `org.sparkle-project.Sparkle/` 下，安装后由 Sparkle 清理。平时为几百 KB |
| `~/Library/HTTPStorages/org.xsearch.XSearch/` | 系统为检查更新的网络请求保存的 Cookie 存储，几十 KB |

## 4. 临时文件（`$TMPDIR`）

| 路径 | 何时产生 | 何时清除 |
|---|---|---|
| `xs-archive-<uuid>/` | 索引服务提取压缩包时，把包内可提取的文件解压到这里 | 这个压缩包处理完立即删除（只读一层，总量不超过 256 MB） |
| `XSearch-open/<uuid>/<文件名>` | 在结果里打开压缩包内的某个文件时，先把它单独解压到这里，再交给默认应用 | 应用每次启动时，删除超过一天的文件夹（当天的可能还开在别的应用里） |

## 5. 其他

- **崩溃报告**：如果 XSearch、IndexService 或提取进程 `xs-extract` 崩溃，macOS 会在 `~/Library/Logs/DiagnosticReports/` 生成 `.ips` 报告（由系统管理）。
- **开机启动**：通过系统的 SMAppService 注册登录项，不写文件；在 系统设置 › 通用 › 登录项 中可见。
- **系统权限记录**：完全磁盘访问、自动化（控制 Skim / 预览）、辅助功能等授权由系统的 TCC 数据库保存，不在 XSearch 的目录里。
- **钥匙串**：应用运行时不使用钥匙串。（开发者机器上，发布更新用的 Sparkle 签名私钥存在登录钥匙串的 `xsearch` 账户下，这只与发布有关，与使用无关。）
- **应用本身**：`XSearch.app`，其中包含 `Contents/MacOS/xs-extract`（提取进程）、`Contents/XPCServices/IndexService.xpc`（索引服务）、`Contents/Frameworks/Sparkle.framework`（自动更新），约 47 MB。

## 6. 完全卸载

退出 XSearch，删除下面这些位置：

```
/Applications/XSearch.app
~/Library/Application Support/XSearch
~/Library/Preferences/org.xsearch.XSearch.plist
~/Library/Caches/org.xsearch.XSearch
~/Library/HTTPStorages/org.xsearch.XSearch
$TMPDIR/XSearch-open
```

另外在 系统设置 › 通用 › 登录项、隐私与安全性 中移除 XSearch 的条目。

[简体中文](README.md) · **English**

![XSearch overview: search file names and document text on a Mac, preview and highlight the hits](docs/assets/xsearch-overview-zh.png)

# XSearch

**Find files and search inside documents on your Mac, then jump straight to the hit.**

XSearch is a native menu bar app for Apple silicon Macs. Press `⌥Space` to open apps or find files and folders. When all you remember is a sentence from a document, switch to Content search to look through indexed documents and see highlighted snippets. Files, indexes and queries stay on your Mac. Builds configured with an update feed check for updates over the network once at launch; you can turn this off in Settings › About.

## What it does

| Feature | When to use it |
| --- | --- |
| Name search and app launching | Type part of an app, file or folder name; open the result, press Space for Quick Look, or reveal it in Finder. |
| Document text search | Search indexed text by word, phrase, regular expression or proximity, with Loose, Case-sensitive or Exact matching. |
| Full Window and Reader | Filter and review large result sets in the Full Window; read hits in context and step through them in the Reader. How precisely a PDF or similar file opens at the hit depends on its format and the viewer you use. |
| Search inside archives | Index the supported files inside archives, see which member matched, and extract a single member to open it. |
| Separate index scopes | Manage folders, exclusions and status for names and content separately. The content index can also be limited by file type and file size. |
| Index control | Changes are picked up in real time. Pause content indexing, check everything again now, rescan a single folder, choose an indexing speed, and see and clear what the indexes take up. |

### Which documents can be searched

- **Documents and spreadsheets**: PDFs with a text layer, Word (DOC, DOCX, DOT, DOCM), Excel (XLS, XLSX, XLSM), PowerPoint (PPT, PPTX, PPS, PPTM), OpenDocument (ODT, ODS, ODP), and some WPS formats (WPS, ET, DPS).
- **Text and publications**: plain text, Markdown, logs, common source and configuration files, plus HTML, EPUB, FB2, RTF and OFD.
- **Email**: EML and Apple Mail EMLX messages: subject, sender, recipients, date, body and attachment names.
- **Mind maps**: XMind (current versions and XMind 8 or earlier): topics, labels, notes, boundary and relationship text on every sheet.
- **Archives**: ZIP, TAR, GZ, TGZ, 7z and RAR. XSearch searches the text extracted from members and marks which member matched.

Text search depends on what can actually be extracted. Pages of a scanned PDF without a text layer are marked as waiting for OCR; image text recognition is not available yet. Encrypted, damaged, oversized or inaccessible files may be extracted only in part, or not at all. Archives are opened one level deep, within an unpacking limit.

## Download and install

Requires **Apple silicon (arm64) and macOS 26 or later**. Check under ** → About This Mac**.

1. Download `XSearch-<version>.dmg` from **Releases** at the top of this project's GitHub repository. If there is no DMG, build from source as described below.
2. Open the DMG, drag `XSearch.app` into **Applications**, eject the disk image, and launch XSearch from **Applications** in Finder.
3. Use XSearch from the menu bar, or press `⌥Space`.

### If macOS blocks the first launch

The installer is not notarized by Apple yet. After confirming the download came from the project's release page, try to open XSearch from **Applications** once, then go to **System Settings → Privacy & Security**, choose **Open Anyway** in the Security section and confirm. This permission applies to this app only. [Apple's guide](https://support.apple.com/102445)

If the button doesn't appear and you have verified where the package came from and that its signature is intact, you can inspect and remove the download quarantine flag from this copy of the app in Terminal. Run these checks first, and only run the next commands after the signature check passes.

```sh
codesign --verify --deep --strict --verbose=2 "/Applications/XSearch.app"
xattr -p com.apple.quarantine "/Applications/XSearch.app"
```

```sh
xattr -dr com.apple.quarantine "/Applications/XSearch.app"
open "/Applications/XSearch.app"
```

A signature check only confirms that the signature matches the files. If it fails, or macOS says the app contains malware, stop and check the download. If `xattr -p` reports that the attribute doesn't exist, the launch fails for another reason; check the macOS version and chip first. If the app lives elsewhere, replace the path in the commands.

## Your first search

1. Choose content folders in the first-launch guide. **Downloads** is a good start; add project folders you use often later under **Settings → Index Scope**. By default the name index covers everything accessible, excluding some system folders, hidden items and common developer caches.
2. Press `⌥Space` and type part of a file or app name. If the shortcut is taken, open Settings from the menu bar and record a new one.
3. In the launcher, type lowercase `in` followed by a space, or press `⌘2`, to switch to Content search. In the Full Window, switch to **Content** directly. `⌘1` goes back to Name search.
4. Select a result with the arrow keys. `Return` opens it. `⌘Return` reveals it in Finder in Name search, and opens the Reader in Content search. `⌘E` opens the Full Window.

### Query examples

| Type in the launcher | Result |
| --- | --- |
| `project plan ext:docx;pdf` | Word or PDF files whose names contain both words. |
| `contract -draft kind:word` | Word documents named with “contract”, excluding names containing “draft”. |
| `ext:pdf dm:7d` | PDFs modified in the last seven days. |
| `in "project plan" dir:~/Documents ext:pdf;docx` | PDF or Word documents in Documents whose text contains the phrase. |
| `in "contract amount"~10` | Text where “contract” and “amount” appear within the given number of characters. |
| `in payment name:invoice` | Documents whose file name contains “invoice” and whose text contains “payment”. |
| `in regex:HT-[0-9]{4}` | Text matching a reference-number pattern. |

Both modes support Boolean combinations and `dir:`, `ext:`, `size:` and `dm:`. Name search adds `kind:` and wildcards; Content search adds `name:` file name conditions and proximity queries. In Content search `dir:` takes a file system path and accepts `~/`. Put paths containing spaces in straight double quotes. Press `⌘/` in the launcher for a syntax summary and the state of each switch. The full syntax, regular expressions and more examples are in the [Search Syntax and Regex Guide](docs/SEARCH-GUIDE.en.md).

### When nothing is found

First check the search mode, then look at **Settings → Index Scope** for the folder, exclusion rules, file types and size limit. Use **Diagnosis** to check the path and its index state. Right after you add a folder or change a file, its text may still be waiting to be extracted. Protected folders may need permission in **System Settings → Privacy & Security**; Full Disk Access is optional. Reopen XSearch after granting access.

If a file is in scope but its text cannot be found, look at the content index part of **Settings → Index Scope**: when files failed to extract it shows how many, with **Show Failed Files…** to see why each file failed and extract it again. If you suspect changes were missed, **Update Now** checks the whole scope again, or **Rescan** a single folder; if one content result looks wrong, choose **Index This File Again** from its context menu.

### Managing the indexes

XSearch follows file changes in real time through FSEvents, so there is normally nothing to update by hand. These actions are in the menu bar or Settings:

| Action | Where | What it does |
| --- | --- | --- |
| Pause / Resume Content Indexing | Menu bar; **Settings → Index Scope** | While paused, no file content is extracted; what is indexed stays searchable and the name index keeps updating. Changes in the meantime are noted and caught up after you resume. The paused state survives a restart. |
| Update Index Now | Menu bar; **Settings → Index Scope** | Checks the whole scope again, for when you suspect changes were missed (say, an external drive changed on another Mac). Each folder can also be **Rescan**ned on its own. |
| Index This File Again | Context menu of a content result | Extracts one file again. |
| Show Failed Files | **Settings → Index Scope** (when there are failures) | Lists the files that timed out, crashed the reader, used too much memory or could not be recognised, with the reason; extract the selected ones or all again, or copy the list for a report. |
| Indexing speed | **Settings → Index Scope** | **Performance**: several processes in parallel (2 to 4, depending on CPU cores), the fastest to finish; runs as Balanced on battery. **Balanced** (default): 2 processes. **Energy Saving**: 1 process at background priority, the least energy, slower to finish. Low Power Mode runs as Energy Saving. |
| Index storage and clearing | **Settings → Privacy & Data** | Shows what the name index, content index, personal data and temporary files take up, and cleans up leftover files. **Clear Content Index** or **Clear All Indexes** deletes the index files and pauses content indexing; resuming extracts again (clearing all rescans the name index at once, so name search keeps working). Favorites, recents and settings are always kept. |

## Build from source

You need an Apple silicon Mac, a full Xcode with the macOS 26 SDK and Swift 6.2 or later, and Rust stable (with Cargo) for Apple silicon. Finish installing components in Xcode and make sure `xcode-select -p` points to it. The build scripts download the locked versions of the Rust dependencies and Sparkle, so the first build needs a network connection.

Clone the repository, or download `XSearch-<version>-source.tar.gz` for a release (it includes every Rust dependency's source, so dependencies need no download), then run in the source root:

```sh
xcodebuild -version
swift --version
rustc --version
cargo --version

bash scripts/build-app.sh
open target/XSearch.app
```

The build produces the Rust shared library, the Swift executable, the indexing XPC service and the extraction subprocess, then assembles `target/XSearch.app`. It is signed ad hoc by default; set `XS_SIGN_IDENTITY` to use a development signing identity. Local builds have no update feed by default.

```sh
# Build a DMG at target/XSearch-<version>.dmg
bash scripts/build-dmg.sh

# Run the Rust and Swift tests
source scripts/env.sh
cargo test --workspace --locked
bash scripts/swift-test.sh
```

Before the first Swift test run in a clean checkout, build the app or run `bash scripts/fetch-sparkle.sh` so the framework is in place.

## Data on your Mac and feedback

Indexes and records live in `~/Library/Application Support/XSearch/`. The content index contains the extracted text. Under **Settings → Privacy & Data** you can see what each part takes up and clear or rebuild the indexes; favorites and recently opened items are kept in a separate database and survive clearing. To uninstall, quit the app and move it to the Trash. To remove its data as well, back up any favorites and history you want to keep before deleting the data folder. All locations are listed in [Files on Your Mac](docs/STORAGE.en.md).

If you run into a problem, open a GitHub **Issue** with your macOS version, XSearch version, search mode and the smallest steps that reproduce it. If synthetic files reproduce it, attach those.

## License

XSearch's original code is licensed under the **GNU General Public License version 3, with an UnRAR linking exception**. You may use, modify and redistribute it under that license, including commercially. The linking exception allows distributing XSearch linked with the specified UnRAR implementation; UnRAR remains under its own license. Redistributions must keep the applicable notices and provide the corresponding source as required. Every release includes a complete source archive of the same version, and the DMG and app bundle contain the license texts and third-party notices. The software is provided under the terms of GPLv3, without warranty.

[GPLv3](LICENSE) · [UnRAR linking exception (Chinese)](LICENSES/XSearch-UnRAR-linking-exception.md) · [Third-party notices (Chinese)](THIRD_PARTY_NOTICES.md) · [Search syntax](docs/SEARCH-GUIDE.en.md) · [Design guide](docs/DESIGN.en.md) · [Changelog](CHANGELOG.en.md) · [Contributing](CONTRIBUTING.en.md)

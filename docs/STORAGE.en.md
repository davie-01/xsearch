[简体中文](STORAGE.md) · **English**

# Files on Your Mac

Every location XSearch writes to while in use. Unless noted otherwise, everything stays on your Mac and is never uploaded. `~` in a path is your home folder; `$TMPDIR` is the temporary folder macOS assigns to your user (`/var/folders/…/T/`).

## 1. Data folder `~/Library/Application Support/XSearch/` (permissions 0700)

| Path | Contents | Rebuildable | Size for reference (one Mac, about 170,000 file names and 231 content files) |
|---|---|---|---|
| `catalog.sqlite` (plus `-wal`, `-shm`) | File catalog: each file's id, parent folder, name, size, modification time and inode, whether it is in the content scope, the content task queue, the operation journal | Yes (rescanned) | 30 MB + 4 MB WAL |
| `names/local.idx` | File name index snapshot (loaded at launch instead of rescanning) | Yes (from the catalog) | 16 MB |
| `content/<instance id>/` | Content index (Tantivy): extracted text, trigram index, anchors. While the content index is rebuilt, two instances briefly coexist; the old one is deleted about a minute after the switch (or at the next launch if you quit first) | Yes (re-extracted) | 6 MB; about 1–2× the indexed text |
| `user.sqlite` (plus `-wal`, `-shm`) | **Personal data**: recently opened items (with open counts, used for ranking) and favorites | **No**; rebuilding indexes never touches it | < 1 MB |

- **Storage** under Settings › Privacy & Data shows the sizes of the name index (`catalog.sqlite*` + `names/`), the content index (`content/`), personal data (`user.sqlite*`) and temporary and leftover files.
- **Clean Up** removes leftovers: `retired-*/`, and in the temporary directory `XSearch-open/` folders and `xs-archive-*/` older than an hour (younger ones may still be in use).
- **Clear Content Index** deletes the index in `content/` at once and pauses content indexing; resuming extracts every content file again. **Rebuild Content Index** builds a new instance in the background and keeps using the old one until it is done.
- **Rebuild File Name Index** deletes `catalog.sqlite*`, `names/` and `content/`, then rescans; **Clear All Indexes** deletes the same files and also pauses content indexing: the name index is scanned again at once, content is extracted after resuming.
- `user.sqlite` and the settings are always kept.
- When the file name index is rebuilt, the old files are first moved to `retired-<uuid>/` in the same folder and deleted in the background; if you quit midway, they are cleaned up at the next launch.
- During development the environment variable `XS_DATA_DIR` selects a different data folder.

## 1.1 Size estimates

Neither index depends on **disk capacity**: the file name index grows with the **number of files**, the content index with **how much text can be extracted from the content scope**.

**Measured on one Mac (2026-11-01)**

| Item | Figures |
|---|---|
| File name index | 172,656 entries: catalog.sqlite 30.7 MB + name snapshot 16.5 MB ≈ 47 MB, **about 270 bytes per entry** (about 180 B in the database, 95 B in the snapshot); about 17.5 MB resident memory |
| Content index | 231 files in the content scope, 485 MB of original files → 14.7 MB of extracted text (UTF-8, about 12 million characters) → 6.3 MB index, **0.43× the text**, about **1.3%** of the original files |
| Synthetic comparison | 10,000 documents, 89.7 MB of text → 29.4 MB index (0.33×; synthetic text repeats a lot) |

The content index stores the Zstd-compressed text (about 40% of the original) plus the trigram postings.

**File name index by number of files**

| Files | Disk | Memory |
|---|---|---|
| 100,000 | about 27 MB | about 10 MB |
| 500,000 | about 135 MB | about 50 MB |
| 1,000,000 | about 270 MB | about 80–100 MB (M1 benchmark: 79 MB base layer for 1 million entries) |
| 3,000,000 | about 0.8 GB | about 250–300 MB |

A 100 GB disk usually holds 300,000–1,000,000 files (more with developer folders or photo libraries), so the file name index takes about **0.1–0.3 GB, or 0.1%–0.3% of the disk**.

**Content index by content** (only folders added to the content scope count)

| The content scope mostly holds | Extracted text vs. original files | Content index vs. original files |
|---|---|---|
| Photos, video, audio, installers | 0 (not extracted) | 0 |
| Office / PDF / OFD documents (with images and layout) | 2%–10% | **1%–4%** (1.3% measured) |
| Plain text, code, web pages, CSV | about 100% | **about 35%–45%** |
| Archives | Depends on the documents inside (one level only, at most 256 MB unpacked per archive) | Same as above |

For example, adding 20 GB of office documents on a 100 GB disk gives a content index of about 0.2–0.8 GB; 20 GB of code and text gives about 7–9 GB.

**Temporary extra space**: during a content index rebuild the old and new indexes coexist until the switch; SQLite's WAL grows by a few MB between checkpoints; extracting an archive puts at most 256 MB of unpacked files in the temporary folder, deleted as soon as the archive is done.

## 2. Settings `~/Library/Preferences/org.xsearch.XSearch.plist`

Hotkey, file name and content scopes, syntax switches, match mode, Open With, history switch, whether onboarding is finished and so on, about 4 KB. Managed by the system's UserDefaults.

## 3. Caches

| Path | Contents |
|---|---|
| `~/Library/Caches/org.xsearch.XSearch/` | The system network cache (`Cache.db`) and Sparkle's update cache; a new DMG downloaded by an update check goes under `org.sparkle-project.Sparkle/` and is cleaned up by Sparkle after installing. Usually a few hundred KB |
| `~/Library/HTTPStorages/org.xsearch.XSearch/` | Cookie storage the system keeps for update check requests, tens of KB |

## 4. Temporary files (`$TMPDIR`)

| Path | Created when | Removed when |
|---|---|---|
| `xs-archive-<uuid>/` | The index service extracts an archive: its extractable members are unpacked here | As soon as that archive is done (one level only, at most 256 MB in total) |
| `XSearch-open/<uuid>/<file name>` | You open a file inside an archive from the results: it is unpacked here on its own, then handed to the default app | At each app launch, folders older than a day are deleted (today's may still be open in another app) |

## 5. Other

- **Crash reports**: if XSearch, IndexService or the extraction process `xs-extract` crashes, macOS writes an `.ips` report to `~/Library/Logs/DiagnosticReports/` (managed by the system).
- **Open at login**: registered as a login item through the system's SMAppService; no file is written. Visible in System Settings › General › Login Items.
- **Permission records**: Full Disk Access, Automation (controlling Skim / Preview), Accessibility and other grants are kept in the system's TCC database, not in XSearch's folders.
- **Keychain**: the app doesn't use the Keychain. (On the developer's machine, the Sparkle signing key for publishing updates lives in the login Keychain under the `xsearch` account; that concerns releasing, not using the app.)
- **The app itself**: `XSearch.app`, containing `Contents/MacOS/xs-extract` (extraction process), `Contents/XPCServices/IndexService.xpc` (index service), `Contents/Frameworks/Sparkle.framework` (auto-update) and `Contents/Resources/Licenses/` (license texts), about 50 MB.

## 6. Uninstalling completely

Quit XSearch and delete these locations:

```
/Applications/XSearch.app
~/Library/Application Support/XSearch
~/Library/Preferences/org.xsearch.XSearch.plist
~/Library/Caches/org.xsearch.XSearch
~/Library/HTTPStorages/org.xsearch.XSearch
$TMPDIR/XSearch-open
```

Also remove XSearch's entries under System Settings › General › Login Items and Privacy & Security.

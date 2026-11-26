[简体中文](CHANGELOG.md) · **English**

# Changelog

User-facing changes, newest version first. Versions follow `major.minor.patch`.

## Unreleased

### Improved

- The content index shows its state and progress: the menu bar menu and a new status bar at the bottom of the Settings window read “Indexing 12,340 / 25,600 (48%) · about 6 min left”, “Removing…”, “Checking files…”, “Ready · 28,625 files · 78 failed” or “Paused · N waiting”, and for a minute after a run “Just finished N files · took …”; in Settings › Index Scope each content folder shows its own indexed, waiting and failed counts. The figures used to update only once a whole run of files had finished, showing old values until then.
- Progress is counted and refreshed only while someone looks: every second while the menu is open or the Settings window is on screen; otherwise the index service counts nothing and sends the app no progress.
- Removing a content folder is much faster: deletions alone are handled thousands at a time, so 25,000 files go in seconds (one index commit per 64 files before). Removal asks first and says how many files’ content index it deletes.
- Clicking the menu bar icon opens the search field (as the hot key does); right-click (or Control-click) shows the menu.
- Settings has a new About page: the app icon, version, Check for Updates and View on GitHub (Check for Updates moved from General).
- Updates are checked once at launch (can be turned off on the About page) and mentioned only when there is a new version; no more scheduled background checks. Turned off, XSearch goes online only when you click “Check for Updates…”.
- “Rescan”, “Remove” and “Add Folder” next to folders and exclusion rules in Settings are now buttons with icons.
- Files whose extension does not match their format are read too: the file header is checked before extraction and the real format decides. This covers Word 97 documents saved as .docx, Excel 2003 XML spreadsheets and “single file web pages” saved as .xls, .xls files that are really xlsx, .doc files that are really RTF or PDF, and more; password-protected Office documents are reported as encrypted rather than damaged. .xls workbooks whose macros use an unknown code page now have their sheets read. After the update only files that failed before are extracted again.
- The lock files Office creates while a document is open (`~$Report.docx`, a few bytes naming the user) are no longer extracted as documents and no longer appear among the files that failed.
- Adding or removing a content folder inside the file name scope, or changing the content file types, decides from the existing file list which files to extract or remove, so extraction starts within seconds instead of after re-checking the whole disk. A folder reaching outside the name scope (or holding an excluded place) is still scanned. A long scan now starts extraction as it goes.

## 1.0.0 — 2026-11-25

### Improved

- The download shrinks from about 21 MB to about 8 MB, and the installed app from 53 MB to 18 MB: the app, the index service and the extraction worker share one copy of the Rust engine (each used to carry its own), the engine is built with link-time optimisation, and release builds ship without debug symbols. Features and search results are unchanged; extraction is slightly faster.

## 0.3.0 — 2026-11-25

### Added

- The content index reads FictionBook e-books (.fb2, inside archives too): title, authors, annotation, keywords and the text (poems, citations and tables included), then the notes. Located by chapter and paragraph; the encoding declared in the XML header (windows-1251, for example) is honoured, and malformed files are read leniently like web pages. They count as the e-book type, shown in Settings as “E-book (epub, fb2)”.
- The content index reads XMind mind maps (.xmind), both the `content.json` of current versions and the `content.xml` of XMind 8 and earlier: topics (floating and summary topics included), labels, notes, boundary and relationship text, located by sheet. Encrypted maps cannot be read. Settings and the Full Window have a new “Mind map” type.
- The content index reads email messages (.eml, and Apple Mail .emlx): subject, sender, recipients, Cc, date, body and attachment names, located by “Headers / Body / Attachments”. MIME multipart messages, encoded words (GBK or UTF-8 subjects, for example) and other character sets are handled; HTML-only bodies are read like web pages. Attachment contents are not read yet. Settings and the Full Window have a new “Email” type.
- The content index reads OpenDocument text (.odt) and presentations (.odp): .odt located by paragraph and table cell, with footnotes and text frames; .odp by slide, speaker notes after their slide. They count as the Word and PowerPoint types (.ods already counted as Excel).
- Zip members compressed with BZip2 can be read (the pure-Rust bzip2 decoder 7z support already uses; no new dependency).
- Content search accepts `name:` file name conditions together with the text, e.g. `in payment name:invoice`. Semicolon-separated values in one `name:` are alternatives, several `name:` terms must all match, and `*` / `?` match the whole name; the condition applies before the result limit. In the Full Window, Content search can set “File name” in the condition bar.
- The Full Window can narrow the current results with “Within” steps (`⇧⌘F`): words that must all appear, any of which may appear, or none of which may appear (optionally an exact match). Steps can be removed one by one or undone; it works in Name and Content search and applies before the result limit.

### Improved

- The launcher looks like Spotlight on macOS 26, measured from it: the glass no longer carries a light-grey (dark mode) or white (light mode) veil, keeps the colour of what lies behind and reads more clearly; result rows are 56 pt high with 17 pt names, a 14.5 pt second line and icons as large as Spotlight's; the selection, the filter pills and the hairlines take Spotlight's colours in each appearance; the pills sit 11 pt below the rule; the list shows whole rows only, so the last one is never cut; search results no longer carry an “Apps” heading; once the list scrolls, a hairline under the pills clips the rows passing beneath it.
- Icons follow System Settings → Appearance → Icon & widget style: with Dark, app, folder and file icons are shown dark, as in Spotlight and the Dock.
- The content index no longer keeps its extraction processes while idle: they exit after 30 seconds with nothing to extract and start again (in a few milliseconds) when a file comes in, saving about 70–140 MB of memory when idle.
- No blue keyboard focus rings anywhere (checkboxes, buttons, tables, Settings, the onboarding window and so on): the caret, the selection and the highlighted row show where you are.
- Content indexing has a speed setting: Performance, Balanced (default) and Energy Saving. Energy Saving uses one process at background priority, measured at about 40% of Balanced's CPU energy but about 5.7 times the time; Performance finishes about 30% sooner than Balanced for similar energy. Low Power Mode always runs as Energy Saving, and Performance runs as Balanced on battery.
- A zip member with an unsupported compression method (such as BZip2) or damaged data no longer fails the whole archive: the other members are indexed, the archive is marked partly indexed with the number skipped, and it fails only when nothing at all can be read. Members that are not wanted (type, per-file limit) are no longer checked for their compression method. Archives are extracted once more after updating.
- Indexes can be updated by hand: Update Now in the menu bar and Settings → Index Scope checks the whole scope again, each folder can be rescanned on its own, Index This File Again in a content result's context menu forces a fresh extraction, and the content index card shows how many files failed to extract, with a list of each file and its reason that can reveal them in Finder, copy the list or extract them again.
- Settings → Privacy & Data shows index storage by kind (name index, content index, personal data, temporary and leftover files) and cleans up leftovers. New Clear Content Index and Clear All Indexes delete the files and pause content indexing until you resume; recents, favorites and settings are always kept.
- Content indexing can be paused and resumed (menu bar or Settings → Index Scope), and stays so across restarts. While paused, no file content is extracted and the extraction processes exit; what is indexed stays searchable, and file changes are noted and extracted after resuming. The name index keeps updating in real time.
- The Full Window is redesigned: no sidebar; below the search field a row of fixed-width condition buttons (location, type, date, size, plus file name and match mode in Content search) shows each set value, with Clear All and the equivalent query text to view and copy. The count, Show All and shortcut hints move to a status bar. An empty Name search lists favorites and recents under headings; an empty Content search shows the scope and examples; no results lists the likely reasons and what to try. The result table gets the launcher's context menu.
- Full Window name results over 5,000 get a Show All button next to the count; sorting by a column fetches every match first (up to 100,000) instead of sorting only the first 5,000.
- The launcher's `⌘/` syntax summary is now a grouped list with examples and explanations in two columns, clearer wording, and switched-off syntax clearly marked. Fixes the summary showing as an empty narrow strip over the launcher.
- `Esc` in the launcher now steps back one layer at a time: it closes the syntax summary or Quick Look first, then clears the input, and only then hides the panel; quick repeated presses are no longer lost.

## 0.2.0 — 2026-11-18

First public release.

### Features

- Lives in the menu bar; `⌥Space` opens the launcher to find apps, files and folders, preview with Space, and reveal in Finder.
- Document text search: words, phrases, Boolean combinations, regular expressions and proximity, with Loose, Case-sensitive and Exact matching; `dir:`, `ext:`, `size:` and `dm:` filters, plus `kind:` and wildcards in Name search.
- Supports PDFs with a text layer, Word, Excel, PowerPoint, ODS, some WPS formats, plain text and code, HTML, EPUB, RTF, OFD, and files inside ZIP, TAR, GZ, TGZ, 7z and RAR archives.
- Full Window (`⌘E`) and Reader (`⌘Return`): filter large result sets and step through hits.
- Separate index scopes, exclusions, file types and size limits for names and content; the Diagnosis page explains why a file isn't found.
- Favorites and recently opened items; the interface is available in Simplified Chinese and English.
- Checks GitHub Releases for updates (Sparkle, EdDSA-signed); can be turned off in Settings.

### Release

- New app and menu bar icons; the app icon follows the system's light and dark appearance.
- Released under GPLv3 with an UnRAR linking exception. The DMG and the app bundle include the license texts, third-party notices and Rust dependency licenses; each release provides a source archive with every dependency's source.
- Signed with a development certificate and not notarized by Apple; the first launch must be confirmed in System Settings → Privacy & Security.

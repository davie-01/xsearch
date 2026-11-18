[简体中文](CHANGELOG.md) · **English**

# Changelog

User-facing changes, newest version first. Versions follow `major.minor.patch`.

## Unreleased

### Added

- Content search accepts `name:` file name conditions together with the text, e.g. `in payment name:invoice`. Semicolon-separated values in one `name:` are alternatives, several `name:` terms must all match, and `*` / `?` match the whole name; the condition applies before the result limit. In the Full Window, Content search can set “File name” in the condition bar.
- The Full Window can narrow the current results with “Within” steps (`⇧⌘F`): words that must all appear, any of which may appear, or none of which may appear (optionally an exact match). Steps can be removed one by one or undone; it works in Name and Content search and applies before the result limit.

### Improved

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

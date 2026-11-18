[简体中文](CHANGELOG.md) · **English**

# Changelog

User-facing changes, newest version first. Versions follow `major.minor.patch`.

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

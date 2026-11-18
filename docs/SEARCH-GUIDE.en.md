[简体中文](SEARCH-GUIDE.md) · **English**

# XSearch Search Syntax and Regex Guide

Checked on 2026-11-04 against the source and tests, for the search field of the desktop app; only implemented syntax is described. The syntax of the early `xs` CLI is in its `help` output. Not every example has been tried in the interface; if the app behaves differently from this guide, the running version wins, and please report it.

Chinese aliases (such as `kind:文档` or `dm:今天`) work in the English interface too; they are listed next to the English values below.

## 1. Two search modes

| Mode | Searches | How to enter it |
| --- | --- | --- |
| Name search | App names, file names, folder names | `⌘1` in the launcher; in the Full Window choose Name or press `⌘1` |
| Content search | The text of documents that have been extracted and indexed | Type `in ` in the launcher, or press `⌘2`; in the Full Window choose Content or press `⌘2` |

The default launcher shortcut is `⌥Space`; you can change it in Settings. The launcher opens in Name search, or can remember the last mode.

```text
rollout
```

In Name search, finds items whose names contain “rollout”.

```text
in rollout
```

In the launcher, switches to Content search and finds documents whose text contains “rollout”. Once typed, `in ` turns into a “Content” token in the field and is no longer part of the text.

Notes:

- The prefix must be a lowercase `in` at the start, followed by a regular space. `in:`, `IN ` and `find ` are not the same.
- The automatic switch on `in ` exists in the launcher only. In the Full Window, switch modes first, then type the query.
- Once in Content search, you don't need `in ` again. The `in ` in the content examples below is there so you can start straight from the launcher.
- Plain keywords in Content search look at the text; they don't also require the file name to contain the keyword.

## 2. Syntax at a glance

| Syntax | Does | Name search | Content search | Example |
| --- | --- | --- | --- | --- |
| Plain text | Contains the keyword | Yes | Yes | `smartcity` |
| Space | All words present, AND | Yes | Yes | `city report` |
| `"…"` | Spaces and operators inside are literal text | Yes | Yes | `"annual report"` |
| `\` | Escapes the next special character | Yes | Yes | `\-draft` |
| `\|` | Either condition, OR | Yes | Yes | `contract \| agreement` |
| Leading `-` | Excludes the following text expression | Yes | Yes | `contract -draft` |
| `(…)` | Groups text expressions | Yes | Yes | `(contract \| agreement) -draft` |
| `dir:` | Limits to a folder and everything below it | Full paths and folder name segments | Full paths only | `dir:~/Documents` |
| `ext:` | Filters by extension | Yes | Yes | `ext:pdf;docx` |
| `name:` | Narrows text results by file name | Not needed; type the keyword | Yes | `in payment name:invoice` |
| `kind:` | Filters by file kind | Yes | **No kind filter** | `kind:folder` |
| `size:` | Filters by file size on disk | Yes, folders excluded | Yes | `size:>10mb` |
| `dm:` | Filters by modification date | Yes | Yes | `dm:7d` |
| `*`, `?`, `**` | Wildcards | Yes | Not treated as wildcards | `*rollout*.pdf` |
| `regex:` | Regular expression | Name or path | Extracted text | `regex:HT-[0-9]{4}` |
| `"a b"~N` | Words within a given character distance | No proximity | Yes | `in "contract amount"~10` |

Operators, wildcards, regular expressions and proximity can each be switched on or off under **Settings → Search Syntax**; all are on by default. A switched-off syntax is searched as plain characters, so the examples here no longer apply to it. Press `⌘/` in the launcher for a summary and the state of each switch.

Use ASCII colons, straight double quotes and ASCII parentheses. Don't put a space after a prefix: write `ext:pdf`, not `ext: pdf`.

## 3. Keywords, phrases and Boolean combinations

### 3.1 Plain text means “contains”

```text
smartcity
```

In Name search this matches `009-smartcity-project` without any asterisks: it is a contains match, not a starts-with match. Plain words search names only; a `/` doesn't turn them into a path query.

Name matching ignores case. It offers no pinyin or initial-letter transliteration and doesn't correct typos. Name matching normalizes differently from Content search, and the content match settings don't affect file name search.

### 3.2 Spaces: all words, in any order

```text
city rollout
```

The name must contain both “city” and “rollout”.

```text
in contract amount
```

The extracted text of one document must contain both words, anywhere; they don't need to be adjacent.

### 3.3 Double quotes: spaces and symbols as text

```text
"annual report"
"contract(final)"
"dir:contracts"
```

These search for consecutive text with a space, a name with parentheses, and the literal text `dir:contracts`. Quotes don't mean the whole name or document must be exactly equal; for a whole-name match use a regular expression anchored at both ends.

In Content search, whether whitespace differences inside a phrase matter also depends on the Loose / Case-sensitive / Exact setting.

### 3.4 OR, NOT and grouping

| Input | Meaning |
| --- | --- |
| `contract \| agreement` | The name contains either word |
| `contract -draft` | The name contains “contract” and not “draft” |
| `contract -(draft \| void)` | Contains “contract”, excluding items with “draft” or “void” |
| `(contract \| agreement) 2026` | Contains “contract” or “agreement”, and “2026” |
| `in (acceptance \| rollout) -void` | The text contains “acceptance” or “rollout”, and not “void” |

Precedence: a leading exclusion binds tighter than the space AND, and AND binds tighter than OR; add parentheses for anything complex. The words `AND`, `OR` and `NOT` are not operators.

A pure exclusion such as `in -draft` can produce a huge candidate set; adding a positive keyword and `dir:` or `ext:` is usually more useful. An incomplete content query, such as a missing closing parenthesis or quote, may show a parse error; complete it before judging the results.

### 3.5 Escaping

```text
\-draft
contract\(final\)
"a|b"
```

These search for the literal `-draft`, `contract(final)` and `a|b`. For ordinary names with special characters, quoting is usually simpler; to use an asterisk as text inside a name wildcard, you can also quote the whole term.

## 4. `dir:`: limit the search to a folder

### 4.1 Full paths and the home folder

```text
report dir:~/Documents
report dir:/Users/me/Documents
in rollout dir:~/Documents
```

`~` is your home folder. The scope includes everything below the folder, not only its first level. In Name search, `dir:` limits results to what is inside the folder; it doesn't find the folder itself. To find a folder, use a keyword with `kind:folder`.

Write the actual file system path; don't substitute the localized names Finder shows for folders.

### 4.2 Paths with spaces

```text
rollout dir:"/Users/me/Documents/Work Files/Clients/009-smartcity-project"
in rollout dir:"/Users/me/Documents/Work Files/Clients/009-smartcity-project"
```

Put the path after the colon in straight double quotes, with the `dir:` prefix outside them. Full paths work in both modes.

### 4.3 Name search only: folder name segments

```text
report dir:contracts
report dir:contracts/2024
```

The first searches folders named “contracts” and everything below them; the second requires consecutive folder levels named “contracts/2024”.

A segment is a path level: **each folder name must match in full**, not as a substring. `dir:smartcity` does not reach `009-smartcity-project`; write the full folder name or the full path.

Content search doesn't support segments. `in report dir:contracts` asks for a full path; an invalid folder condition doesn't limit the scope as intended.

### 4.4 Several folders: the union

```text
contract dir:~/Documents dir:~/Downloads
```

Searches either folder; an item doesn't have to be in both. Write one `dir:` per path; don't join paths with semicolons.

`dir:` limits a query; it doesn't create an index. It neither indexes the folder's content nor reads all its files. For a folder without a content index, the app may offer “Scan the text files there now”, which you have to click; it scans supported text files only and doesn't extract PDFs, Word files or images on the fly.

## 5. `kind:`: files, folders or apps by kind

**Only Name search understands `kind:`.** Kinds group items by folder/app markers and extensions; they don't classify document content.

| Kind | Accepted values (aliases) | Currently covers |
| --- | --- | --- |
| Folder | `folder`, `dir`, `directory`, `文件夹`, `目录` | Folders |
| App | `app`, `application`, `应用` | Apps |
| PDF | `pdf` | pdf |
| Text document | `doc`, `word`, `文档` | doc, docx, wps, rtf, pages, odt |
| Spreadsheet | `xls`, `excel`, `sheet`, `表格` | xls, xlsx, csv, numbers, ods, et |
| Presentation | `ppt`, `slide`, `powerpoint`, `演示` | ppt, pptx, key, odp, dps |
| OFD | `ofd` | ofd |
| Text and code | `text`, `txt`, `code`, `文本`, `代码` | See the full list below |
| Image | `image`, `img`, `picture`, `图片` | png, jpg, jpeg, gif, heic, heif, webp, tif, tiff, bmp, svg, raw, dng |
| Video | `video`, `视频` | mp4, mov, m4v, avi, mkv, webm |
| Audio | `audio`, `music`, `音频` | mp3, m4a, aac, wav, flac, aiff, ogg |
| Archive and disk image | `archive`, `zip`, `压缩包` | zip, rar, 7z, tar, gz, tgz, bz2, xz, dmg, iso |

The extensions of `kind:text`:

```text
txt md markdown log json xml yaml yml toml ini
swift rs c h m mm cpp hpp py js ts tsx jsx go java kt rb sh zsh html css sql
```

Usage:

```text
smartcity kind:folder
contract kind:doc
rollout kind:pdf
budget kind:sheet
Safari kind:app
contract kind:pdf;word
```

`kind:pdf;word` accepts either kind; commas or repeated `kind:` work too.

Easy to get wrong:

- `kind:doc` is not just `.doc`; for that extension alone write `ext:doc`.
- `kind:zip` is the whole archive/disk image kind, not just `.zip`.
- `kind:docx`, `kind:xlsx`, `kind:其他` and `kind:other` are not valid aliases; use `ext:` for an exact extension.
- Name kinds and content extraction cover different formats: finding an extension by name doesn't mean that format is extracted or indexed.
- In Content search, `kind:pdf` doesn't become a type filter; it usually ends up as text in the query. Use `in keyword ext:pdf` instead.

App launch results have a name index of their own. Plain app names and `Safari kind:app` are the usual way; wildcards, regular expressions, complex Boolean conditions and a bare `kind:app` don't promise the same complete set of apps as a plain app name search. More complex app conditions may depend on whether the file name index includes the `.app`.

## 6. `ext:`: only certain extensions

```text
contract ext:pdf
contract ext:doc;docx
contract ext:doc,docx,pdf
in rollout ext:pdf;docx
```

Works in both modes and ignores case; the leading dot is optional (`ext:.pdf` works). Several extensions form a union; repeated `ext:` terms are merged too.

`ext:docx` differs from `kind:doc`: the first is one exact extension, the second a group.

Don't use wildcards in `ext:`; `ext:*.pdf` is not `ext:pdf`. The filter only narrows existing candidates; it doesn't make unsupported formats searchable by text.

## 7. `name:`: narrow Content search by file name

Keywords in Content search look at the text only. To limit the file name as well, add `name:`:

```text
in payment name:invoice
in payment name:invoice;settlement
in payment name:invoice name:2026
in budget name:*.xlsx
in goals name:"annual report"
```

In order: text contains “payment” and the file name contains “invoice”; the name contains “invoice” or “settlement”; the name contains both “invoice” and “2026”; the name ends in `.xlsx`; the name contains “annual report”, with its space.

Rules:

- It is a **contains** match, ignoring case, with the same folding as Name search.
- Values in one `name:`, separated by semicolons or commas, form a **union**; several `name:` terms **intersect** and must all match.
- With `*` or `?` a value is a **whole-name wildcard**: `*` any number of characters, `?` exactly one. Wildcards in `name:` don't depend on the Wildcards syntax switch.
- Quote values containing spaces with straight double quotes.
- Archive members pass when either the archive's name or the member's own name matches.
- The name condition applies before the text is verified and before the result limit, so a match is never hidden just because it wasn't among the first 1,000 results.
- Like other filters it applies to the whole query, not to one OR branch; `-name:` is not an exclusion.
- `in name:invoice` alone has no text condition and lists nothing; to find files by name only, use Name search.

In the Full Window, the Content sidebar has a “File name contains” field that does the same as `name:`; separate several values with semicolons there too.

Name search doesn't need `name:`: the keywords you type already search file names.

## 8. `size:`: filter by file size

Size is the file's size on disk in bytes, not a word count, page count or the size of the extracted text. In Name search, `size:` excludes folders; it can't compute a folder's total size.

| Input | Meaning |
| --- | --- |
| `size:>10mb` | Larger than 10×1024×1024 bytes |
| `size:>=10mb` | At least that size |
| `size:<1m` | Smaller than 1×1024×1024 bytes |
| `size:<=500k` | At most 500×1024 bytes |
| `size:empty` or `size:空` | Files of 0 bytes |
| `size:1024` | Exactly 1024 bytes |
| `size:>=1m size:<=10m` | Exactly between 1 MiB and 10 MiB, both ends included |

Units: `b`, `k/kb`, `m/mb`, `g/gb`, `t/tb`, case-insensitive, all powers of 1024; without a unit the value is in bytes. Decimals work, e.g. `size:>1.5m`.

**A special rule in the current implementation: a bare value or range with a unit extends its upper bound to the whole unit.**

- `size:1m` (also `size:=1m`) means 1 MiB up to but not including 2 MiB, not exactly 1 MiB.
- `size:1m..2m` means 1 MiB up to but not including 3 MiB, not the 1–2 MiB you might expect.
- For exact bounds, use two comparisons, e.g. `size:>=1m size:<=2m`.

Combined:

```text
rollout ext:pdf size:>10mb
in contract ext:docx size:<=20m
```

## 9. `dm:`: filter by modification date

`dm` is the modification date, not the creation date or the indexing date. Dates follow your Mac's calendar and time zone; the first day of the week follows your calendar settings.

### 9.1 Shortcuts

| English | Chinese alias | Meaning |
| --- | --- | --- |
| `today` | `今天` | Today, the calendar day |
| `yesterday` | `昨天` | Yesterday |
| `thisweek` | `本周` | The current calendar week |
| `lastweek` | `上周` | The previous calendar week |
| `thismonth` | `本月` | The current calendar month |
| `lastmonth` | `上月` | The previous calendar month |
| `thisyear` | `今年` | The current calendar year |
| `lastyear` | `去年` | The previous calendar year |

```text
report dm:today
contract dm:thismonth
in rollout dm:7d
```

Relative times take a positive integer with `d/天`, `w/周`, `m/月` or `y/年`. `7d` runs from 7 days before the moment of the query until now; `3m` goes back 3 calendar months, which is not the same as three whole calendar months.

### 9.2 Dates, comparisons and ranges

| Input | Meaning |
| --- | --- |
| `dm:2026` | All of 2026 |
| `dm:2026-11` | November 2026 |
| `dm:2026-11-04` | That calendar day |
| `dm:>=2026-11-01` | From that day on |
| `dm:>2026-11-01` | After that day ends, i.e. from the next day |
| `dm:<=2026-11` | Until the end of November 2026 |
| `dm:<2026` | Before 2026 starts |
| `dm:2026-01..2026-06` | From the start of January to the end of June 2026 |

Dates also accept `/` or `.` as separators, but `YYYY-MM-DD` is recommended. A range includes the whole periods at both ends. Repeated `dm:` terms intersect, e.g. `dm:>=2026-01-01 dm:<2027-01-01`.

## 10. Name search wildcards: `*`, `?`, `**`

Wildcards must be switched on in Settings. Content search doesn't treat these characters as name wildcards; to limit content results by extension, use `ext:`.

| Symbol | Meaning |
| --- | --- |
| `*` | Zero or more characters, not crossing `/` |
| `?` | One Unicode scalar, not `/`; a CJK character usually counts as one, a composed emoji may not |
| `**` | Zero or more characters, crossing `/` |

Wildcards match **the whole term**: without `/` they match the whole name; with `/` the full path. That differs from the contains match of plain text.

| Example | Meaning |
| --- | --- |
| `*.pdf` | Name ends with `.pdf` |
| `rollout*` | Name starts with “rollout” |
| `*rollout*` | Name contains “rollout” anywhere |
| `*rollout.pdf` | Name ends with “rollout.pdf” |
| `report?.docx` | “report”, exactly one character, then “.docx” |
| `**/contracts/*.pdf` | PDFs directly inside any folder named “contracts”; the last `*` doesn't cross into subfolders |
| `/Users/me/Documents/**` | Everything at any depth below that path |

For a relative path pattern such as `contracts/*.pdf`, any ancestor path is allowed in front. Don't assume `**` here implements every shell or Git glob rule; in particular, `**/` is not specially allowed to match nothing including the slash.

Taking `009-smartcity-project` as an example:

- `smartcity`: plain contains match, found.
- `*smartcity`: the name must end with “smartcity”, so a name ending in “project” is not found.
- `*smartcity*`: other text allowed on both sides, found.
- `smartcity kind:folder`: only folders whose names contain the word; usually the most direct.

`[0-9]` is not a character class in wildcards; use `regex:` for digit patterns.

## 11. `regex:`: regular expressions

### 11.1 Syntax and what is matched

```text
regex:expression
```

Don't wrap it in `/…/`, and don't put the whole regex in double quotes. Whitespace ends the regex token, so write spaces in the pattern as `\s`, `\s+` or `\x20`.

| Mode | Matched against |
| --- | --- |
| Name search, expression without `/` | The file or folder name, including the extension |
| Name search, expression with `/` | The full path |
| Content search | The extracted text, as processed by the current match mode |

A regex matches if it is found anywhere. For a whole-name match add `^` and `$`. In Content search the anchors refer to the whole extracted text, not each line; use `(?m)` for line-by-line matching. Loose mode may fold line breaks into spaces; if you need the original lines, choose Exact, and remember that for PDFs and similar formats the “original” is still the extracted text.

The regex token runs until whitespace; `|` and parentheses inside it belong to the regex. To combine it with the outer query, separate with spaces:

```text
regex:HT-[0-9]{4} -draft
(regex:HT-[0-9]{4} | contract)
```

In the second line, the space before the outer closing parenthesis keeps it out of the regex token.

### 11.2 Quick reference

| Symbol | Meaning | Example |
| --- | --- | --- |
| `.` | Usually any one character except a line break | `report.` |
| `.*` | Any number of such characters | `contract.*final` |
| `.+` | At least one such character | `report.+` |
| `?` | The previous item zero or one time | `report-?2026` |
| `[0-9]` | One ASCII digit | `[0-9]{4}` |
| `[A-Za-z]` | One ASCII letter | `[A-Za-z]+` |
| `\d` | One Unicode digit, wider than 0–9 | `\d+` |
| `\s` | One whitespace character | `contract\s+amount` |
| `\S` | One non-whitespace character | `ref\S+` |
| `{n}` | The previous item exactly n times | `[0-9]{4}` |
| `{n,m}` | The previous item n to m times | `[0-9]{2,4}` |
| `^`, `$` | Start / end | `^report.*\.pdf$` |
| `\.` | A literal period | `\.docx$` |
| `(a\|b)` | Alternatives inside the regex | `(contract\|agreement)` |
| `(?:…)` | Non-capturing group | `\.(?:pdf\|docx)$` |

### 11.3 Name regexes to copy

```text
regex:^009-.*
regex:^009-smartcity-project$ kind:folder
regex:^report[0-9]{4}\.pdf$
regex:(contract|agreement).*\.(pdf|docx)$
regex:rollout.*\.pdf$
regex:/contracts/[^/]*\.pdf$
```

In order: names starting with 009-; exactly that folder name; “report” plus four digits as a PDF; names containing “contract” or “agreement” with the given extensions; PDFs whose names contain “rollout”; PDFs directly inside a “contracts” folder.

### 11.4 Content regexes to copy

```text
in regex:HT-[0-9]{4}-[0-9]+ ext:pdf;docx
in regex:Contract\sNo\.?\s*[:：]?\s*[A-Za-z0-9-]+ ext:pdf;docx
in regex:[0-9]{4}-[0-9]{2}-[0-9]{2} dir:~/Documents
in regex:\+?1?[0-9]{10} ext:txt
in regex:Amount[:：]?\s*[0-9,]+(?:\.[0-9]{1,2})? ext:pdf
```

These match the shape of text: the date example doesn't check that the date exists, and the phone example doesn't check that the number is real.

If a content regex has no fixed text that can recall candidates, and no `dir:` or `ext:`, the app may refuse to scan the whole index and say:

```text
A regex needs at least 3 bytes of fixed text, or dir: / ext: to narrow it down
```

Adding a folder or extension is the safest fix. It is **3 UTF-8 bytes, not 3 characters**; whether candidates can be recalled in advance also depends on whether the whole expression yields a safe candidate condition. `size:` or `dm:` alone can't replace the folder/extension requirement.

### 11.5 How the two modes differ

- Name regexes use `NSRegularExpression` on the case-folded name key; switching the content match setting doesn't restore a name's original case.
- Content regexes use Rust `regex`. It has no look-around or backreferences, so `(?<=contract)` or `(word)\1` won't work as content queries. See the [Rust regex syntax](https://docs.rs/regex/1.13.1/regex/#syntax).
- Content regexes run against the text as processed by the current mode; the regex itself is not normalized the way plain keywords are. For full-width characters or exact line structure, prefer Exact and write against the actual extracted text.
- Regexes are for finding and locating only; there is no replace or batch rename.

## 12. Content proximity: `"a b"~N`

```text
in "contract amount"~10
in "rollout report"~20 ext:pdf
```

All the words appear within one local window, in any order, and the window holds at most N characters besides the keywords. Characters are counted after the current match mode's processing; it is not a count of words, pages or bytes, and the window may cross paragraphs.

For example, in “contract total amount”, the characters between “contract” and “amount” are “ total ” (7 characters, spaces included): `"contract amount"~7` matches, `~6` doesn't. With three or more keywords, N limits the window covering all of them, not each pair of neighbors.

Give at least two words separated by whitespace, and put `~` and a non-negative integer right after the closing quote; `~0` allows no extra characters. Name search has no proximity queries.

## 13. Combining filters

```text
(rollout | acceptance) ext:pdf;docx dir:~/Documents dm:thismonth size:<20m
```

Names containing “rollout” or “acceptance”; PDF or DOCX; inside Documents; modified this month; smaller than 20 MiB.

```text
in (rollout | acceptance) -void ext:pdf;docx dir:~/Documents dm:thismonth
```

The text must contain “rollout” or “acceptance” and not “void”; the other conditions filter file metadata.

Rules:

- Filters of different kinds must all hold (AND).
- Several `dir:` terms form a union; so do several extensions or kinds.
- Several `size:` or `dm:` terms intersect; so do several `name:` terms, while the values inside one `name:` form a union.
- Filters are taken out of the expression and apply globally; **each OR branch does not get its own filters**.
- `-dir:…`, `-ext:…`, `-kind:…` and `-name:…` are not negative filters; don't use them to exclude folders, extensions or names.

So this does not mean “a in Documents, or b in Downloads”:

```text
(a dir:~/Documents) | (b dir:~/Downloads)
```

Its folder conditions merge into a global union: in effect, a or b in either folder. When branches need different scopes, run two queries.

Content search needs a text expression. `in ext:pdf dir:~/Documents` alone doesn't list every PDF; to find files by attributes only, switch back to Name search.

## 14. Recipes

| To do this | Type |
| --- | --- |
| Find the smartcity project folder | `smartcity kind:folder` |
| Find folders with other text around that name | `*smartcity* kind:folder` |
| Find rollout PDFs by name in the project | `rollout ext:pdf dir:"/Users/me/Documents/Work Files/Clients/009-smartcity-project"` |
| Find “rollout” in the project's document text | `in rollout dir:"/Users/me/Documents/Work Files/Clients/009-smartcity-project"` |
| Word and PDF files whose text contains “rollout” | `in rollout ext:doc;docx;pdf` |
| Name contains “invoice”, text contains “payment” | `in payment name:invoice` |
| Word documents named “contract”, without “draft” | `contract -draft kind:word` |
| PDFs modified in the last 7 days | `ext:pdf dm:7d` |
| Files larger than 50 MiB | `size:>50m` |
| Empty files | `size:empty` |
| Folders modified today | `kind:folder dm:today` |
| Text where “contract” and “amount” are close | `in "contract amount"~10 ext:pdf;docx` |
| Text shaped like a contract number | `in regex:HT-[0-9]{4}-[0-9]+ ext:pdf;docx` |

## 15. Interface actions related to search

Mostly in the launcher; shortcuts use macOS symbols: `⌘` Command, `⌥` Option, `⇧` Shift.

| Action | Use |
| --- | --- |
| `⌘1` / `⌘2` | Switch to Name / Content search; the Full Window supports them too |
| `⌘/` | Syntax summary in the launcher |
| `↓` / `↑` | Move through the results; above the first name result, back to the field |
| `Tab` in the field with a folder selected | In Name search, the folder becomes a scope token, and the search continues inside it |
| `Tab` in the field with an app selected | In Name search, filters by the document types the app declares it can open; it doesn't search the app's own data |
| Delete in an empty field | The launcher removes the scope token first; without one, in Content search, it removes the “Content” token and returns to Name search |
| `Return` | Open the selected result |
| `⌘Return` in Name search | Reveal the selected item in Finder |
| `⌘Return` in Content search | Open the Reader at the current hit |
| `Space` with the name result list focused | Opens system Quick Look; a space typed in the field stays text |
| `⌘G` / `⌘⇧G` in Content search | Next / previous hit in the content preview |
| `⌘E` in the launcher | Go to the Full Window |
| `⌘,` in the launcher | Open Settings |

Tab on a folder works like `dir:`. Tab on an app depends on the document types the app declares and is not a `kind:` category. The Full Window may add sidebar folder, type and date conditions on top; check those as well when results look wrong.

## 16. When nothing is found

1. Check the mode: Name search for file names, Content search for text.
2. Reduce the query to one distinctive word, to see whether multiple words, exclusions, dates or types filtered the results out.
3. Look at the syntax switches and any “not recognized” notice. An invalid name regex, kind or metadata filter may not limit anything; results still showing doesn't mean the filter worked.
4. In Content search, replace `kind:` with `ext:`, use full paths with `dir:`, and put alternative names in one `name:` separated by semicolons.
5. Folder name segments must match whole folder names; quote paths with spaces.
6. With wildcards, remember they match the whole term; check whether the name has extra text such as “project” at the end.
7. Check the name scope, the content scope, exclusion rules, file access permissions, and whether the format has been extracted. Being findable by name doesn't make a file searchable by text.
8. For Content search, check the match mode. Loose ignores case, compatibility character differences and whitespace; Exact compares the extracted text character by character, not the visual layout or the binary PDF/Office file.
9. Images and scanned PDFs depend on the actual OCR extraction state; text that failed, isn't done yet, or was misrecognized can't appear in the index.
10. The launcher limits how many name results it shows. For many results with the same word, narrow with `kind:`, `dir:` or `ext:`, or go to the Full Window; “not in the first few” is not the same as “not matching”.

There is no `path:`, `type:`, `created:`, `before:`, `after:` or `case:` syntax, no `find` prefix, and no SQL-style AND/OR keywords; `name:` is for Content search only. For path conditions use `dir:` or path wildcards / path regexes; for dates use `dm:`; for content case rules, switch the match mode in Settings or the Full Window.

## 17. Sources checked (for maintainers)

This guide follows these implementations:

- `App/Sources/LauncherPanel.swift`: the `in ` prefix, mode switching, syntax summary, scope tokens and shortcuts.
- `App/Sources/FullWindow.swift`: Full Window modes, sidebar filters and shortcuts; no automatic `in ` switch.
- `App/Sources/Settings.swift`, `Preferences.swift`: syntax switches and content match modes.
- `Packages/XSearchCore/Sources/NameQuery.swift`, `ContentQuery.swift`: filters and token parsing in both modes, including `name:` in Content search.
- `Packages/XSearchCore/Sources/QuerySyntax.swift`: wildcards, size and date bounds, syntax defaults.
- `Packages/XSearchCore/Sources/FileKind.swift`, `NameKey.swift`: kind aliases, extension groups and name keys.
- `Packages/NameEngine/Sources/NameView.swift`: folder segment parsing, filter combination, wildcard/regex matching.
- `Packages/Catalog/Sources/AppCatalog.swift`: what the separate app launch results cover.
- `rust/xs-core/src/query.rs`, `normalize.rs`: content Boolean syntax, regexes, proximity and normalization.
- `rust/xs-ffi/src/lib.rs`, `rust/xs-index/src/reader.rs`: the content regex scope requirement, global filters and the `name:` condition.
- `Packages/XSearchCore/Tests/XSearchCoreTests.swift`, `Packages/NameEngine/Tests/NameEngineTests.swift`, `rust/xs-index/tests/engine.rs`: existing behavior examples and edge-case tests.

Paths are relative to the repository root. When the syntax or parsers change, update this guide and its [Chinese version](SEARCH-GUIDE.md), especially the `size:` unit rule, the global scope of filters, the folder rules of both modes and the regex differences.

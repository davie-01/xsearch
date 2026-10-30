//! M4 web formats: HTML (tags, scripts and styles removed; one anchor per paragraph) and ePub
//! (spine order, one anchor per chapter, chapter text as HTML).
use crate::{
    Extraction, Limits, decode_text,
    office::{AnyZip, Out, join, open_zip, zip_text},
};
use anyhow::{Context, Result, bail};
use std::{collections::HashMap, fs::File, io::Read, path::Path};
use xs_index::AnchorKind;

pub const HTML_EXTRACTOR_VERSION: u64 = 1;
pub const EPUB_EXTRACTOR_VERSION: u64 = 1;

/// Elements whose content is never text.
const SKIPPED: [&str; 7] = ["script", "style", "noscript", "template", "svg", "math", "object"];
/// Elements that start a new paragraph.
const BLOCKS: [&str; 34] = [
    "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "table", "section", "article", "header", "footer",
    "blockquote", "pre", "ul", "ol", "dl", "dt", "dd", "hr", "title", "nav", "aside", "main", "figure", "figcaption",
    "form", "address", "caption", "body",
];

/// Streams HTML into `out`: tolerant of broken markup (unclosed tags, stray `<`), entities
/// decoded, whitespace collapsed outside `<pre>`, a paragraph anchor per non-empty block.
pub(crate) fn html_into(src: &str, out: &mut Out, para: &mut u32) {
    let bytes = src.as_bytes();
    let mut i = 0;
    let mut line = String::new();
    let mut pre = 0usize;
    let flush = |line: &mut String, out: &mut Out, para: &mut u32| {
        let t = line.trim();
        if !t.is_empty() {
            *para += 1;
            out.anchor(AnchorKind::Paragraph { index: *para });
            out.push(t);
            out.push("\n");
        }
        line.clear();
    };
    while i < bytes.len() {
        if out.partial {
            return;
        }
        if bytes[i] == b'<' {
            let rest = &src[i..];
            if rest.starts_with("<!--") {
                i += rest.find("-->").map_or(rest.len(), |e| e + 3);
                continue;
            }
            if let Some(cdata) = rest.strip_prefix("<![CDATA[") {
                let end = cdata.find("]]>").unwrap_or(cdata.len());
                line.push_str(&cdata[..end]);
                i += 9 + end + 3.min(cdata.len() - end);
                continue;
            }
            // A real tag starts with a letter, `/` or `!`; anything else is a literal `<`.
            let next = bytes.get(i + 1).copied().unwrap_or(b' ');
            if !(next.is_ascii_alphabetic() || next == b'/' || next == b'!' || next == b'?') {
                line.push('<');
                i += 1;
                continue;
            }
            let end = tag_end(bytes, i + 1);
            let tag = &src[i + 1..end.min(src.len())];
            i = (end + 1).min(bytes.len());
            let closing = tag.starts_with('/');
            let name: String = tag
                .trim_start_matches(['/', '!', '?'])
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric())
                .collect::<String>()
                .to_ascii_lowercase();
            if !closing && SKIPPED.contains(&name.as_str()) && !tag.ends_with('/') {
                // Skip to the matching close tag (case-insensitive).
                let close = format!("</{name}");
                let lower = src[i..].to_ascii_lowercase();
                i += lower.find(&close).map_or(src.len() - i, |p| {
                    p + lower[p..].find('>').map_or(lower.len() - p, |q| q + 1)
                });
                continue;
            }
            if name == "pre" {
                pre = if closing { pre.saturating_sub(1) } else { pre + 1 };
            }
            if name == "td" || name == "th" {
                if !closing && !line.trim().is_empty() {
                    line.push('\t');
                }
            } else if BLOCKS.contains(&name.as_str()) {
                flush(&mut line, out, para);
            }
            continue;
        }
        if bytes[i] == b'&' {
            let (decoded, used) = entity(&src[i..]);
            line.push_str(&decoded);
            i += used;
            continue;
        }
        let ch = src[i..].chars().next().unwrap_or(' ');
        i += ch.len_utf8();
        if ch.is_whitespace() {
            if pre > 0 && ch == '\n' {
                flush(&mut line, out, para);
            } else if !line.ends_with(' ') && !line.is_empty() {
                line.push(' ');
            }
        } else {
            line.push(ch);
        }
    }
    flush(&mut line, out, para);
}

/// Index of the `>` closing a tag that starts at `from`, skipping quoted attribute values.
fn tag_end(bytes: &[u8], from: usize) -> usize {
    let mut quote = 0u8;
    for (k, &b) in bytes.iter().enumerate().skip(from) {
        match (quote, b) {
            (0, b'"') | (0, b'\'') => quote = b,
            (q, _) if q != 0 && b == q => quote = 0,
            (0, b'>') => return k,
            _ => {}
        }
    }
    bytes.len()
}

/// Decodes one entity at the start of `s`; returns the text and the bytes consumed. Unknown or
/// malformed entities stay literal.
fn entity(s: &str) -> (String, usize) {
    // Byte search: a fixed-length str slice could end inside a multi-byte character.
    let Some(semi) = s.as_bytes().iter().take(12).position(|&b| b == b';') else { return ("&".into(), 1) };
    let body = &s[1..semi];
    let c = if let Some(num) = body.strip_prefix('#') {
        let v = if let Some(hex) = num.strip_prefix(['x', 'X']) { u32::from_str_radix(hex, 16).ok() } else { num.parse().ok() };
        v.and_then(char::from_u32)
    } else {
        match body {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" | "ensp" | "emsp" | "thinsp" => Some(' '),
            "copy" => Some('©'),
            "reg" => Some('®'),
            "trade" => Some('™'),
            "mdash" => Some('—'),
            "ndash" => Some('–'),
            "hellip" => Some('…'),
            "ldquo" => Some('“'),
            "rdquo" => Some('”'),
            "lsquo" => Some('‘'),
            "rsquo" => Some('’'),
            "middot" => Some('·'),
            "times" => Some('×'),
            "yen" => Some('¥'),
            "euro" => Some('€'),
            "deg" => Some('°'),
            _ => None,
        }
    };
    match c {
        Some(c) => (c.to_string(), semi + 1),
        None => ("&".into(), 1),
    }
}

/// `<meta charset>` / `http-equiv` declared in the first 2 KB, if any.
fn declared_charset(head: &[u8]) -> Option<&'static encoding_rs::Encoding> {
    let s = String::from_utf8_lossy(&head[..head.len().min(2048)]).to_ascii_lowercase();
    let at = s.find("charset=")? + 8;
    let name: String = s[at..].trim_start_matches(['"', '\'']).chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').collect();
    encoding_rs::Encoding::for_label(name.as_bytes())
}

fn decode_html(bytes: &[u8]) -> Result<(String, String)> {
    if let Some(enc) = declared_charset(bytes)
        && enc != encoding_rs::UTF_8
    {
        let (text, _, _) = enc.decode(bytes);
        return Ok((text.into_owned(), format!("html/{}", enc.name().to_ascii_lowercase())));
    }
    let e = decode_text(bytes, false)?;
    Ok((e.text, e.method.replace("text/", "html/")))
}

pub fn html(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut bytes = vec![];
    File::open(path)?.take(limits.max_file_bytes.max(1)).read_to_end(&mut bytes)?;
    let (src, method) = decode_html(&bytes)?;
    let mut out = Out::new(limits);
    let mut para = 0;
    html_into(&src, &mut out, &mut para);
    Ok(out.done(&method))
}

/// An ePub is a zip, or (Apple Books) a folder with the same layout.
enum Package {
    Zip(AnyZip),
    Dir(std::path::PathBuf),
}

impl Package {
    fn open(path: &Path, limits: Limits) -> Result<Self> {
        Ok(if path.is_dir() { Self::Dir(path.to_owned()) } else { Self::Zip(open_zip(path, limits)?) })
    }

    fn read(&mut self, name: &str, limits: Limits, used: &mut u64) -> Result<String> {
        match self {
            Self::Zip(z) => zip_text(z, name, limits, used),
            Self::Dir(root) => {
                let p = root.join(name);
                // Stay inside the package.
                if name.split('/').any(|c| c == "..") {
                    bail!("path outside package");
                }
                *used += std::fs::metadata(&p)?.len();
                if *used > limits.max_unpacked_bytes {
                    bail!("uncompressed size limit");
                }
                Ok(String::from_utf8_lossy(&std::fs::read(p)?).into_owned())
            }
        }
    }
}

/// Attributes of every `<name …>` (any namespace prefix). Lenient on purpose: real OPF files
/// use undeclared prefixes and HTML entities that a strict XML parser rejects.
fn tags(xml: &str, name: &str) -> Vec<HashMap<String, String>> {
    let bytes = xml.as_bytes();
    let mut out = vec![];
    let mut from = 0;
    while let Some(p) = xml[from..].find('<') {
        let start = from + p + 1;
        let end = tag_end(bytes, start);
        let tag = &xml[start..end.min(xml.len())];
        from = (end + 1).min(xml.len());
        let tag_name = tag.split(|c: char| c.is_whitespace() || c == '/' || c == '>').next().unwrap_or("");
        if tag_name.rsplit(':').next() != Some(name) {
            continue;
        }
        let mut attrs = HashMap::new();
        let mut rest = &tag[tag_name.len()..];
        while let Some(eq) = rest.find('=') {
            let key = rest[..eq].trim().rsplit(':').next().unwrap_or("").to_owned();
            let after = rest[eq + 1..].trim_start();
            let Some(q) = after.chars().next().filter(|c| *c == '"' || *c == '\'') else { break };
            let Some(close) = after[1..].find(q) else { break };
            attrs.insert(key, after[1..1 + close].to_owned());
            rest = &after[close + 2..];
        }
        out.push(attrs);
    }
    out
}

/// ePub: META-INF/container.xml → OPF → spine order → XHTML chapters. Each chapter starts with
/// a part anchor named after its first heading (or "第 n 章").
pub fn epub(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut pkg = Package::open(path, limits).context("not an ePub package")?;
    let mut used = 0;
    let Ok(container) = pkg.read("META-INF/container.xml", limits, &mut used) else {
        return loose_text_package(pkg, limits);
    };
    let opf_path = tags(&container, "rootfile").into_iter().find_map(|a| a.get("full-path").cloned()).context("missing rootfile")?;
    let opf_dir = opf_path.rsplit_once('/').map(|(d, _)| d.to_owned()).unwrap_or_default();
    let opf = pkg.read(&opf_path, limits, &mut used)?;
    let manifest: HashMap<String, String> = tags(&opf, "item")
        .into_iter()
        .filter_map(|mut a| Some((a.remove("id")?, a.remove("href")?)))
        .collect();
    let spine: Vec<String> = tags(&opf, "itemref")
        .iter()
        .filter_map(|a| manifest.get(a.get("idref")?))
        .map(|href| join(&opf_dir, &percent_decode(href.split('#').next().unwrap_or(href))))
        .collect();
    if spine.is_empty() {
        bail!("empty spine");
    }
    let mut out = Out::new(limits);
    let mut para = 0;
    for (n, item) in spine.iter().enumerate() {
        let Ok(xhtml) = pkg.read(item, limits, &mut used) else {
            out.partial = true;
            out.warnings.push(format!("第 {} 章无法读取", n + 1));
            continue;
        };
        let title = first_heading(&xhtml).unwrap_or_else(|| format!("第 {} 章", n + 1));
        out.anchor(AnchorKind::Part { name: title });
        html_into(&xhtml, &mut out, &mut para);
        if out.partial {
            break;
        }
    }
    Ok(out.done("epub"))
}

/// Some apps export books as a zip of plain-text chapters with an .epub name: no container,
/// no OPF. Read the text and HTML entries in name order, one part anchor per entry.
fn loose_text_package(pkg: Package, limits: Limits) -> Result<Extraction> {
    let Package::Zip(mut zip) = pkg else { bail!("missing container.xml") };
    let mut names: Vec<String> = zip
        .file_names()
        .filter(|n| {
            let l = n.to_ascii_lowercase();
            l.ends_with(".txt") || l.ends_with(".html") || l.ends_with(".xhtml") || l.ends_with(".htm")
        })
        .map(str::to_owned)
        .collect();
    if names.is_empty() {
        bail!("missing container.xml");
    }
    names.sort_by_key(|n| natural(n));
    let mut out = Out::new(limits);
    let mut used = 0u64;
    let mut para = 0;
    for name in &names {
        let mut f = zip.by_name(name)?;
        used += f.size();
        if used > limits.max_unpacked_bytes {
            out.partial = true;
            out.warnings.push("内容超过上限，后续部分未索引".into());
            break;
        }
        let mut bytes = vec![];
        f.read_to_end(&mut bytes)?;
        let stem = name.rsplit('/').next().unwrap_or(name).rsplit_once('.').map_or(name.as_str(), |(s, _)| s);
        out.anchor(AnchorKind::Part { name: stem.chars().take(24).collect() });
        if name.to_ascii_lowercase().ends_with(".txt") {
            for line in decode_text(&bytes, false)?.text.lines().filter(|l| !l.trim().is_empty()) {
                out.push(line.trim());
                out.push("\n");
            }
        } else {
            html_into(&String::from_utf8_lossy(&bytes), &mut out, &mut para);
        }
        if out.partial {
            break;
        }
    }
    Ok(out.done("epub/loose"))
}

/// Sort key that orders "2.txt" before "10.txt".
fn natural(s: &str) -> Vec<(String, u64)> {
    let mut out = vec![];
    let mut text = String::new();
    let mut num = String::new();
    for c in s.chars() {
        if c.is_ascii_digit() {
            num.push(c);
        } else {
            if !num.is_empty() {
                out.push((std::mem::take(&mut text), num.parse().unwrap_or(u64::MAX)));
                num.clear();
            }
            text.push(c);
        }
    }
    out.push((text, num.parse().unwrap_or(0)));
    out
}

/// Text of the first `<h1>`–`<h3>`, shortened for the gutter.
fn first_heading(xhtml: &str) -> Option<String> {
    let lower = xhtml.to_ascii_lowercase();
    let start = ["<h1", "<h2", "<h3"].iter().filter_map(|t| lower.find(t)).min()?;
    let open_end = start + lower[start..].find('>')? + 1;
    let close = open_end + lower[open_end..].find("</h")?;
    let mut out = Out::new(Limits::default());
    let mut para = 0;
    html_into(&xhtml[open_end..close], &mut out, &mut para);
    let t = out.text.split_whitespace().collect::<Vec<_>>().join(" ");
    (!t.is_empty()).then(|| t.chars().take(24).collect())
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%'
            && i + 2 < b.len()
            && let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16)
        {
            out.push(v);
            i += 3;
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

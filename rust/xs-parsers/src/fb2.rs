//! FictionBook 2 (.fb2): one XML file, often in windows-1251 or another legacy encoding
//! declared in the XML header. The book's title, authors, annotation and keywords, then the
//! bodies: the main text, then notes and comments. Embedded images (`<binary>`, base64) are
//! dropped before parsing. Malformed files are read leniently, like HTML.
//! Anchors: "简介" for the description, one part per top-level section named after its title
//! (or "第 n 章"), "注释" for the notes bodies; a paragraph anchor per paragraph or verse line.
use crate::office::Out;
use crate::{Extraction, Limits};
use anyhow::{Result, bail};
use roxmltree::{Document, Node, ParsingOptions};
use std::{fs::File, io::Read, path::Path};
use xs_index::AnchorKind;

pub const FB2_EXTRACTOR_VERSION: u64 = 1;

pub fn fb2(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut bytes = vec![];
    File::open(path)?.take(limits.max_file_bytes.max(1)).read_to_end(&mut bytes)?;
    let xml = without_binaries(&decode(&bytes));
    let mut out = Out::new(limits);
    let mut para = 0;
    let Ok(doc) = Document::parse_with_options(&xml, ParsingOptions { allow_dtd: true, ..Default::default() }) else {
        if !xml.contains("FictionBook") {
            bail!("not a FictionBook file");
        }
        crate::web::html_into(&xml, &mut out, &mut para);
        return Ok(out.done("fb2/lenient"));
    };
    let book = doc.root_element();
    if !is(&book, "FictionBook") {
        bail!("not a FictionBook file");
    }
    if let Some(info) = child(book, "description").and_then(|d| child(d, "title-info")) {
        out.anchor(AnchorKind::Part { name: "简介".into() });
        line(&mut out, &text(child(info, "book-title")));
        let authors: Vec<_> = info.children().filter(|c| is(c, "author")).map(author).filter(|a| !a.is_empty()).collect();
        line(&mut out, &authors.join("、"));
        if let Some(a) = child(info, "annotation") {
            walk(a, &mut out, &mut para);
        }
        line(&mut out, &text(child(info, "keywords")));
    }
    let mut chapter = 0;
    for body in book.children().filter(|c| is(c, "body")) {
        if body.attribute("name").is_some_and(|n| n == "notes" || n == "comments") {
            out.anchor(AnchorKind::Part { name: "注释".into() });
            walk(body, &mut out, &mut para);
            continue;
        }
        for c in body.children().filter(Node::is_element) {
            if is(&c, "section") {
                chapter += 1;
                // A title is one or more paragraphs ("第一章" / "出发").
                let title = child(c, "title").map_or(String::new(), |t| t.children().filter(|p| is(p, "p")).map(|p| text(Some(p))).collect::<Vec<_>>().join(" "));
                let name = if title.is_empty() { format!("第 {chapter} 章") } else { title.chars().take(24).collect() };
                out.anchor(AnchorKind::Part { name });
            }
            walk(c, &mut out, &mut para);
        }
        if out.partial {
            break;
        }
    }
    if out.text.is_empty() {
        bail!("no text");
    }
    Ok(out.done("fb2"))
}

/// The encoding from a byte order mark or the XML declaration; UTF-8 when neither says.
fn decode(bytes: &[u8]) -> String {
    if let Some((enc, skip)) = encoding_rs::Encoding::for_bom(bytes) {
        return enc.decode_without_bom_handling(&bytes[skip..]).0.into_owned();
    }
    let head = String::from_utf8_lossy(&bytes[..bytes.len().min(200)]).to_ascii_lowercase();
    let declared = head.split("?>").next().and_then(|decl| {
        let at = decl.find("encoding=")? + 9;
        let name: String = decl[at..].trim_start_matches(['"', '\'']).chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').collect();
        encoding_rs::Encoding::for_label(name.as_bytes())
    });
    declared.unwrap_or(encoding_rs::UTF_8).decode_without_bom_handling(bytes).0.into_owned()
}

/// Removes `<binary …>…</binary>` (base64 images, often most of the file).
fn without_binaries(xml: &str) -> String {
    let mut out = String::with_capacity(xml.len());
    let mut rest = xml;
    while let Some(start) = rest.find("<binary") {
        out.push_str(&rest[..start]);
        rest = rest[start..].find("</binary>").map_or("", |end| &rest[start + end + 9..]);
    }
    out.push_str(rest);
    out
}

/// Elements by local name (FictionBook files use a default namespace, some none).
fn is(n: &Node, name: &str) -> bool {
    n.is_element() && n.tag_name().name() == name
}

fn child<'a, 'i>(n: Node<'a, 'i>, name: &str) -> Option<Node<'a, 'i>> {
    n.children().find(|c| is(c, name))
}

/// All the text inside, whitespace collapsed.
fn text(n: Option<Node>) -> String {
    let Some(n) = n else { return String::new() };
    // Inline markup (emphasis, strong, links) joins its text without a space.
    let s: String = n.descendants().filter(|d| d.is_text()).filter_map(|d| d.text()).collect();
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn author(a: Node) -> String {
    let parts: Vec<_> = ["first-name", "middle-name", "last-name"].iter().map(|f| text(child(a, f))).filter(|s| !s.is_empty()).collect();
    if parts.is_empty() { text(child(a, "nickname")) } else { parts.join(" ") }
}

fn line(out: &mut Out, s: &str) {
    if !s.is_empty() {
        out.push(s);
        out.push("\n");
    }
}

/// Paragraph-like elements become one line each; containers (section, poem, stanza, cite,
/// epigraph, title, table rows) are walked through.
fn walk(n: Node, out: &mut Out, para: &mut u32) {
    for c in n.children().filter(Node::is_element) {
        if out.partial {
            return;
        }
        match c.tag_name().name() {
            "image" | "binary" => {}
            "p" | "v" | "subtitle" | "text-author" | "th" | "td" | "date" => {
                let t = text(Some(c));
                if !t.is_empty() {
                    *para += 1;
                    out.anchor(AnchorKind::Paragraph { index: *para });
                    line(out, &t);
                }
            }
            _ => walk(c, out, para),
        }
    }
}

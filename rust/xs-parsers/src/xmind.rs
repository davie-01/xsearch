//! XMind mind maps (.xmind, a zip package). XMind 2020 and later write `content.json` (and a
//! `content.xml` that only tells old versions to upgrade); XMind 8 and earlier write
//! `content.xml` alone. Each sheet: its title, then the topics depth first, one per line
//! (attached, floating and summary topics), each topic's labels and notes after it, then
//! boundary and relationship titles. Markers, images, links and styles are left out.
//! Anchors: one part per sheet, named after the sheet.
use crate::office::{Out, zip_text};
use crate::{Extraction, Limits};
use anyhow::{Result, bail};
use roxmltree::{Document, Node};
use serde_json::Value;
use std::{fs::File, path::Path};
use xs_index::AnchorKind;

pub const XMIND_EXTRACTOR_VERSION: u64 = 1;

pub fn xmind(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut zip = zip::ZipArchive::new(File::open(path)?)?;
    if zip.len() > 10_000 {
        bail!("archive entry limit");
    }
    let mut used = 0;
    if let Ok(manifest) = zip_text(&mut zip, "manifest.json", limits, &mut used)
        && manifest.contains("encryption-data")
    {
        bail!("encrypted mind map");
    }
    let mut out = Out::new(limits);
    if zip.index_for_name("content.json").is_some() {
        let json: Value = serde_json::from_str(&zip_text(&mut zip, "content.json", limits, &mut used)?)?;
        let Some(sheets) = json.as_array() else { bail!("content.json is not a list of sheets") };
        for (i, sheet) in sheets.iter().enumerate() {
            let root = &sheet["rootTopic"];
            begin_sheet(&mut out, i, str_of(&sheet["title"]), str_of(&root["title"]));
            json_topic(root, &mut out);
            titles(&mut out, sheet["relationships"].as_array().into_iter().flatten().map(|r| str_of(&r["title"])));
            if out.partial {
                break;
            }
        }
        return Ok(out.done("xmind"));
    }
    let xml = zip_text(&mut zip, "content.xml", limits, &mut used)?;
    let doc = Document::parse(&xml)?;
    let sheets: Vec<_> = doc.root_element().children().filter(|n| is(n, "sheet")).collect();
    if sheets.is_empty() {
        bail!("no sheets");
    }
    for (i, sheet) in sheets.into_iter().enumerate() {
        let root = sheet.children().find(|n| is(n, "topic"));
        begin_sheet(&mut out, i, child_text(sheet, "title"), root.map(|r| child_text(r, "title")).unwrap_or_default());
        if let Some(root) = root {
            xml_topic(root, &mut out);
        }
        let relationships = sheet.children().filter(|n| is(n, "relationships")).flat_map(|r| r.children().filter(|n| is(n, "relationship")));
        titles(&mut out, relationships.map(|r| child_text(r, "title")));
        if out.partial {
            break;
        }
    }
    Ok(out.done("xmind"))
}

/// The sheet's part anchor, and its title as text unless it only repeats the central topic.
fn begin_sheet(out: &mut Out, index: usize, title: &str, root: &str) {
    let title = title.trim();
    let name = if title.is_empty() { format!("画布 {}", index + 1) } else { title.chars().take(24).collect() };
    out.anchor(AnchorKind::Part { name });
    if !title.is_empty() && title != root.trim() {
        line(out, title);
    }
}

fn line(out: &mut Out, s: &str) {
    // Titles can hold line breaks of their own; keep one topic per line.
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if !s.is_empty() {
        out.push(&s);
        out.push("\n");
    }
}

fn titles<'a>(out: &mut Out, titles: impl Iterator<Item = &'a str>) {
    for t in titles {
        line(out, t);
    }
}

/// Notes keep their own lines (they are free text, often several paragraphs).
fn notes(out: &mut Out, text: &str) {
    for l in text.lines() {
        line(out, l);
    }
}

fn str_of(v: &Value) -> &str {
    v.as_str().unwrap_or("")
}

fn json_topic(topic: &Value, out: &mut Out) {
    if out.partial {
        return;
    }
    line(out, str_of(&topic["title"]));
    let labels: Vec<_> = topic["labels"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    line(out, &labels.join(" "));
    let n = &topic["notes"];
    if let Some(plain) = n["plain"]["content"].as_str() {
        notes(out, plain);
    } else if let Some(html) = n["realHTML"]["content"].as_str().or(n["html"]["content"].as_str()) {
        let mut text = Out::new(Limits::default());
        crate::web::html_into(html, &mut text, &mut 0);
        notes(out, &text.text);
    }
    let children = &topic["children"];
    for kind in ["attached", "detached", "summary"] {
        for child in children[kind].as_array().into_iter().flatten() {
            json_topic(child, out);
        }
    }
    titles(out, topic["boundaries"].as_array().into_iter().flatten().map(|b| str_of(&b["title"])));
}

/// XML elements by local name (XMind 8 uses one namespace throughout; older files none).
fn is(n: &Node, name: &str) -> bool {
    n.is_element() && n.tag_name().name() == name
}

fn child_text<'a>(n: Node<'a, '_>, name: &str) -> &'a str {
    n.children().find(|c| is(c, name)).and_then(|c| c.text()).unwrap_or("")
}

fn xml_topic(topic: Node, out: &mut Out) {
    if out.partial {
        return;
    }
    line(out, child_text(topic, "title"));
    if let Some(labels) = topic.children().find(|c| is(c, "labels")) {
        let labels: Vec<_> = labels.children().filter(|c| is(c, "label")).filter_map(|c| c.text()).collect();
        line(out, &labels.join(" "));
    }
    if let Some(n) = topic.children().find(|c| is(c, "notes")) {
        if let Some(plain) = n.children().find(|c| is(c, "plain")) {
            notes(out, &plain.descendants().filter(|d| d.is_text()).filter_map(|d| d.text()).collect::<String>());
        } else if let Some(html) = n.children().find(|c| is(c, "html")) {
            // xhtml:p paragraphs, each on its own line.
            for p in html.descendants().filter(|d| is(d, "p")) {
                line(out, &p.descendants().filter(|d| d.is_text()).filter_map(|d| d.text()).collect::<String>());
            }
        }
    }
    for topics in topic.children().filter(|c| is(c, "children")).flat_map(|c| c.children().filter(|t| is(t, "topics"))) {
        for child in topics.children().filter(|c| is(c, "topic")) {
            xml_topic(child, out);
        }
    }
    let boundaries = topic.children().filter(|c| is(c, "boundaries")).flat_map(|b| b.children().filter(|c| is(c, "boundary")));
    titles(out, boundaries.map(|b| child_text(b, "title")));
}

//! DOCX: body, headers, footers, footnotes and endnotes from the WordprocessingML parts.
//! Anchors: one per paragraph ("段 13"), table cells as "表 2·B3", and a part anchor where
//! headers / footers / notes begin.
use crate::{Extraction, Limits, paragraph_anchor};
use anyhow::{Result, bail};
use roxmltree::Node;
use std::{fs::File, io::Read, path::Path};
use xs_index::{Anchor, AnchorKind, ExtractState};

const NS: &str = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";

pub fn extract(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut zip = zip::ZipArchive::new(File::open(path)?)?;
    if zip.len() > 10_000 {
        bail!("archive entry limit");
    }
    let mut parts: Vec<String> = zip
        .file_names()
        .filter(|n| {
            *n == "word/document.xml"
                || n.starts_with("word/header")
                || n.starts_with("word/footer")
                || *n == "word/footnotes.xml"
                || *n == "word/endnotes.xml"
        })
        .map(str::to_owned)
        .collect();
    if !parts.iter().any(|n| n == "word/document.xml") {
        bail!("missing word/document.xml");
    }
    // Body, then headers, footers, footnotes, endnotes; numbered parts in name order.
    let rank = |n: &str| {
        [
            "word/document",
            "word/header",
            "word/footer",
            "word/footnotes",
            "word/endnotes",
        ]
        .iter()
        .position(|p| n.starts_with(p))
        .unwrap_or(5)
    };
    parts.sort_by_key(|n| (rank(n), n.clone()));
    let mut b = Builder::default();
    let mut unpacked = 0u64;
    for name in parts {
        let mut f = zip.by_name(&name)?;
        unpacked += f.size();
        if unpacked > limits.max_unpacked_bytes {
            b.warnings.push("解压后超过上限，后续部分未索引".into());
            b.partial = true;
            break;
        }
        let mut xml = String::new();
        Read::by_ref(&mut f)
            .take(limits.max_unpacked_bytes + 1)
            .read_to_string(&mut xml)?;
        let doc = roxmltree::Document::parse(&xml)?;
        if name != "word/document.xml" {
            b.anchors.push(Anchor {
                start: b.chars as u32,
                kind: AnchorKind::Part {
                    name: part_label(&name),
                },
            });
        }
        let mut tables = 0u32;
        walk(doc.root_element(), &mut b, &mut tables, None);
    }
    let state = if b.partial {
        ExtractState::Partial
    } else {
        ExtractState::Complete
    };
    Ok(Extraction {
        text: b.text,
        anchors: b.anchors,
        state,
        warnings: b.warnings,
        method: "docx".into(),
    })
}

#[derive(Default)]
struct Builder {
    text: String,
    chars: usize,
    anchors: Vec<Anchor>,
    paragraphs: u32,
    warnings: Vec<String>,
    partial: bool,
}

impl Builder {
    fn push(&mut self, s: &str) {
        self.text.push_str(s);
        self.chars += s.chars().count();
    }
}

fn part_label(name: &str) -> String {
    let base = name.trim_start_matches("word/").trim_end_matches(".xml");
    let kind = base.trim_end_matches(|c: char| c.is_ascii_digit());
    match kind {
        "header" => "页眉".into(),
        "footer" => "页脚".into(),
        "footnotes" => "脚注".into(),
        "endnotes" => "尾注".into(),
        _ => base.into(),
    }
}

/// Spreadsheet-style column letters: 0 → A, 25 → Z, 26 → AA.
fn column(mut i: usize) -> String {
    let mut s = String::new();
    loop {
        s.insert(0, (b'A' + (i % 26) as u8) as char);
        if i < 26 {
            return s;
        }
        i = i / 26 - 1;
    }
}

/// Depth-first over the part; `cell` is the enclosing table cell (table, label) if any.
fn walk(node: Node, b: &mut Builder, tables: &mut u32, cell: Option<(u32, String)>) {
    for child in node.children().filter(Node::is_element) {
        if child.has_tag_name((NS, "tbl")) {
            *tables += 1;
            let table = *tables;
            let rows = child.children().filter(|n| n.has_tag_name((NS, "tr")));
            for (r, row) in rows.enumerate() {
                let mut col = 0usize;
                for tc in row.children().filter(|n| n.has_tag_name((NS, "tc"))) {
                    let label = format!("{}{}", column(col), r + 1);
                    walk(tc, b, tables, Some((table, label)));
                    // Horizontally merged cells span several grid columns.
                    let span = tc
                        .descendants()
                        .find(|n| n.has_tag_name((NS, "gridSpan")))
                        .and_then(|n| n.attribute((NS, "val")))
                        .and_then(|v| v.parse::<usize>().ok())
                        .unwrap_or(1);
                    col += span.max(1);
                }
            }
        } else if child.has_tag_name((NS, "p")) {
            paragraph(child, b, cell.clone(), tables);
        } else {
            walk(child, b, tables, cell.clone());
        }
    }
}

fn paragraph(p: Node, b: &mut Builder, cell: Option<(u32, String)>, tables: &mut u32) {
    let start = b.chars;
    let mut text = String::new();
    let mut nested: Vec<Node> = vec![];
    collect(p, &mut text, &mut nested);
    if !text.is_empty() {
        b.paragraphs += 1;
        b.anchors.push(match &cell {
            Some((table, label)) => Anchor {
                start: start as u32,
                kind: AnchorKind::Cell {
                    table: *table,
                    cell: label.clone(),
                },
            },
            None => paragraph_anchor(start, b.paragraphs),
        });
        b.push(&text);
        b.push("\n");
    }
    // Text boxes inside the paragraph contribute their own paragraphs after it.
    for n in nested {
        walk(n, b, tables, cell.clone());
    }
}

/// Text owned by a paragraph: runs, tabs and breaks, not the paragraphs of nested text boxes.
fn collect<'a>(node: Node<'a, 'a>, out: &mut String, nested: &mut Vec<Node<'a, 'a>>) {
    for n in node.children().filter(Node::is_element) {
        if n.has_tag_name((NS, "txbxContent")) {
            nested.push(n);
        } else if n.has_tag_name((NS, "t")) {
            out.push_str(n.text().unwrap_or(""));
        } else if n.has_tag_name((NS, "tab")) {
            out.push('\t');
        } else if n.has_tag_name((NS, "br")) || n.has_tag_name((NS, "cr")) {
            out.push('\n');
        } else if n.has_tag_name((NS, "delText")) {
            // Deleted text in tracked changes is not part of the current document.
        } else {
            collect(n, out, nested);
        }
    }
}

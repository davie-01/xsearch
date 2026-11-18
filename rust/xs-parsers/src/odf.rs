//! OpenDocument text (.odt) and presentations (.odp): `content.xml` of the zip package.
//! Spreadsheets (.ods) go through calamine with the other workbooks.
//! Anchors as for their Office counterparts: .odt one per paragraph ("段 13") and per table
//! cell ("表 2·B3"); .odp one per page (slide), its speaker notes after it ("备注 3").
use crate::office::{Out, zip_text};
use crate::{Extraction, Limits};
use anyhow::{Result, bail};
use roxmltree::{Document, Node};
use std::{fs::File, path::Path};
use xs_index::AnchorKind;

pub const ODF_EXTRACTOR_VERSION: u64 = 1;

const TEXT: &str = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";
const TABLE: &str = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
const DRAW: &str = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0";
const OFFICE: &str = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
const PRESENTATION: &str = "urn:oasis:names:tc:opendocument:xmlns:presentation:1.0";

fn content(path: &Path, limits: Limits) -> Result<String> {
    let mut zip = zip::ZipArchive::new(File::open(path)?)?;
    if zip.len() > 10_000 {
        bail!("archive entry limit");
    }
    let mut used = 0;
    zip_text(&mut zip, "content.xml", limits, &mut used)
}

fn body<'a>(doc: &'a Document<'a>, kind: &str) -> Result<Node<'a, 'a>> {
    doc.descendants().find(|n| n.has_tag_name((OFFICE, kind))).ok_or_else(|| anyhow::anyhow!("missing office:{kind}"))
}

/// .odt: paragraphs and headings in document order, through lists, sections, tables and
/// text frames; footnotes after the paragraph that cites them.
pub fn text(path: &Path, limits: Limits) -> Result<Extraction> {
    let xml = content(path, limits)?;
    let doc = Document::parse(&xml)?;
    let mut w = Walker { out: Out::new(limits), paragraphs: 0, tables: 0, numbered: true };
    w.block(body(&doc, "text")?, None);
    Ok(w.out.done("odt"))
}

/// .odp: each page (draw:page) is a slide: its frames' text, then its speaker notes.
pub fn presentation(path: &Path, limits: Limits) -> Result<Extraction> {
    let xml = content(path, limits)?;
    let doc = Document::parse(&xml)?;
    let pages: Vec<_> = body(&doc, "presentation")?.children().filter(|n| n.has_tag_name((DRAW, "page"))).collect();
    if pages.is_empty() {
        bail!("no slides");
    }
    let mut w = Walker { out: Out::new(limits), paragraphs: 0, tables: 0, numbered: false };
    for (i, page) in pages.into_iter().enumerate() {
        let n = i as u32 + 1;
        w.out.anchor(AnchorKind::Slide { slide: n });
        let notes = page.children().find(|c| c.has_tag_name((PRESENTATION, "notes")));
        for child in page.children().filter(|c| c.is_element() && Some(*c) != notes) {
            w.block(child, None);
        }
        if let Some(notes) = notes {
            let mut text = Walker { out: Out::new(limits), paragraphs: 0, tables: 0, numbered: false };
            text.block(notes, None);
            // Like .pptx: a page-number field alone is not a note.
            if text.out.text.lines().any(|l| !l.trim().is_empty() && l.trim().parse::<u32>().is_err()) {
                w.out.anchor(AnchorKind::Part { name: format!("备注 {n}") });
                w.block(notes, None);
            }
        }
        if w.out.partial {
            break;
        }
    }
    Ok(w.out.done("odp"))
}

struct Walker {
    out: Out,
    paragraphs: u32,
    tables: u32,
    /// .odt numbers paragraphs; .odp has slide anchors instead.
    numbered: bool,
}

impl Walker {
    /// Block-level content; `cell` is the enclosing table cell (table, label) if any.
    fn block(&mut self, node: Node, cell: Option<(u32, String)>) {
        for child in node.children().filter(Node::is_element) {
            if self.out.partial {
                return;
            }
            if child.has_tag_name((TEXT, "p")) || child.has_tag_name((TEXT, "h")) {
                self.paragraph(child, cell.clone());
            } else if child.has_tag_name((TABLE, "table")) {
                self.table(child);
            } else if child.has_tag_name((OFFICE, "annotation")) || child.has_tag_name((TEXT, "tracked-changes")) {
                // Comments and deleted text of tracked changes are not the document's text.
            } else {
                self.block(child, cell.clone());
            }
        }
    }

    fn table(&mut self, table: Node) {
        self.tables += 1;
        let t = self.tables;
        let rows = table.descendants().filter(|n| n.has_tag_name((TABLE, "table-row")));
        for (r, row) in rows.enumerate() {
            let mut col = 0usize;
            for c in row.children().filter(|n| n.has_tag_name((TABLE, "table-cell")) || n.has_tag_name((TABLE, "covered-table-cell"))) {
                // A repeated empty cell stands for several columns.
                let repeat = c.attribute((TABLE, "number-columns-repeated")).and_then(|v| v.parse::<usize>().ok()).unwrap_or(1).max(1);
                if c.has_tag_name((TABLE, "table-cell")) {
                    self.block(c, Some((t, format!("{}{}", column(col), r + 1))));
                }
                col = col.saturating_add(repeat);
            }
        }
    }

    fn paragraph(&mut self, p: Node, cell: Option<(u32, String)>) {
        let start = self.out.chars;
        let mut text = String::new();
        let mut nested = vec![];
        collect(p, &mut text, &mut nested);
        if !text.trim().is_empty() {
            match cell {
                Some((table, label)) => self.out.anchor(AnchorKind::Cell { table, cell: label }),
                None if self.numbered => {
                    self.paragraphs += 1;
                    self.out.anchors.push(crate::paragraph_anchor(start, self.paragraphs));
                }
                None => {}
            }
            self.out.push(&text);
            self.out.push("\n");
        }
        // Text frames and footnote bodies inside the paragraph follow it.
        for n in nested {
            self.block(n, None);
        }
    }
}

/// Text owned by a paragraph: spans, links, spaces, tabs and breaks; frames and note bodies are
/// returned in `nested`.
fn collect<'a>(node: Node<'a, 'a>, out: &mut String, nested: &mut Vec<Node<'a, 'a>>) {
    for n in node.children() {
        if n.is_text() {
            out.push_str(n.text().unwrap_or(""));
            continue;
        }
        if !n.is_element() {
            continue;
        }
        if n.has_tag_name((TEXT, "s")) {
            let c = n.attribute((TEXT, "c")).and_then(|v| v.parse::<usize>().ok()).unwrap_or(1).min(1000);
            out.extend(std::iter::repeat_n(' ', c));
        } else if n.has_tag_name((TEXT, "tab")) {
            out.push('\t');
        } else if n.has_tag_name((TEXT, "line-break")) {
            out.push('\n');
        } else if n.has_tag_name((TEXT, "note")) {
            if let Some(b) = n.children().find(|c| c.has_tag_name((TEXT, "note-body"))) {
                nested.push(b);
            }
        } else if n.has_tag_name((DRAW, "frame")) || n.has_tag_name((DRAW, "text-box")) {
            nested.push(n);
        } else if n.has_tag_name((OFFICE, "annotation")) || n.has_tag_name((TEXT, "deletion")) {
        } else {
            collect(n, out, nested);
        }
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

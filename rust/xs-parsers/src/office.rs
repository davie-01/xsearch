//! M3 formats: spreadsheets (XLSX / XLSM / XLS / ODS via calamine), PPTX and OFD.
use crate::{Extraction, Limits};
use anyhow::{Context, Result, bail};
use calamine::{Data, Reader, open_workbook_auto};
use roxmltree::Node;
use std::{collections::BTreeMap, fs::File, io::Read, path::Path};
use xs_index::{Anchor, AnchorKind, ExtractState};

pub const SHEET_EXTRACTOR_VERSION: u64 = 1;
pub const PPTX_EXTRACTOR_VERSION: u64 = 1;
pub const OFD_EXTRACTOR_VERSION: u64 = 1;

struct Out {
    text: String,
    chars: usize,
    anchors: Vec<Anchor>,
    partial: bool,
    warnings: Vec<String>,
    max_chars: usize,
}

impl Out {
    fn new(limits: Limits) -> Self {
        // Unpacked byte budget doubles as a text budget (scalars ≤ bytes).
        Self { text: String::new(), chars: 0, anchors: vec![], partial: false, warnings: vec![], max_chars: limits.max_unpacked_bytes as usize }
    }
    fn anchor(&mut self, kind: AnchorKind) {
        self.anchors.push(Anchor { start: self.chars as u32, kind });
    }
    /// Returns false once the text budget is exhausted.
    fn push(&mut self, s: &str) -> bool {
        if self.chars >= self.max_chars {
            if !self.partial {
                self.partial = true;
                self.warnings.push("内容超过上限，后续部分未索引".into());
            }
            return false;
        }
        self.text.push_str(s);
        self.chars += s.chars().count();
        true
    }
    fn done(self, method: &str) -> Extraction {
        Extraction {
            text: self.text,
            anchors: self.anchors,
            state: if self.partial { ExtractState::Partial } else { ExtractState::Complete },
            warnings: self.warnings,
            method: method.into(),
        }
    }
}

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

/// One line per non-empty row (cells separated by tabs), anchored "Sheet1!A12" at the row's
/// first non-empty cell. Formulas contribute their cached values.
pub fn spreadsheet(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut wb = open_workbook_auto(path).context("spreadsheet unreadable")?;
    let mut out = Out::new(limits);
    'sheets: for name in wb.sheet_names().to_owned() {
        let Ok(range) = wb.worksheet_range(&name) else { continue };
        let (r0, c0) = range.start().unwrap_or((0, 0));
        for (r, row) in range.rows().enumerate() {
            let cells: Vec<(usize, String)> = row
                .iter()
                .enumerate()
                .filter_map(|(c, v)| {
                    let s = match v {
                        Data::Empty => return None,
                        Data::String(s) => s.clone(),
                        Data::Float(f) if f.fract() == 0.0 && f.abs() < 1e15 => format!("{}", *f as i64),
                        other => other.to_string(),
                    };
                    let s = s.trim().to_owned();
                    (!s.is_empty()).then_some((c, s))
                })
                .collect();
            let Some((first, _)) = cells.first() else { continue };
            out.anchor(AnchorKind::Sheet { sheet: name.clone(), cell: format!("{}{}", column(c0 as usize + first), r0 as usize + r + 1) });
            let line = cells.into_iter().map(|(_, s)| s).collect::<Vec<_>>().join("\t");
            if !out.push(&line) || !out.push("\n") {
                break 'sheets;
            }
        }
    }
    Ok(out.done("sheet"))
}

fn zip_text(zip: &mut zip::ZipArchive<File>, name: &str, limits: Limits, used: &mut u64) -> Result<String> {
    let mut f = zip.by_name(name)?;
    *used += f.size();
    if *used > limits.max_unpacked_bytes {
        bail!("uncompressed size limit");
    }
    let mut s = String::new();
    Read::by_ref(&mut f).take(limits.max_unpacked_bytes + 1).read_to_string(&mut s)?;
    Ok(s)
}

/// Numbered parts in numeric order: slide2 before slide10.
fn numbered(zip: &zip::ZipArchive<File>, prefix: &str) -> BTreeMap<u32, String> {
    zip.file_names()
        .filter_map(|n| {
            let num = n.strip_prefix(prefix)?.strip_suffix(".xml")?.parse().ok()?;
            Some((num, n.to_owned()))
        })
        .collect()
}

const A: &str = "http://schemas.openxmlformats.org/drawingml/2006/main";

/// Paragraph texts (`a:p` → `a:t` runs, `a:br` breaks) of a DrawingML part.
fn drawing_paragraphs(xml: &str) -> Result<Vec<String>> {
    let doc = roxmltree::Document::parse(xml)?;
    Ok(doc
        .descendants()
        .filter(|n| n.has_tag_name((A, "p")))
        .map(|p| {
            let mut s = String::new();
            for n in p.descendants() {
                if n.has_tag_name((A, "t")) {
                    s.push_str(n.text().unwrap_or(""));
                } else if n.has_tag_name((A, "br")) {
                    s.push('\n');
                }
            }
            s
        })
        .filter(|s| !s.trim().is_empty())
        .collect())
}

/// Slides in order, each followed by its speaker notes; a slide anchor per slide.
pub fn pptx(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut zip = zip::ZipArchive::new(File::open(path)?)?;
    let slides = numbered(&zip, "ppt/slides/slide");
    if slides.is_empty() {
        bail!("no slides");
    }
    let notes = numbered(&zip, "ppt/notesSlides/notesSlide");
    let mut out = Out::new(limits);
    let mut used = 0;
    for (n, name) in slides {
        out.anchor(AnchorKind::Slide { slide: n });
        for p in drawing_paragraphs(&zip_text(&mut zip, &name, limits, &mut used)?)? {
            out.push(&p);
            out.push("\n");
        }
        // Notes numbering follows slides in typical files; good enough for search.
        if let Some(note) = notes.get(&n) {
            let paras = drawing_paragraphs(&zip_text(&mut zip, note, limits, &mut used)?)?;
            // The first note paragraphs often repeat the slide number placeholder; keep text only.
            let paras: Vec<_> = paras.into_iter().filter(|p| p.trim().parse::<u32>().is_err()).collect();
            if !paras.is_empty() {
                out.anchor(AnchorKind::Part { name: format!("备注 {n}") });
                for p in paras {
                    out.push(&p);
                    out.push("\n");
                }
            }
        }
        if out.partial {
            break;
        }
    }
    Ok(out.done("pptx"))
}

fn local(n: &Node, name: &str) -> bool {
    n.is_element() && n.tag_name().name() == name
}

fn join(base: &str, rel: &str) -> String {
    let rel = rel.trim_start_matches('/');
    let mut parts: Vec<&str> = base.split('/').filter(|s| !s.is_empty()).collect();
    for seg in rel.split('/') {
        match seg {
            "." | "" => {}
            ".." => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    parts.join("/")
}

/// OFD (GB/T 33190): OFD.xml → DocRoot (Document.xml) → Pages in order → Content.xml; text is
/// `TextCode` inside `TextObject`, one line per text object, a page anchor per page.
pub fn ofd(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut zip = zip::ZipArchive::new(File::open(path)?)?;
    let mut used = 0;
    let root_xml = zip_text(&mut zip, "OFD.xml", limits, &mut used).context("missing OFD.xml")?;
    let root = roxmltree::Document::parse(&root_xml)?;
    let doc_root = root.descendants().find(|n| local(n, "DocRoot")).and_then(|n| n.text()).context("missing DocRoot")?.trim().to_owned();
    let doc_dir = doc_root.rsplit_once('/').map(|(d, _)| d.to_owned()).unwrap_or_default();
    let doc_xml = zip_text(&mut zip, &join("", &doc_root), limits, &mut used)?;
    let doc = roxmltree::Document::parse(&doc_xml)?;
    let mut pages: Vec<String> = doc
        .descendants()
        .filter(|n| local(n, "Page"))
        .filter_map(|n| n.attribute("BaseLoc"))
        .map(|loc| join(&doc_dir, loc))
        .collect();
    if pages.is_empty() {
        // Fallback: every page content file in numeric order.
        let mut found: Vec<(u32, String)> = zip
            .file_names()
            .filter(|n| n.ends_with("/Content.xml") && n.contains("/Pages/"))
            .filter_map(|n| {
                let page = n.split('/').find(|s| s.starts_with("Page_"))?.trim_start_matches("Page_").parse().ok()?;
                Some((page, n.to_owned()))
            })
            .collect();
        found.sort();
        pages = found.into_iter().map(|(_, n)| n).collect();
    }
    let mut out = Out::new(limits);
    for (i, page) in pages.iter().enumerate() {
        out.anchor(AnchorKind::Page { page: i as u32 + 1 });
        let Ok(xml) = zip_text(&mut zip, page, limits, &mut used) else {
            out.partial = true;
            out.warnings.push(format!("第 {} 页无法读取", i + 1));
            continue;
        };
        let content = roxmltree::Document::parse(&xml)?;
        for obj in content.descendants().filter(|n| local(n, "TextObject")) {
            let line: String = obj.descendants().filter(|n| local(n, "TextCode")).filter_map(|n| n.text()).collect();
            if !line.trim().is_empty() {
                out.push(&line);
                out.push("\n");
            }
        }
        if out.partial {
            break;
        }
    }
    Ok(out.done("ofd"))
}

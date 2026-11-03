//! M3 formats: spreadsheets (XLSX / XLSM / XLS / ODS via calamine), PPTX and OFD.
use crate::{Extraction, Limits};
use anyhow::{Context, Result, bail};
use calamine::{Data, Reader, open_workbook_auto};
use roxmltree::Node;
use std::{collections::BTreeMap, fs::File, io::Read, path::Path};
use xs_index::{Anchor, AnchorKind, ExtractState};

pub const SHEET_EXTRACTOR_VERSION: u64 = 2;
pub const PPTX_EXTRACTOR_VERSION: u64 = 2;
pub const OFD_EXTRACTOR_VERSION: u64 = 2;

pub(crate) struct Out {
    pub(crate) text: String,
    pub(crate) chars: usize,
    pub(crate) anchors: Vec<Anchor>,
    pub(crate) partial: bool,
    pub(crate) warnings: Vec<String>,
    max_bytes: usize,
    /// The text was cut: nothing later may follow it, even if a short piece would still fit.
    full: bool,
}

impl Out {
    pub(crate) fn new(limits: Limits) -> Self {
        // The unpacked byte budget doubles as the budget for the UTF-8 text produced.
        Self { text: String::new(), chars: 0, anchors: vec![], partial: false, warnings: vec![], max_bytes: limits.max_unpacked_bytes as usize, full: false }
    }
    pub(crate) fn anchor(&mut self, kind: AnchorKind) {
        self.anchors.push(Anchor { start: self.chars as u32, kind });
    }
    /// Appends what fits, ending on a character boundary. Returns false once the budget is
    /// exhausted: the text is then marked partial and never exceeds the budget.
    pub(crate) fn push(&mut self, s: &str) -> bool {
        if self.full {
            return false;
        }
        let room = self.max_bytes.saturating_sub(self.text.len());
        let fits = s.len() <= room;
        let mut end = s.len().min(room);
        while !s.is_char_boundary(end) {
            end -= 1;
        }
        self.text.push_str(&s[..end]);
        self.chars += s[..end].chars().count();
        if !fits {
            self.full = true;
            self.partial = true;
            self.warnings.push("内容超过上限，后续部分未索引".into());
        }
        fits
    }
    pub(crate) fn done(self, method: &str) -> Extraction {
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
    // Known extensions pick their reader; others (WPS .et = BIFF8) are recognised by content.
    let known = path.extension().and_then(|e| e.to_str()).is_some_and(|e| {
        ["xlsx", "xlsm", "xlsb", "xls", "xla", "ods"].contains(&e.to_ascii_lowercase().as_str())
    });
    // The reader unpacks a whole sheet before the text budget can apply: go by the package's
    // declared sizes first (a binary .xls is no package and is bound by the file limit).
    if let Ok(z) = zip::ZipArchive::new(File::open(path)?) {
        // None: the package does not say. Not a reason to refuse it.
        if z.decompressed_size().is_some_and(|total| total > limits.max_unpacked_bytes as u128) {
            bail!("uncompressed size limit");
        }
    }
    let mut wb = if known {
        open_workbook_auto(path).context("spreadsheet unreadable")?
    } else {
        let data = std::fs::read(path)?;
        let auto = calamine::open_workbook_auto_from_rs(std::io::Cursor::new(data)).context("spreadsheet unreadable")?;
        return sheets_into(auto, limits);
    };
    sheets_into_impl(&mut wb, limits)
}

fn sheets_into<RS: std::io::Read + std::io::Seek>(mut wb: calamine::Sheets<RS>, limits: Limits) -> Result<Extraction> {
    sheets_into_impl(&mut wb, limits)
}

fn sheets_into_impl<RS: std::io::Read + std::io::Seek>(wb: &mut calamine::Sheets<RS>, limits: Limits) -> Result<Extraction> {
    let mut out = Out::new(limits);
    'sheets: for name in wb.sheet_names().to_owned() {
        let Ok(range) = wb.worksheet_range(&name) else {
            out.partial = true;
            out.warnings.push(format!("工作表“{name}”无法读取"));
            continue;
        };
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

pub(crate) fn zip_text<R: Read + std::io::Seek>(zip: &mut zip::ZipArchive<R>, name: &str, limits: Limits, used: &mut u64) -> Result<String> {
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

/// Slides in order, each followed by its speaker notes; a slide anchor per slide. Binary
/// PowerPoint (.ppt / .pps, WPS .dps) is recognised by its OLE2 signature.
pub fn pptx(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut magic = [0u8; 8];
    if File::open(path)?.read_exact(&mut magic).is_ok() && magic == OLE_MAGIC {
        return ppt_binary(path, limits);
    }
    let mut zip = zip::ZipArchive::new(File::open(path)?)?;
    let mut used = 0;
    let slides = match slides_in_presentation_order(&mut zip, limits, &mut used) {
        Some(ordered) if !ordered.is_empty() => ordered,
        // No usable presentation part: file numbering is the best remaining guide.
        _ => {
            let notes = numbered(&zip, "ppt/notesSlides/notesSlide");
            numbered(&zip, "ppt/slides/slide").into_iter().map(|(n, name)| (n, name, notes.get(&n).cloned())).collect()
        }
    };
    if slides.is_empty() {
        bail!("no slides");
    }
    let mut out = Out::new(limits);
    for (n, name, note) in slides {
        out.anchor(AnchorKind::Slide { slide: n });
        for p in drawing_paragraphs(&zip_text(&mut zip, &name, limits, &mut used)?)? {
            out.push(&p);
            out.push("\n");
        }
        if let Some(note) = note {
            let paras = drawing_paragraphs(&zip_text(&mut zip, &note, limits, &mut used)?)?;
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

/// (position, slide part, notes part) as shown: `presentation.xml` lists the slides, and each
/// slide's relationships name its notes. Part numbers say nothing once slides were reordered,
/// copied or deleted. None when the parts are missing or malformed.
fn slides_in_presentation_order(zip: &mut zip::ZipArchive<File>, limits: Limits, used: &mut u64) -> Option<Vec<(u32, String, Option<String>)>> {
    let xml = zip_text(zip, "ppt/presentation.xml", limits, used).ok()?;
    let doc = roxmltree::Document::parse(&xml).ok()?;
    let rels = relationships(zip, "ppt/_rels/presentation.xml.rels", "ppt", limits, used)?;
    let mut out = vec![];
    for id in doc.descendants().filter(|n| local(n, "sldId")) {
        // Its plain `id` attribute is a number; the relationship is the namespaced one.
        let Some(rid) = id.attributes().find(|a| a.name() == "id" && a.namespace().is_some()) else { continue };
        let Some((_, part)) = rels.iter().find(|(rel, _)| rel.0 == rid.value()) else { continue };
        if zip.index_for_name(part).is_none() {
            continue;
        }
        let (dir, file) = part.rsplit_once('/')?;
        let note = relationships(zip, &format!("{dir}/_rels/{file}.rels"), dir, limits, used)
            .unwrap_or_default()
            .into_iter()
            .find(|((_, kind), target)| kind.ends_with("/notesSlide") && zip.index_for_name(target).is_some())
            .map(|(_, target)| target);
        out.push((out.len() as u32 + 1, part.clone(), note));
    }
    Some(out)
}

/// ((id, type), part name) of an OOXML relationships part; `base` is the source part's folder.
fn relationships(zip: &mut zip::ZipArchive<File>, rels: &str, base: &str, limits: Limits, used: &mut u64) -> Option<Vec<((String, String), String)>> {
    let xml = zip_text(zip, rels, limits, used).ok()?;
    let doc = roxmltree::Document::parse(&xml).ok()?;
    Some(
        doc.descendants()
            .filter(|n| local(n, "Relationship") && n.attribute("TargetMode") != Some("External"))
            .filter_map(|n| {
                let target = n.attribute("Target")?;
                let part = if target.starts_with('/') { join("", target) } else { join(base, target) };
                Some(((n.attribute("Id")?.to_owned(), n.attribute("Type")?.to_owned()), part))
            })
            .collect(),
    )
}

fn local(n: &Node, name: &str) -> bool {
    n.is_element() && n.tag_name().name() == name
}

pub(crate) fn join(base: &str, rel: &str) -> String {
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
    let mut image_only = 0;
    for (i, page) in pages.iter().enumerate() {
        out.anchor(AnchorKind::Page { page: i as u32 + 1 });
        let Ok(xml) = zip_text(&mut zip, page, limits, &mut used) else {
            out.partial = true;
            out.warnings.push(format!("第 {} 页无法读取", i + 1));
            continue;
        };
        let content = roxmltree::Document::parse(&xml)?;
        let before = out.chars;
        for obj in content.descendants().filter(|n| local(n, "TextObject")) {
            let line: String = obj.descendants().filter(|n| local(n, "TextCode")).filter_map(|n| n.text()).collect();
            if !line.trim().is_empty() {
                out.push(&line);
                out.push("\n");
            }
        }
        // Scanned pages: images and no text layer (OCR is M6).
        if out.chars == before && content.descendants().any(|n| local(&n, "ImageObject")) {
            image_only += 1;
        }
        if out.partial {
            break;
        }
    }
    let pages_total = pages.len();
    let mut e = out.done("ofd");
    if image_only > 0 {
        e.warnings.push(format!("{image_only} 页没有文字层，等待 OCR"));
        if image_only == pages_total {
            e.state = ExtractState::WaitingOcr;
        } else if e.state == ExtractState::Complete {
            e.state = ExtractState::Partial;
        }
    }
    Ok(e)
}

/// Archive reader: memory-backed when the file needed repair.
pub(crate) type AnyZip = zip::ZipArchive<Box<dyn ReadSeek>>;
pub(crate) trait ReadSeek: Read + std::io::Seek {}
impl<T: Read + std::io::Seek> ReadSeek for T {}

/// Opens a zip; when the end-of-central-directory record claims the wrong number of entries
/// (seen in real ePubs from buggy writers; Python accepts them, the zip crate does not), the
/// file is read into memory with the count corrected from the actual central directory.
const REPAIR_MAX_BYTES: u64 = 512 << 20;

pub(crate) fn open_zip(path: &Path, limits: Limits) -> Result<AnyZip> {
    let first = zip::ZipArchive::new(Box::new(File::open(path)?) as Box<dyn ReadSeek>);
    let Err(err) = first else { return Ok(first?) };
    let size = std::fs::metadata(path)?.len();
    // The repair reads the whole file into memory; callers may pass no file limit of their own.
    if size > limits.max_unpacked_bytes.max(limits.max_file_bytes).min(REPAIR_MAX_BYTES) {
        return Err(err.into());
    }
    let mut data = std::fs::read(path)?;
    let Some(eocd) = data.windows(4).rposition(|w| w == b"PK\x05\x06") else { return Err(err.into()) };
    if eocd + 22 > data.len() {
        return Err(err.into());
    }
    let u32_at = |d: &[u8], o: usize| u32::from_le_bytes([d[o], d[o + 1], d[o + 2], d[o + 3]]) as usize;
    let (cd_size, cd_off) = (u32_at(&data, eocd + 12), u32_at(&data, eocd + 16));
    if cd_off + cd_size > eocd {
        return Err(err.into());
    }
    // Walk the central directory headers that really exist.
    let mut count = 0u16;
    let mut at = cd_off;
    while at + 46 <= cd_off + cd_size && data[at..at + 4] == *b"PK\x01\x02" {
        let len = |o: usize| u16::from_le_bytes([data[at + o], data[at + o + 1]]) as usize;
        at += 46 + len(28) + len(30) + len(32);
        count += 1;
    }
    if count == 0 {
        return Err(err.into());
    }
    data[eocd + 8..eocd + 10].copy_from_slice(&count.to_le_bytes());
    data[eocd + 10..eocd + 12].copy_from_slice(&count.to_le_bytes());
    Ok(zip::ZipArchive::new(Box::new(std::io::Cursor::new(data)) as Box<dyn ReadSeek>)?)
}

pub(crate) const OLE_MAGIC: [u8; 8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

/// Text of a binary PowerPoint 97–2003 deck ([MS-PPT]). Primary path: `ppt_by_persist`.
/// Fallback for files without a usable persist directory: a plain walk of the record tree that
/// assigns text boxes to slides in container order (title / notes masters can then shift
/// numbering).
fn ppt_binary(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut ole = cfb::open(path).context("not an OLE2 file")?;
    let mut stream = ole.open_stream("/PowerPoint Document").context("missing PowerPoint Document stream")?;
    let mut data = vec![];
    Read::by_ref(&mut stream).take(limits.max_unpacked_bytes).read_to_end(&mut data)?;

    #[derive(Default)]
    struct Walk {
        slides: BTreeMap<u32, Vec<String>>,
        notes: BTreeMap<u32, Vec<String>>,
        list: Option<u16>,
        slide: u32,
        note: u32,
        container: Option<u32>,
        containers: u32,
        notes_container: Option<u32>,
        notes_containers: u32,
    }
    fn add(map: &mut BTreeMap<u32, Vec<String>>, n: u32, text: String) {
        let t = text.replace(['\r', '\u{0B}'], "\n");
        let t = t.trim();
        if t.is_empty() || n == 0 {
            return;
        }
        let v = map.entry(n).or_default();
        if !v.iter().any(|x| x == t) {
            v.push(t.to_owned());
        }
    }
    fn walk(d: &[u8], w: &mut Walk, depth: u32) {
        let mut pos = 0;
        while pos + 8 <= d.len() && depth < 32 {
            let verinst = u16::from_le_bytes([d[pos], d[pos + 1]]);
            let rtype = u16::from_le_bytes([d[pos + 2], d[pos + 3]]);
            let len = u32::from_le_bytes([d[pos + 4], d[pos + 5], d[pos + 6], d[pos + 7]]) as usize;
            let body = &d[pos + 8..(pos + 8).saturating_add(len).min(d.len())];
            pos = (pos + 8).saturating_add(len);
            let (ver, inst) = (verinst & 0xF, verinst >> 4);
            let text = match rtype {
                0x0FA0 => Some(String::from_utf16_lossy(&body.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect::<Vec<_>>())),
                0x0FA8 => Some(body.iter().map(|&b| b as char).collect()),
                _ => None,
            };
            if let Some(t) = text {
                if let Some(c) = w.container {
                    add(&mut w.slides, c, t);
                } else if let Some(c) = w.notes_container {
                    add(&mut w.notes, c, t);
                } else if w.list == Some(0) {
                    add(&mut w.slides, w.slide, t);
                } else if w.list == Some(2) {
                    add(&mut w.notes, w.note, t);
                }
                continue;
            }
            match rtype {
                0x03F8 | 0x0FD9 | 0x0FC4 => {}
                0x0FF0 => {
                    w.list = Some(inst);
                    walk(body, w, depth + 1);
                    w.list = None;
                }
                0x03F3 => match w.list {
                    Some(0) => w.slide += 1,
                    Some(2) => w.note += 1,
                    _ => {}
                },
                0x03EE => {
                    w.containers += 1;
                    w.container = Some(w.containers);
                    walk(body, w, depth + 1);
                    w.container = None;
                }
                0x03F0 => {
                    w.notes_containers += 1;
                    w.notes_container = Some(w.notes_containers);
                    walk(body, w, depth + 1);
                    w.notes_container = None;
                }
                _ if ver == 0xF => walk(body, w, depth + 1),
                _ => {}
            }
        }
    }
    let mut w = Walk::default();
    if !ppt_by_persist(&data, &mut w.slides, &mut w.notes) {
        walk(&data, &mut w, 0);
    }
    let mut out = Out::new(limits);
    let numbers: std::collections::BTreeSet<u32> = w.slides.keys().chain(w.notes.keys()).copied().collect();
    for n in numbers {
        out.anchor(AnchorKind::Slide { slide: n });
        for t in w.slides.get(&n).into_iter().flatten() {
            out.push(t);
            out.push("\n");
        }
        // Slide-number fields and similar one-word placeholders are left out of notes.
        let notes: Vec<&String> = w.notes.get(&n).into_iter().flatten().filter(|t| t.trim().parse::<u32>().is_err()).collect();
        if !notes.is_empty() {
            out.anchor(AnchorKind::Part { name: format!("备注 {n}") });
            for t in notes {
                out.push(t);
                out.push("\n");
            }
        }
        if out.partial {
            break;
        }
    }
    Ok(out.done("ppt"))
}

struct Rec<'a> {
    ver: u16,
    inst: u16,
    rtype: u16,
    body: &'a [u8],
    end: usize,
}

fn rec_at(d: &[u8], pos: usize) -> Option<Rec<'_>> {
    if pos + 8 > d.len() {
        return None;
    }
    let verinst = u16::from_le_bytes([d[pos], d[pos + 1]]);
    let rtype = u16::from_le_bytes([d[pos + 2], d[pos + 3]]);
    let len = u32::from_le_bytes([d[pos + 4], d[pos + 5], d[pos + 6], d[pos + 7]]) as usize;
    let end = (pos + 8).saturating_add(len).min(d.len());
    Some(Rec { ver: verinst & 0xF, inst: verinst >> 4, rtype, body: &d[pos + 8..end], end })
}

fn atom_text(r: &Rec) -> Option<String> {
    match r.rtype {
        0x0FA0 => Some(String::from_utf16_lossy(&r.body.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect::<Vec<_>>())),
        0x0FA8 => Some(r.body.iter().map(|&b| b as char).collect()),
        _ => None,
    }
}

/// Every text atom inside a container, depth-first.
fn texts_in(d: &[u8], out: &mut Vec<String>, depth: u32) {
    let mut pos = 0;
    while let Some(r) = rec_at(d, pos) {
        pos = pos + 8 + r.body.len();
        if let Some(t) = atom_text(&r) {
            out.push(t);
        } else if r.ver == 0xF && depth < 32 {
            texts_in(r.body, out, depth + 1);
        }
    }
}

/// [MS-PPT] structure: the persist directory (0x1772, later entries win) maps persist ids to
/// stream offsets; the newest DocumentContainer's SlideListWithText lists slides (instance 0)
/// and notes (instance 2) in order, each SlidePersistAtom carrying persistIdRef (+0) and
/// slideId (+12) followed by its placeholder text; a slide's container holds its text boxes
/// and a SlideAtom (0x03EF) whose notesIdRef (+16) names its notes. Masters are never
/// referenced, so their template text stays out. Returns false when the structure is missing.
fn ppt_by_persist(d: &[u8], slides: &mut BTreeMap<u32, Vec<String>>, notes: &mut BTreeMap<u32, Vec<String>>) -> bool {
    let u32_at = |b: &[u8], o: usize| (o + 4 <= b.len()).then(|| u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]));
    let mut persist: std::collections::HashMap<u32, usize> = Default::default();
    let mut doc: Option<usize> = None;
    let mut pos = 0;
    while let Some(r) = rec_at(d, pos) {
        match r.rtype {
            0x1772 => {
                let mut o = 0;
                while let Some(h) = u32_at(r.body, o) {
                    let (start, count) = (h & 0xF_FFFF, (h >> 20) as usize);
                    for k in 0..count {
                        if let Some(off) = u32_at(r.body, o + 4 + 4 * k) {
                            persist.insert(start + k as u32, off as usize);
                        }
                    }
                    o += 4 + 4 * count;
                }
            }
            0x03E8 => doc = Some(pos),
            _ => {}
        }
        pos = r.end;
    }
    let Some(doc) = doc.and_then(|p| rec_at(d, p)) else { return false };
    struct Entry {
        persist: u32,
        id: u32,
        texts: Vec<String>,
    }
    let (mut slide_list, mut notes_list) = (vec![], vec![]);
    let mut p = 0;
    while let Some(r) = rec_at(doc.body, p) {
        p = r.end;
        if r.rtype != 0x0FF0 || (r.inst != 0 && r.inst != 2) {
            continue;
        }
        let list: &mut Vec<Entry> = if r.inst == 0 { &mut slide_list } else { &mut notes_list };
        let mut q = 0;
        while let Some(c) = rec_at(r.body, q) {
            q = c.end;
            if c.rtype == 0x03F3 {
                list.push(Entry { persist: u32_at(c.body, 0).unwrap_or(0), id: u32_at(c.body, 12).unwrap_or(0), texts: vec![] });
            } else if let (Some(t), Some(e)) = (atom_text(&c), list.last_mut()) {
                e.texts.push(t);
            } else if c.ver == 0xF && let Some(e) = list.last_mut() {
                texts_in(c.body, &mut e.texts, 1);
            }
        }
    }
    if slide_list.is_empty() {
        return false;
    }
    let container = |persist_id: u32| persist.get(&persist_id).and_then(|&o| rec_at(d, o)).filter(|r| r.rtype == 0x03EE || r.rtype == 0x03F0);
    let notes_by_id: std::collections::HashMap<u32, &Entry> = notes_list.iter().map(|e| (e.id, e)).collect();
    let push = |map: &mut BTreeMap<u32, Vec<String>>, n: u32, t: &str| {
        let t = t.replace(['\r', '\u{0B}'], "\n");
        let t = t.trim();
        if t.is_empty() {
            return;
        }
        let v = map.entry(n).or_default();
        if !v.iter().any(|x| x == t) {
            v.push(t.to_owned());
        }
    };
    for (i, s) in slide_list.iter().enumerate() {
        let n = i as u32 + 1;
        slides.entry(n).or_default();
        s.texts.iter().for_each(|t| push(slides, n, t));
        let Some(c) = container(s.persist) else { continue };
        let mut boxes = vec![];
        texts_in(c.body, &mut boxes, 1);
        boxes.iter().for_each(|t| push(slides, n, t));
        // SlideAtom → notesIdRef → notes entry (list text + notes container text boxes).
        let notes_id = {
            let mut q = 0;
            let mut found = None;
            while let Some(a) = rec_at(c.body, q) {
                q = a.end;
                if a.rtype == 0x03EF {
                    found = u32_at(a.body, 16);
                    break;
                }
            }
            found
        };
        if let Some(e) = notes_id.filter(|&id| id != 0).and_then(|id| notes_by_id.get(&id)) {
            e.texts.iter().for_each(|t| push(notes, n, t));
            if let Some(nc) = container(e.persist) {
                let mut nb = vec![];
                texts_in(nc.body, &mut nb, 1);
                nb.iter().for_each(|t| push(notes, n, t));
            }
        }
    }
    slides.retain(|_, v| !v.is_empty());
    true
}

#[cfg(test)]
mod budget_tests {
    use super::*;

    fn out(max: u64) -> Out {
        Out::new(Limits { max_file_bytes: 1 << 20, max_unpacked_bytes: max })
    }

    #[test]
    fn text_never_exceeds_the_byte_budget() {
        let mut o = out(4);
        assert!(!o.push("中文ABC"));
        assert_eq!((o.text.as_str(), o.chars), ("中", 1), "cut on a character boundary");
        assert_eq!(o.done("t").state, ExtractState::Partial);

        let mut o = out(6);
        assert!(o.push("中文"), "exactly the budget fits");
        assert!(!o.partial);
        assert!(!o.push("中文"));
        assert_eq!(o.text, "中文");
        assert_eq!(o.done("t").state, ExtractState::Partial);

        let mut o = out(5);
        assert!(!o.push("😀😀"));
        assert_eq!(o.text, "😀");
        assert!(!o.push("x"), "one byte is free, but text after the cut would leave a hole");
        assert_eq!(o.text, "😀");
    }
}

/// Text of a Word 97–2003 binary document ([MS-DOC]): the FIB locates the piece table (CLX) in
/// the table stream, and each piece is either 8-bit (cp1252) or UTF-16 text in the WordDocument
/// stream. AppKit's .doc reader returns nothing for some real documents; this does not depend
/// on it. Field codes are dropped (their results kept); one paragraph anchor per non-empty line.
pub fn word97(path: &Path, limits: Limits) -> Result<Extraction> {
    let mut ole = cfb::open(path).context("not an OLE2 file")?;
    let mut wd = vec![];
    ole.open_stream("/WordDocument").context("missing WordDocument stream")?.read_to_end(&mut wd)?;
    let u16at = |d: &[u8], o: usize| d.get(o..o + 2).map(|b| u16::from_le_bytes([b[0], b[1]]));
    let u32at = |d: &[u8], o: usize| d.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]));
    if u16at(&wd, 0) != Some(0xA5EC) {
        bail!("not a Word document");
    }
    // Word 6 / 95 files use another FIB layout.
    if u16at(&wd, 2).unwrap_or(0) < 101 {
        bail!("Word 95 or older");
    }
    let flags = u16at(&wd, 0x0A).context("short FIB")?;
    if flags & 0x0100 != 0 {
        bail!("文档已加密，无法提取");
    }
    let mut table = vec![];
    let name = if flags & 0x0200 != 0 { "/1Table" } else { "/0Table" };
    ole.open_stream(name).context("missing table stream")?.read_to_end(&mut table)?;

    // FibBase (32 bytes), then counted blocks: fibRgW, fibRgLw, fibRgFcLcb.
    let csw = u16at(&wd, 32).context("short FIB")? as usize;
    let lw = 34 + csw * 2;
    let cslw = u16at(&wd, lw).context("short FIB")? as usize;
    // ccpText, ccpFtn, ccpHdd, ccpMcr, ccpAtn, ccpEdn, ccpTxbx, ccpHdrTxbx: every story.
    let total: u64 = (3..11).filter(|&i| i < cslw).map(|i| u32at(&wd, lw + 2 + i * 4).unwrap_or(0) as u64).sum();
    let fclcb = lw + 2 + cslw * 4 + 2;
    let fc_clx = u32at(&wd, fclcb + 33 * 8).context("short FIB")? as usize;
    let lcb_clx = u32at(&wd, fclcb + 33 * 8 + 4).context("short FIB")? as usize;
    let clx = table.get(fc_clx..fc_clx.saturating_add(lcb_clx)).context("piece table outside the table stream")?;
    let mut pos = 0;
    let plc = loop {
        match clx.get(pos) {
            Some(1) => pos += 3 + u16at(clx, pos + 1).context("bad CLX")? as usize,
            Some(2) => {
                let lcb = u32at(clx, pos + 1).context("bad CLX")? as usize;
                break clx.get(pos + 5..pos + 5 + lcb).context("bad CLX")?;
            }
            _ => bail!("bad CLX"),
        }
    };
    let n = plc.len().saturating_sub(4) / 12;
    let hidden = word97_hidden_runs(&wd, &table, fclcb);
    // Characters whose run is deleted (tracked change) or hidden are not part of the document.
    let shown = |fc: u32| {
        let i = hidden.partition_point(|r| r.1 <= fc);
        !hidden.get(i).is_some_and(|r| r.0 <= fc)
    };
    let mut raw = String::new();
    for i in 0..n {
        let start = u32at(plc, i * 4).unwrap_or(0) as u64;
        let end = (u32at(plc, i * 4 + 4).unwrap_or(0) as u64).min(if total > 0 { total } else { u64::MAX });
        if end <= start {
            continue;
        }
        let len = (end - start) as usize;
        let fc = u32at(plc, (n + 1) * 4 + i * 8 + 2).unwrap_or(0);
        if fc & 0x4000_0000 != 0 {
            let off = (fc & 0x3FFF_FFFF) as usize / 2;
            let Some(b) = wd.get(off..off.saturating_add(len).min(wd.len())) else { continue };
            let kept: Vec<u8> = b.iter().enumerate().filter(|(j, _)| shown((off + j) as u32)).map(|(_, &c)| c).collect();
            raw.push_str(&encoding_rs::WINDOWS_1252.decode_without_bom_handling(&kept).0);
        } else {
            let off = fc as usize;
            let Some(b) = wd.get(off..off.saturating_add(len * 2).min(wd.len())) else { continue };
            let units: Vec<u16> = b.as_chunks::<2>().0.iter().enumerate().filter(|(j, _)| shown((off + j * 2) as u32)).map(|(_, c)| u16::from_le_bytes(*c)).collect();
            raw.push_str(&String::from_utf16_lossy(&units));
        }
    }

    // Special characters: 0x13 field begin, 0x14 separator, 0x15 end (code between begin and
    // separator is dropped); 0x0D paragraph, 0x0B line, 0x0C page/section, 0x07 cell end.
    let mut text = String::with_capacity(raw.len());
    let mut fields: Vec<bool> = vec![];
    for c in raw.chars() {
        match c {
            '\u{13}' => fields.push(true),
            '\u{14}' => {
                if let Some(code) = fields.last_mut() {
                    *code = false;
                }
            }
            '\u{15}' => {
                fields.pop();
            }
            _ if fields.iter().any(|&code| code) => {}
            '\r' | '\u{0B}' | '\u{0C}' | '\u{0E}' => text.push('\n'),
            '\u{07}' => text.push('\t'),
            '\u{1E}' => text.push('-'),
            '\u{A0}' => text.push(' '),
            '\t' => text.push('\t'),
            c if (c as u32) < 0x20 => {}
            c => text.push(c),
        }
    }
    drop(raw);

    let mut out = Out::new(limits);
    let mut index = 0;
    for line in text.split('\n') {
        let line = line.trim_end_matches('\t');
        if line.trim().is_empty() {
            continue;
        }
        index += 1;
        out.anchor(AnchorKind::Paragraph { index });
        if !out.push(line) || !out.push("\n") {
            break;
        }
    }
    Ok(out.done("word97"))
}

/// Byte ranges [start, end) of the WordDocument stream whose character properties mark the text
/// deleted (sprmCFRMarkDel) or hidden (sprmCFVanish), sorted. From the CHPX FKPs that
/// PlcBteChpx points to; anything unreadable simply yields no ranges.
fn word97_hidden_runs(wd: &[u8], table: &[u8], fclcb: usize) -> Vec<(u32, u32)> {
    let u16at = |d: &[u8], o: usize| d.get(o..o + 2).map(|b| u16::from_le_bytes([b[0], b[1]]));
    let u32at = |d: &[u8], o: usize| d.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]));
    let mut runs = vec![];
    let (Some(fc), Some(lcb)) = (u32at(wd, fclcb + 12 * 8), u32at(wd, fclcb + 12 * 8 + 4)) else { return runs };
    let Some(plc) = table.get(fc as usize..(fc as usize).saturating_add(lcb as usize)) else { return runs };
    let n = plc.len().saturating_sub(4) / 8;
    for i in 0..n {
        let Some(pn) = u32at(plc, (n + 1) * 4 + i * 4) else { break };
        let base = (pn & 0x3F_FFFF) as usize * 512;
        let Some(page) = wd.get(base..base + 512) else { continue };
        let crun = page[511] as usize;
        for r in 0..crun.min(101) {
            let (Some(start), Some(end)) = (u32at(page, r * 4), u32at(page, r * 4 + 4)) else { break };
            let Some(&word) = page.get((crun + 1) * 4 + r) else { break };
            if word == 0 {
                continue;
            }
            let at = word as usize * 2;
            let Some(&cb) = page.get(at) else { continue };
            let Some(grpprl) = page.get(at + 1..(at + 1 + cb as usize).min(511)) else { continue };
            let mut p = 0;
            let mut hide = false;
            while let Some(op) = u16at(grpprl, p) {
                p += 2;
                let size = match op >> 13 {
                    0 | 1 => 1,
                    2 | 4 | 5 => 2,
                    3 => 4,
                    7 => 3,
                    _ => 1 + *grpprl.get(p).unwrap_or(&0) as usize,
                };
                // 1 = on, 0x81 = the opposite of the style (assumed off there, so on).
                if (op == 0x0800 || op == 0x083C) && matches!(grpprl.get(p), Some(1 | 0x81)) {
                    hide = true;
                }
                p += size;
            }
            if hide && end > start {
                runs.push((start, end));
            }
        }
    }
    runs.sort_unstable();
    runs
}
